//! Live configuration, persistence, and rollback state.

use std::ops::Deref;

use openlogi_core::config::{Config, ConfigFile, ConfigRevision};
use tracing::warn;

/// Where [`super::AppState`] may persist configuration mutations.
///
/// Runtime state uses [`Self::UserFile`]. Tests opt into
/// [`Self::MemoryOnly`] so realistic device fixtures can never modify the
/// developer's actual `config.toml`.
#[derive(Debug, Clone)]
pub enum ConfigPersistence {
    /// Persist through the tracked user file, preserving comments and refusing
    /// to overwrite edits made after startup.
    UserFile(ConfigFile),
    /// A load error made the config unsafe to write for this process lifetime.
    ReadOnly(String),
    /// Keep changes in the in-memory [`Config`] only.
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "test-only persistence boundary")
    )]
    MemoryOnly,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ConfigIssue {
    Persistence(String),
    Reload(String),
}

impl ConfigIssue {
    fn message(&self) -> &str {
        match self {
            Self::Persistence(message) | Self::Reload(message) => message,
        }
    }
}

/// Owns the live and last-persisted revisions as one rollback boundary.
pub(super) struct ConfigState {
    current: Config,
    persisted: Config,
    persistence: ConfigPersistence,
    issue: Option<ConfigIssue>,
}

impl ConfigState {
    pub(super) fn new(current: Config, persistence: ConfigPersistence) -> Self {
        let issue = match &persistence {
            ConfigPersistence::ReadOnly(error) => Some(ConfigIssue::Persistence(error.clone())),
            ConfigPersistence::UserFile(_) | ConfigPersistence::MemoryOnly => None,
        };
        let persisted = current.clone();
        Self {
            current,
            persisted,
            persistence,
            issue,
        }
    }

    pub(super) fn issue(&self) -> Option<&str> {
        self.issue.as_ref().map(ConfigIssue::message)
    }

    pub(super) fn should_reload_agent(&self) -> bool {
        self.issue.is_none() && matches!(&self.persistence, ConfigPersistence::UserFile(_))
    }

    /// The revision of `config.toml` as this process last loaded or saved
    /// it. Without a user file there is no such file, so the revision matches
    /// no file the agent reads.
    pub(super) fn revision(&self) -> ConfigRevision {
        match &self.persistence {
            ConfigPersistence::UserFile(file) => file.revision(),
            ConfigPersistence::ReadOnly(_) | ConfigPersistence::MemoryOnly => {
                ConfigRevision::default()
            }
        }
    }

    /// Scope an uncommitted edit to this rollback boundary. Runtime callers
    /// must follow it with the appropriate `AppState` persistence path; startup
    /// migration and tests are the only intentional in-memory-only callers.
    pub(super) fn edit<R>(&mut self, edit: impl FnOnce(&mut Config) -> R) -> R {
        edit(&mut self.current)
    }

    /// Take in a `[flow]` section another writer saved to `config.toml`
    /// (the agent adding a peer it just paired, say), when that is the only
    /// change on disk and nothing here is unsaved. Without this every later
    /// save from this process would be refused as a conflict. Returns whether
    /// the live config changed.
    pub(super) fn adopt_flow_from_disk(&mut self) -> bool {
        let ConfigPersistence::UserFile(file) = &self.persistence else {
            return false;
        };
        let Ok((disk, reloaded)) = ConfigFile::load_from_path(file.path()) else {
            return false;
        };
        if reloaded.revision() == file.revision() || !same_config(&self.current, &self.persisted) {
            return false;
        }
        let Some(flow) = adoptable_flow(&self.persisted, &disk) else {
            return false;
        };
        self.current.flow = flow.clone();
        self.persisted.flow = flow;
        self.persistence = ConfigPersistence::UserFile(reloaded);
        true
    }

    /// Persist the live revision, restoring the last persisted one on failure.
    pub(super) fn persist(&mut self, what: &str) -> bool {
        let result = match &mut self.persistence {
            ConfigPersistence::UserFile(file) => file.save(&self.current),
            ConfigPersistence::ReadOnly(_) => {
                self.restore();
                return false;
            }
            ConfigPersistence::MemoryOnly => Ok(()),
        };
        if let Err(error) = result {
            warn!(error = %error, what, "could not persist to config.toml");
            self.issue = Some(ConfigIssue::Persistence(error.to_string()));
            self.restore();
            return false;
        }
        self.persisted.clone_from(&self.current);
        if matches!(&self.issue, Some(ConfigIssue::Persistence(_))) {
            self.issue = None;
        }
        true
    }

    pub(super) fn apply_reload_result(
        &mut self,
        result: Result<(), openlogi_ipc::ConfigReloadError>,
    ) -> bool {
        let next = match result {
            Err(error) => Some(ConfigIssue::Reload(error.message)),
            Ok(()) if matches!(&self.issue, Some(ConfigIssue::Reload(_))) => None,
            Ok(()) => return false,
        };
        if self.issue == next {
            return false;
        }
        self.issue = next;
        true
    }

    fn restore(&mut self) {
        self.current.clone_from(&self.persisted);
    }
}

impl Deref for ConfigState {
    type Target = Config;

    fn deref(&self) -> &Self::Target {
        &self.current
    }
}

fn same_config(left: &Config, right: &Config) -> bool {
    match (serde_json::to_value(left), serde_json::to_value(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

/// `disk`'s `[flow]` section, when it is the only way `disk` differs from
/// `persisted`.
fn adoptable_flow(persisted: &Config, disk: &Config) -> Option<openlogi_core::config::FlowConfig> {
    if disk.flow == persisted.flow {
        return None;
    }
    let mut merged = persisted.clone();
    merged.flow = disk.flow.clone();
    same_config(&merged, disk).then(|| disk.flow.clone())
}

#[cfg(test)]
mod tests {
    use openlogi_core::config::FlowPeer;

    use super::*;

    fn with_peer(mut config: Config) -> Config {
        config.flow.peers.push(FlowPeer {
            name: "desk".into(),
            public_key: format!("ed25519:{}", "ab".repeat(32)),
            addresses: vec!["desk.local".into()],
        });
        config
    }

    #[test]
    fn only_a_flow_only_change_on_disk_is_adopted() {
        let persisted = Config::ephemeral();
        assert!(adoptable_flow(&persisted, &persisted).is_none());

        let paired = with_peer(persisted.clone());
        assert_eq!(
            adoptable_flow(&persisted, &paired).map(|flow| flow.peers.len()),
            Some(1)
        );

        let mut also_other = paired;
        also_other.app_settings.launch_at_login = !persisted.app_settings.launch_at_login;
        assert!(adoptable_flow(&persisted, &also_other).is_none());
    }

    #[test]
    fn a_paired_peer_saved_by_another_writer_is_taken_in_and_saves_continue() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join(openlogi_core::paths::CONFIG_FILE);
        let (config, file) = ConfigFile::load_from_path(&path).unwrap();
        let mut state = ConfigState::new(config, ConfigPersistence::UserFile(file));
        assert!(state.persist("seed"));
        assert!(!state.adopt_flow_from_disk());

        // The agent pairs a peer and saves through its own handle.
        let (disk, mut agent) = ConfigFile::load_from_path(&path).unwrap();
        agent.save(&with_peer(disk)).unwrap();

        assert!(state.adopt_flow_from_disk());
        assert_eq!(state.flow.peers.len(), 1);
        state.edit(|config| config.flow.require_modifier = true);
        assert!(
            state.persist("after adoption"),
            "no conflict after adoption"
        );
    }
}
