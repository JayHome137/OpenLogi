//! Flow clipboard synchronization for text and file-list representations.
//!
//! The peer protocol owns framing and capability negotiation. This module owns
//! the host clipboard boundary and the generation/loop-prevention rules around
//! it so those decisions do not leak into the transport or GUI layers.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::UNIX_EPOCH;

use buffa::Message;
use openlogi_flow::generated as proto;
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "macos")]
use self::macos::MacClipboard;
#[cfg(target_os = "windows")]
use self::windows::WindowsClipboard;

/// The text representation used by the v1 Flow clipboard capability.
pub(crate) const TEXT_MIME: &str = "text/plain;charset=utf-8";
pub(crate) const FILES_MIME: &str = "application/x-openlogi-files";
pub(super) const MAX_CLIPBOARD_BYTES: usize = 64 * 1024 * 1024;
const MAX_FILE_COUNT: usize = 256;
pub(super) const MAX_FILE_BYTES: u64 = 512 * 1024 * 1024;
pub(super) const MAX_FILE_LIST_BYTES: usize = 1024 * 1024;

/// Host boundary for the system clipboard.
pub(crate) trait ClipboardBackend: Send + Sync {
    /// Returns the current UTF-8 text, if the host clipboard has one.
    fn read_text(&self) -> Option<Vec<u8>>;
    /// Replaces the host clipboard with UTF-8 text.
    fn write_text(&self, bytes: &[u8]) -> Result<(), String>;
    /// Returns paths currently represented by a file clipboard, if supported.
    fn read_files(&self) -> Option<Vec<PathBuf>> {
        None
    }
    /// Places downloaded files under the platform download directory and makes
    /// those paths the current file clipboard contents.
    fn write_files(&self, _files: &[(String, Vec<u8>)]) -> Result<(), String> {
        Err("file clipboard is unsupported on this host".to_owned())
    }
}

enum PreparedClipboard {
    Text(Vec<u8>),
    Files {
        files: Vec<(String, Vec<u8>)>,
        identity_digest: [u8; 32],
    },
}

enum ClipboardSuppression {
    Text([u8; 32]),
    Files([u8; 32]),
}

struct ClipboardPasteBridge {
    backend: Arc<dyn ClipboardBackend>,
    prepared: StdMutex<Option<PreparedClipboard>>,
    suppression: StdMutex<Option<ClipboardSuppression>>,
}

impl ClipboardPasteBridge {
    fn new(backend: Arc<dyn ClipboardBackend>) -> Self {
        Self {
            backend,
            prepared: StdMutex::new(None),
            suppression: StdMutex::new(None),
        }
    }

    fn stage(&self, prepared: PreparedClipboard) {
        if let Ok(mut current) = self.prepared.lock() {
            *current = Some(prepared);
        }
    }

    fn clear_prepared(&self) {
        if let Ok(mut prepared) = self.prepared.lock() {
            *prepared = None;
        }
    }

    fn apply(&self) -> bool {
        let prepared = self.prepared.lock().ok().and_then(|mut value| value.take());
        let Some(prepared) = prepared else {
            return false;
        };
        match prepared {
            PreparedClipboard::Text(bytes) => {
                let hash = digest(&bytes);
                if self.backend.write_text(&bytes).is_err() {
                    self.stage(PreparedClipboard::Text(bytes));
                    return false;
                }
                if let Ok(mut suppression) = self.suppression.lock() {
                    *suppression = Some(ClipboardSuppression::Text(hash));
                }
            }
            PreparedClipboard::Files {
                files,
                identity_digest,
            } => {
                if self.backend.write_files(&files).is_err() {
                    self.stage(PreparedClipboard::Files {
                        files,
                        identity_digest,
                    });
                    return false;
                }
                // A collision may make the backend rename a received file. If
                // so, suppress the identity that the host clipboard actually
                // exposes instead of the remote name-only identity.
                let actual_digest = self
                    .backend
                    .read_files()
                    .and_then(collect_files)
                    .map_or(identity_digest, |files| files.identity_digest);
                if let Ok(mut suppression) = self.suppression.lock() {
                    *suppression = Some(ClipboardSuppression::Files(actual_digest));
                }
            }
        }
        true
    }

    fn take_text_suppression(&self, hash: [u8; 32]) -> bool {
        let Ok(mut suppression) = self.suppression.lock() else {
            return false;
        };
        if matches!(*suppression, Some(ClipboardSuppression::Text(expected)) if expected == hash) {
            *suppression = None;
            true
        } else {
            false
        }
    }

    fn take_file_suppression(&self, identity_digest: [u8; 32]) -> bool {
        let Ok(mut suppression) = self.suppression.lock() else {
            return false;
        };
        if matches!(*suppression, Some(ClipboardSuppression::Files(expected)) if expected == identity_digest)
        {
            *suppression = None;
            true
        } else {
            false
        }
    }
}

/// Creates the host backend used by the production agent.
pub(crate) fn default_backend() -> Arc<dyn ClipboardBackend> {
    #[cfg(target_os = "macos")]
    {
        Arc::new(MacClipboard)
    }
    #[cfg(target_os = "windows")]
    {
        Arc::new(WindowsClipboard)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        Arc::new(UnsupportedClipboard)
    }
}

/// A clipboard generation that can be served to a peer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LocalClipboard {
    pub(crate) sequence: u64,
    pub(crate) bytes: Vec<u8>,
    pub(crate) sha256: [u8; 32],
}

#[derive(Clone, Debug)]
struct LocalFile {
    path: PathBuf,
    entry: proto::FileEntry,
}

#[derive(Clone, Debug)]
struct LocalFileSet {
    sequence: u64,
    list: proto::FileList,
    files: Vec<LocalFile>,
    digest: [u8; 32],
    change_digest: [u8; 32],
    identity_digest: [u8; 32],
}

impl LocalClipboard {
    fn announce(&self) -> proto::ClipboardAnnounce {
        let mut format = proto::ClipboardFormat {
            mime: TEXT_MIME.to_owned(),
            size_bytes: u64::try_from(self.bytes.len()).unwrap_or(u64::MAX),
            ..Default::default()
        };
        format.sha256 = Some(self.sha256.to_vec());
        proto::ClipboardAnnounce {
            sequence: self.sequence,
            formats: vec![format],
            ..Default::default()
        }
    }
}

#[derive(Clone, Debug)]
struct RemoteClipboard {
    order: u64,
    sequence: u64,
    mime: String,
    size_bytes: u64,
    sha256: Option<[u8; 32]>,
    buffer: Option<Vec<u8>>,
    received: Vec<(usize, usize)>,
    consumed: bool,
}

#[derive(Default)]
struct ClipboardState {
    local: Option<LocalClipboard>,
    local_files: Option<LocalFileSet>,
    remote: std::collections::HashMap<openlogi_flow::sas::PublicKey, RemoteClipboard>,
    next_remote_order: u64,
}

/// Stateful clipboard owner shared by the generation's connection tasks.
pub(crate) struct ClipboardManager {
    backend: Arc<dyn ClipboardBackend>,
    paste_bridge: Arc<ClipboardPasteBridge>,
    state: Mutex<ClipboardState>,
}

impl ClipboardManager {
    pub(crate) fn new(backend: Arc<dyn ClipboardBackend>) -> Self {
        Self {
            paste_bridge: Arc::new(ClipboardPasteBridge::new(Arc::clone(&backend))),
            backend,
            state: Mutex::new(ClipboardState::default()),
        }
    }

    /// Applies a prefetched remote clipboard value during the input-hook
    /// callback, before the host application handles Cmd/Ctrl+V.
    pub(crate) fn apply_staged(&self) -> bool {
        self.paste_bridge.apply()
    }

    /// Reads the host clipboard and returns a new announcement only when text
    /// changed. A write caused by a remote peer is consumed without rebroadcast.
    pub(crate) async fn poll_local(&self) -> Option<proto::ClipboardAnnounce> {
        if let Some(paths) = self.backend.read_files()
            && let Some(files) = collect_files(paths)
        {
            let mut state = self.state.lock().await;
            let changed = state
                .local_files
                .as_ref()
                .is_none_or(|local| local.change_digest != files.change_digest);
            if !changed {
                return None;
            }
            self.paste_bridge.clear_prepared();
            state.remote.clear();
            state.local = None;
            let sequence = next_sequence(&mut state);
            let files = LocalFileSet { sequence, ..files };
            if self
                .paste_bridge
                .take_file_suppression(files.identity_digest)
            {
                state.local_files = Some(files);
                return None;
            }
            let announce = announce_files(&files);
            state.local_files = Some(files);
            return Some(announce);
        }
        let bytes = self.backend.read_text()?;
        if bytes.len() > MAX_CLIPBOARD_BYTES {
            return None;
        }
        let hash = digest(&bytes);
        let mut state = self.state.lock().await;
        let changed = state
            .local
            .as_ref()
            .is_none_or(|local| local.sha256 != hash)
            || state.local_files.is_some();
        if !changed {
            return None;
        }
        self.paste_bridge.clear_prepared();
        state.remote.clear();
        state.local_files = None;
        if self.paste_bridge.take_text_suppression(hash) {
            state.local = Some(next_local(next_sequence(&mut state), bytes, hash));
            return None;
        }
        state.local = Some(next_local(next_sequence(&mut state), bytes, hash));
        state.local.as_ref().map(LocalClipboard::announce)
    }

    /// Returns the requested local slice after validating its sequence, MIME,
    /// and offset.
    pub(crate) async fn fetch(
        &self,
        sequence: u64,
        mime: &str,
        offset: u64,
    ) -> Result<(LocalClipboard, Vec<u8>), ClipboardError> {
        if mime != TEXT_MIME {
            return Err(ClipboardError::UnsupportedMime);
        }
        let state = self.state.lock().await;
        let Some(local) = state.local.clone() else {
            return Err(ClipboardError::Unavailable);
        };
        if local.sequence != sequence {
            return Err(ClipboardError::StaleSequence);
        }
        let offset = usize::try_from(offset).map_err(|_| ClipboardError::InvalidOffset)?;
        if offset > local.bytes.len() {
            return Err(ClipboardError::InvalidOffset);
        }
        Ok((local.clone(), local.bytes[offset..].to_vec()))
    }

    /// Returns the serialized file list for a local generation.
    pub(crate) async fn fetch_file_list(
        &self,
        sequence: u64,
        offset: u64,
    ) -> Result<(u64, u64, Vec<u8>), ClipboardError> {
        let state = self.state.lock().await;
        let Some(files) = state.local_files.as_ref() else {
            return Err(ClipboardError::Unavailable);
        };
        if files.sequence != sequence {
            return Err(ClipboardError::StaleSequence);
        }
        let bytes = encode_message(&files.list)?;
        let offset = usize::try_from(offset).map_err(|_| ClipboardError::InvalidOffset)?;
        if offset > bytes.len() {
            return Err(ClipboardError::InvalidOffset);
        }
        Ok((files.sequence, bytes.len() as u64, bytes[offset..].to_vec()))
    }

    /// Returns one local file slice for a `FileFetch` request.
    pub(crate) async fn fetch_file(
        &self,
        sequence: u64,
        file_index: u32,
        offset: u64,
    ) -> Result<(u64, u64, Vec<u8>), ClipboardError> {
        let state = self.state.lock().await;
        let Some(files) = state.local_files.as_ref() else {
            return Err(ClipboardError::Unavailable);
        };
        if files.sequence != sequence {
            return Err(ClipboardError::StaleSequence);
        }
        let index = usize::try_from(file_index).map_err(|_| ClipboardError::InvalidFile)?;
        let Some(file) = files.files.get(index) else {
            return Err(ClipboardError::InvalidFile);
        };
        let metadata = std::fs::metadata(&file.path)
            .map_err(|error| ClipboardError::Backend(error.to_string()))?;
        let modified_at_ms = file_modified_at_ms(&metadata);
        if !metadata.is_file()
            || metadata.len() != file.entry.size_bytes
            || modified_at_ms != file.entry.modified_at_ms
            || metadata.len() > MAX_FILE_BYTES
        {
            return Err(ClipboardError::StaleSequence);
        }
        let bytes = std::fs::read(&file.path)
            .map_err(|error| ClipboardError::Backend(error.to_string()))?;
        if bytes.len() as u64 != file.entry.size_bytes {
            return Err(ClipboardError::StaleSequence);
        }
        let offset = usize::try_from(offset).map_err(|_| ClipboardError::InvalidOffset)?;
        if offset > bytes.len() {
            return Err(ClipboardError::InvalidOffset);
        }
        Ok((
            files.sequence,
            file.entry.size_bytes,
            bytes[offset..].to_vec(),
        ))
    }

    /// Records a remote announce and returns the fetch descriptor only for a
    /// fresh, valid text generation.
    pub(crate) async fn accept_announce(
        &self,
        peer: openlogi_flow::sas::PublicKey,
        announce: &proto::ClipboardAnnounce,
    ) -> Option<(u64, String)> {
        if announce.sequence == 0 {
            return None;
        }
        let format = announce
            .formats
            .iter()
            .find(|format| format.mime == TEXT_MIME || format.mime == FILES_MIME)?;
        let max_size = if format.mime == FILES_MIME {
            MAX_FILE_LIST_BYTES as u64
        } else {
            MAX_CLIPBOARD_BYTES as u64
        };
        if format.size_bytes > max_size {
            return None;
        }
        let sha256 = match format.sha256.as_deref() {
            None => None,
            Some(bytes) => Some(<[u8; 32]>::try_from(bytes).ok()?),
        };
        let mut state = self.state.lock().await;
        if state
            .remote
            .get(&peer)
            .is_some_and(|remote| announce.sequence <= remote.sequence)
        {
            return None;
        }
        state.next_remote_order = state.next_remote_order.saturating_add(1).max(1);
        let order = state.next_remote_order;
        state.remote.insert(
            peer,
            RemoteClipboard {
                order,
                sequence: announce.sequence,
                mime: format.mime.clone(),
                size_bytes: format.size_bytes,
                sha256,
                buffer: None,
                received: Vec::new(),
                consumed: false,
            },
        );
        Some((announce.sequence, format.mime.clone()))
    }

    /// Drops all announced generations owned by a disconnected peer.
    pub(crate) async fn forget_peer(&self, peer: openlogi_flow::sas::PublicKey) {
        self.state.lock().await.remote.remove(&peer);
    }

    /// Clears all peer-owned staged data when a Flow generation is replaced.
    /// Local clipboard generations remain so a config reload does not emit a
    /// duplicate local announcement.
    pub(crate) async fn reset_remote(&self) {
        self.paste_bridge.clear_prepared();
        if let Ok(mut suppression) = self.paste_bridge.suppression.lock() {
            *suppression = None;
        }
        self.state.lock().await.remote.clear();
    }

    /// Select the newest announced representation that has not been prefetched.
    /// This remains the fallback when a paste arrives before announce-triggered
    /// prefetching has completed.
    pub(crate) async fn pending_fetch(
        &self,
    ) -> Option<(openlogi_flow::sas::PublicKey, u64, String, u64)> {
        let state = self.state.lock().await;
        state
            .remote
            .iter()
            .filter(|(_, remote)| !remote.consumed)
            .max_by_key(|(_, remote)| remote.order)
            .map(|(peer, remote)| {
                let offset = remote
                    .received
                    .first()
                    .filter(|(start, _)| *start == 0)
                    .map_or(0, |(_, end)| *end);
                (*peer, remote.sequence, remote.mime.clone(), offset as u64)
            })
    }

    /// Validates and stages a fetched remote generation. The hash is checked
    /// against both the announce and the transfer terminator when present;
    /// the host clipboard is updated only by [`Self::apply_staged`].
    pub(crate) async fn apply_remote(
        &self,
        peer: openlogi_flow::sas::PublicKey,
        sequence: u64,
        offset: u64,
        bytes: Vec<u8>,
        transfer_hash: Option<[u8; 32]>,
    ) -> Result<(), ClipboardError> {
        self.apply_remote_chunk(peer, sequence, offset, &bytes)
            .await?;
        let mut state = self.state.lock().await;
        let Some(remote) = state.remote.get_mut(&peer) else {
            return Err(ClipboardError::StaleSequence);
        };
        if remote.sequence != sequence || remote.consumed {
            return Err(ClipboardError::StaleSequence);
        }
        if remote.mime != TEXT_MIME {
            return Err(ClipboardError::UnsupportedMime);
        }
        let Some(buffer) = remote.buffer.as_ref() else {
            return Err(ClipboardError::Unavailable);
        };
        if transfer_hash.is_some_and(|expected| expected != digest(&bytes)) {
            return Err(ClipboardError::ChecksumMismatch);
        }
        if remote.received.len() != 1
            || remote.received[0] != (0, buffer.len())
            || remote
                .sha256
                .is_some_and(|expected| expected != digest(buffer))
        {
            return Ok(());
        }
        let bytes = remote.buffer.take().unwrap_or_default();
        remote.consumed = true;
        self.paste_bridge.stage(PreparedClipboard::Text(bytes));
        Ok(())
    }

    /// Stores one validated text slice without committing the host clipboard.
    ///
    /// The caller can invoke this for every received bulk chunk. If the
    /// transport ends before its terminator, the contiguous prefix is retained
    /// and [`Self::pending_fetch`] can request only the missing suffix later.
    pub(crate) async fn apply_remote_chunk(
        &self,
        peer: openlogi_flow::sas::PublicKey,
        sequence: u64,
        offset: u64,
        bytes: &[u8],
    ) -> Result<(), ClipboardError> {
        if bytes.len() > MAX_CLIPBOARD_BYTES {
            return Err(ClipboardError::TooLarge);
        }
        let mut state = self.state.lock().await;
        let Some(remote) = state.remote.get_mut(&peer) else {
            return Err(ClipboardError::StaleSequence);
        };
        if remote.sequence != sequence {
            return Err(ClipboardError::StaleSequence);
        }
        if remote.consumed {
            return Err(ClipboardError::StaleSequence);
        }
        if remote.mime != TEXT_MIME {
            return Err(ClipboardError::UnsupportedMime);
        }
        let offset = usize::try_from(offset).map_err(|_| ClipboardError::InvalidOffset)?;
        let size = usize::try_from(remote.size_bytes).map_err(|_| ClipboardError::TooLarge)?;
        let end = offset
            .checked_add(bytes.len())
            .ok_or(ClipboardError::InvalidOffset)?;
        if end > size {
            return Err(ClipboardError::InvalidOffset);
        }
        let buffer = remote.buffer.get_or_insert_with(|| vec![0; size]);
        buffer[offset..end].copy_from_slice(bytes);
        add_received_range(&mut remote.received, offset, end);
        Ok(())
    }

    /// Validates a fetched remote file list before individual files are read.
    pub(crate) async fn validate_remote_file_list(
        &self,
        peer: openlogi_flow::sas::PublicKey,
        sequence: u64,
        bytes: &[u8],
        transfer_hash: Option<[u8; 32]>,
    ) -> Result<Vec<proto::FileEntry>, ClipboardError> {
        let mut state = self.state.lock().await;
        let Some(remote) = state.remote.get_mut(&peer) else {
            return Err(ClipboardError::StaleSequence);
        };
        if remote.sequence != sequence || remote.mime != FILES_MIME || remote.consumed {
            return Err(ClipboardError::StaleSequence);
        }
        if bytes.len() > MAX_FILE_LIST_BYTES {
            return Err(ClipboardError::TooLarge);
        }
        if bytes.len() as u64 != remote.size_bytes {
            return Err(ClipboardError::ChecksumMismatch);
        }
        if transfer_hash.is_some_and(|expected| expected != digest(bytes)) {
            return Err(ClipboardError::ChecksumMismatch);
        }
        if remote
            .sha256
            .is_some_and(|expected| expected != digest(bytes))
        {
            return Err(ClipboardError::ChecksumMismatch);
        }
        let list = proto::FileList::decode_from_slice(bytes)
            .map_err(|_| ClipboardError::InvalidFileList)?;
        validate_file_entries(&list.files)?;
        remote.buffer = Some(bytes.to_vec());
        Ok(list.files)
    }

    /// Stages a validated remote file set and consumes its announced
    /// generation. The host clipboard is updated only by [`Self::apply_staged`].
    pub(crate) async fn apply_remote_files(
        &self,
        peer: openlogi_flow::sas::PublicKey,
        sequence: u64,
        files: Vec<(String, Vec<u8>)>,
        identity_digest: [u8; 32],
    ) -> Result<(), ClipboardError> {
        let mut state = self.state.lock().await;
        let Some(remote) = state.remote.get_mut(&peer) else {
            return Err(ClipboardError::StaleSequence);
        };
        if remote.sequence != sequence || remote.mime != FILES_MIME || remote.consumed {
            return Err(ClipboardError::StaleSequence);
        }
        self.paste_bridge.stage(PreparedClipboard::Files {
            files,
            identity_digest,
        });
        remote.consumed = true;
        Ok(())
    }
}

fn add_received_range(ranges: &mut Vec<(usize, usize)>, start: usize, end: usize) {
    if start == end {
        if ranges.is_empty() {
            ranges.push((0, 0));
        }
        return;
    }
    ranges.push((start, end));
    ranges.sort_unstable_by_key(|(range_start, _)| *range_start);
    let mut merged = Vec::with_capacity(ranges.len());
    for (start, end) in ranges.drain(..) {
        if let Some((_, previous_end)) = merged.last_mut()
            && start <= *previous_end
        {
            *previous_end = (*previous_end).max(end);
        } else {
            merged.push((start, end));
        }
    }
    *ranges = merged;
}

fn next_local(sequence: u64, bytes: Vec<u8>, sha256: [u8; 32]) -> LocalClipboard {
    LocalClipboard {
        sequence,
        bytes,
        sha256,
    }
}

fn next_sequence(state: &mut ClipboardState) -> u64 {
    state
        .local
        .as_ref()
        .map_or(0, |local| local.sequence)
        .max(state.local_files.as_ref().map_or(0, |files| files.sequence))
        .saturating_add(1)
        .max(1)
}

fn collect_files(paths: Vec<PathBuf>) -> Option<LocalFileSet> {
    if paths.is_empty() || paths.len() > MAX_FILE_COUNT {
        return None;
    }
    let mut entries = Vec::with_capacity(paths.len());
    let mut files = Vec::with_capacity(paths.len());
    let mut names = std::collections::HashSet::new();
    let mut total = 0_u64;
    for path in paths {
        let metadata = std::fs::metadata(&path).ok()?;
        if !metadata.is_file() {
            return None;
        }
        let size = metadata.len();
        total = total.checked_add(size)?;
        if total > MAX_FILE_BYTES {
            return None;
        }
        let mut name = path.file_name()?.to_string_lossy().into_owned();
        if name.is_empty() || name.len() > 1024 {
            return None;
        }
        if !names.insert(name.clone()) {
            let stem = Path::new(&name).file_stem().map_or_else(
                || "file".to_owned(),
                |stem| stem.to_string_lossy().into_owned(),
            );
            let extension = Path::new(&name)
                .extension()
                .map_or_else(String::new, |extension| {
                    format!(".{}", extension.to_string_lossy())
                });
            let mut suffix = 2_u32;
            loop {
                let candidate = format!("{stem} ({suffix}){extension}");
                if names.insert(candidate.clone()) {
                    name = candidate;
                    break;
                }
                suffix = suffix.saturating_add(1);
            }
        }
        let modified_at_ms = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |duration| {
                u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
            });
        entries.push(proto::FileEntry {
            relative_path: name,
            size_bytes: size,
            modified_at_ms,
            ..Default::default()
        });
        files.push(LocalFile {
            path,
            entry: entries.last().cloned().unwrap_or_default(),
        });
    }
    let list = proto::FileList {
        files: entries,
        ..Default::default()
    };
    let bytes = encode_message(&list).ok()?;
    if bytes.len() > MAX_FILE_LIST_BYTES {
        return None;
    }
    let change_digest = file_change_digest(&list);
    let identity_digest = file_identity_digest(&list);
    Some(LocalFileSet {
        sequence: 0,
        list,
        files,
        digest: digest(&bytes),
        change_digest,
        identity_digest,
    })
}

fn persist_received_files(files: &[(String, Vec<u8>)]) -> Result<Vec<PathBuf>, String> {
    validate_file_payloads(files)?;
    let root = openlogi_core::paths::data_dir()
        .map_err(|error| error.to_string())?
        .join("flow")
        .join("received");
    std::fs::create_dir_all(&root).map_err(|error| error.to_string())?;
    let mut written = Vec::with_capacity(files.len());
    for (relative_path, bytes) in files {
        let name = Path::new(relative_path)
            .file_name()
            .filter(|_| Path::new(relative_path).components().count() == 1)
            .ok_or_else(|| "file name is not a safe relative path".to_owned())?;
        let stem = Path::new(name)
            .file_stem()
            .unwrap_or(name)
            .to_string_lossy();
        let extension = Path::new(name)
            .extension()
            .map(|extension| format!(".{}", extension.to_string_lossy()))
            .unwrap_or_default();
        let mut suffix = 1_u32;
        let destination = loop {
            let candidate_name = if suffix == 1 {
                name.to_string_lossy().into_owned()
            } else {
                format!("{stem} ({suffix}){extension}")
            };
            let candidate = root.join(candidate_name);
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&candidate)
            {
                Ok(mut file) => {
                    if let Err(error) = std::io::Write::write_all(&mut file, bytes) {
                        let _ = std::fs::remove_file(&candidate);
                        for path in &written {
                            let _ = std::fs::remove_file(path);
                        }
                        return Err(error.to_string());
                    }
                    break candidate;
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    suffix = suffix.saturating_add(1);
                }
                Err(error) => return Err(error.to_string()),
            }
        };
        written.push(destination);
    }
    Ok(written)
}

fn announce_files(files: &LocalFileSet) -> proto::ClipboardAnnounce {
    let bytes = encode_message(&files.list).unwrap_or_default();
    proto::ClipboardAnnounce {
        sequence: files.sequence,
        formats: vec![proto::ClipboardFormat {
            mime: FILES_MIME.to_owned(),
            size_bytes: bytes.len() as u64,
            sha256: Some(files.digest.to_vec()),
            ..Default::default()
        }],
        ..Default::default()
    }
}

fn encode_message(message: &impl Message) -> Result<Vec<u8>, ClipboardError> {
    message
        .try_encode_to_vec()
        .map_err(|_| ClipboardError::InvalidFileList)
}

fn validate_file_entries(entries: &[proto::FileEntry]) -> Result<(), ClipboardError> {
    if entries.is_empty() || entries.len() > MAX_FILE_COUNT {
        return Err(ClipboardError::InvalidFileList);
    }
    let mut total = 0_u64;
    let mut paths = std::collections::HashSet::new();
    for entry in entries {
        if !is_safe_file_name(&entry.relative_path) || !paths.insert(entry.relative_path.clone()) {
            return Err(ClipboardError::InvalidFileList);
        }
        total = total
            .checked_add(entry.size_bytes)
            .ok_or(ClipboardError::TooLarge)?;
        if total > MAX_FILE_BYTES {
            return Err(ClipboardError::TooLarge);
        }
    }
    Ok(())
}

fn validate_file_payloads(files: &[(String, Vec<u8>)]) -> Result<(), String> {
    if files.is_empty() || files.len() > MAX_FILE_COUNT {
        return Err("file list has an invalid number of files".to_owned());
    }
    let mut names = std::collections::HashSet::with_capacity(files.len());
    let mut total = 0_u64;
    for (name, bytes) in files {
        if !is_safe_file_name(name) || !names.insert(name) {
            return Err("file list contains an unsafe or duplicate name".to_owned());
        }
        total = total
            .checked_add(u64::try_from(bytes.len()).map_err(|_| "file is too large".to_owned())?)
            .ok_or_else(|| "file list is too large".to_owned())?;
        if total > MAX_FILE_BYTES {
            return Err("file list is too large".to_owned());
        }
    }
    Ok(())
}

fn is_safe_file_name(name: &str) -> bool {
    let path = Path::new(name);
    !name.is_empty()
        && name.len() <= 1024
        && !name.contains('\\')
        && !name.contains(':')
        && !name.contains('\0')
        && !path.is_absolute()
        && matches!(
            path.components().collect::<Vec<_>>().as_slice(),
            [std::path::Component::Normal(_)]
        )
}

pub(super) fn file_identity_digest(list: &proto::FileList) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for entry in &list.files {
        hasher.update(entry.relative_path.as_bytes());
        hasher.update([0]);
        hasher.update(entry.size_bytes.to_le_bytes());
    }
    hasher.finalize().into()
}

fn file_change_digest(list: &proto::FileList) -> [u8; 32] {
    let mut hasher = Sha256::new();
    for entry in &list.files {
        hasher.update(entry.relative_path.as_bytes());
        hasher.update([0]);
        hasher.update(entry.size_bytes.to_le_bytes());
        hasher.update(entry.modified_at_ms.to_le_bytes());
    }
    hasher.finalize().into()
}

fn file_modified_at_ms(metadata: &std::fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |duration| {
            u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
        })
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

/// Errors returned by the application-level clipboard contract.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub(crate) enum ClipboardError {
    #[error("clipboard representation is not supported")]
    UnsupportedMime,
    #[error("clipboard is unavailable")]
    Unavailable,
    #[error("clipboard generation is stale")]
    StaleSequence,
    #[error("clipboard offset is invalid")]
    InvalidOffset,
    #[error("clipboard payload is too large")]
    TooLarge,
    #[error("clipboard checksum does not match")]
    ChecksumMismatch,
    #[error("clipboard file index is invalid")]
    InvalidFile,
    #[error("clipboard file list is invalid")]
    InvalidFileList,
    #[error("clipboard backend failed: {0}")]
    Backend(String),
}

#[cfg_attr(
    any(target_os = "macos", target_os = "windows"),
    expect(
        dead_code,
        reason = "fallback backend is only constructed on unsupported hosts"
    )
)]
#[derive(Debug, Default)]
struct UnsupportedClipboard;

impl ClipboardBackend for UnsupportedClipboard {
    fn read_text(&self) -> Option<Vec<u8>> {
        None
    }

    fn write_text(&self, _bytes: &[u8]) -> Result<(), String> {
        Err("clipboard is unsupported on this host".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex as StdMutex;

    use super::*;

    #[derive(Default)]
    struct MemoryClipboard {
        value: StdMutex<Option<Vec<u8>>>,
    }

    impl ClipboardBackend for MemoryClipboard {
        fn read_text(&self) -> Option<Vec<u8>> {
            self.value.lock().ok().and_then(|value| value.clone())
        }

        fn write_text(&self, bytes: &[u8]) -> Result<(), String> {
            *self.value.lock().map_err(|_| "poisoned".to_owned())? = Some(bytes.to_vec());
            Ok(())
        }
    }

    #[tokio::test]
    async fn generations_reject_stale_and_invalid_offsets() {
        let backend = Arc::new(MemoryClipboard::default());
        *backend.value.lock().unwrap() = Some(b"hello world".to_vec());
        let manager = ClipboardManager::new(backend);
        let announce = manager
            .poll_local()
            .await
            .expect("first clipboard announcement");
        assert_eq!(announce.sequence, 1);
        let (local, bytes) = manager.fetch(1, TEXT_MIME, 6).await.expect("valid fetch");
        assert_eq!(bytes, b"world");
        assert_eq!(local.bytes, b"hello world");
        assert_eq!(
            manager.fetch(0, TEXT_MIME, 0).await,
            Err(ClipboardError::StaleSequence)
        );
        assert_eq!(
            manager.fetch(1, TEXT_MIME, 99).await,
            Err(ClipboardError::InvalidOffset)
        );
    }

    #[tokio::test]
    async fn remote_write_is_not_reannounced() {
        let backend = Arc::new(MemoryClipboard::default());
        *backend.value.lock().unwrap() = Some(b"local".to_vec());
        let manager = ClipboardManager::new(Arc::clone(&backend) as Arc<dyn ClipboardBackend>);
        let _ = manager.poll_local().await.expect("local announcement");
        let remote = proto::ClipboardAnnounce {
            sequence: 9,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: 6,
                sha256: Some(digest(b"remote").to_vec()),
                ..Default::default()
            }],
            ..Default::default()
        };
        let peer = openlogi_flow::sas::PublicKey::new([7; 32]);
        assert_eq!(
            manager.accept_announce(peer, &remote).await,
            Some((9, TEXT_MIME.to_owned()))
        );
        assert_eq!(
            manager.pending_fetch().await,
            Some((peer, 9, TEXT_MIME.to_owned(), 0))
        );
        assert_eq!(backend.read_text(), Some(b"local".to_vec()));
        manager
            .apply_remote(peer, 9, 0, b"remote".to_vec(), Some(digest(b"remote")))
            .await
            .expect("remote clipboard write");
        assert_eq!(manager.pending_fetch().await, None);
        assert_eq!(backend.read_text(), Some(b"local".to_vec()));
        assert!(manager.apply_staged());
        assert_eq!(manager.poll_local().await, None);
        assert_eq!(backend.read_text(), Some(b"remote".to_vec()));
    }

    #[tokio::test]
    async fn empty_remote_clipboard_is_committed() {
        let backend = Arc::new(MemoryClipboard::default());
        let manager = ClipboardManager::new(Arc::clone(&backend) as Arc<dyn ClipboardBackend>);
        let peer = openlogi_flow::sas::PublicKey::new([11; 32]);
        let announce = proto::ClipboardAnnounce {
            sequence: 1,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: 0,
                sha256: Some(digest(&[]).to_vec()),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(manager.accept_announce(peer, &announce).await.is_some());
        manager
            .apply_remote(peer, 1, 0, Vec::new(), Some(digest(&[])))
            .await
            .expect("empty remote clipboard write");
        assert!(manager.apply_staged());
        assert_eq!(backend.read_text(), Some(Vec::new()));
        assert_eq!(manager.pending_fetch().await, None);
    }

    #[tokio::test]
    async fn announces_with_malformed_hash_are_ignored() {
        let manager = ClipboardManager::new(Arc::new(MemoryClipboard::default()));
        let peer = openlogi_flow::sas::PublicKey::new([8; 32]);
        let announce = proto::ClipboardAnnounce {
            sequence: 1,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: 3,
                sha256: Some(vec![0; 31]),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert_eq!(manager.accept_announce(peer, &announce).await, None);
    }

    #[tokio::test]
    async fn remote_size_and_checksum_are_verified_before_write() {
        let backend = Arc::new(MemoryClipboard::default());
        let manager = ClipboardManager::new(Arc::clone(&backend) as Arc<dyn ClipboardBackend>);
        let peer = openlogi_flow::sas::PublicKey::new([9; 32]);
        let announce = proto::ClipboardAnnounce {
            sequence: 4,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: 6,
                sha256: Some(digest(b"remote").to_vec()),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(manager.accept_announce(peer, &announce).await.is_some());
        manager
            .apply_remote(peer, 4, 0, b"short".to_vec(), Some(digest(b"short")))
            .await
            .expect("partial data can be resumed");
        assert_eq!(backend.read_text(), None);
        assert_eq!(
            manager
                .apply_remote(peer, 4, 0, b"remote".to_vec(), Some(digest(b"wrong")))
                .await,
            Err(ClipboardError::ChecksumMismatch)
        );
        assert_eq!(backend.read_text(), None);
    }

    #[tokio::test]
    async fn remote_clipboard_can_resume_from_a_nonzero_offset() {
        let backend = Arc::new(MemoryClipboard::default());
        let manager = ClipboardManager::new(Arc::clone(&backend) as Arc<dyn ClipboardBackend>);
        let peer = openlogi_flow::sas::PublicKey::new([10; 32]);
        let full = b"hello world";
        let announce = proto::ClipboardAnnounce {
            sequence: 5,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: full.len() as u64,
                sha256: Some(digest(full).to_vec()),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(manager.accept_announce(peer, &announce).await.is_some());
        manager
            .apply_remote(peer, 5, 6, b"world".to_vec(), Some(digest(b"world")))
            .await
            .expect("suffix should be accepted");
        assert_eq!(backend.read_text(), None);
        manager
            .apply_remote(peer, 5, 0, b"hello ".to_vec(), Some(digest(b"hello ")))
            .await
            .expect("prefix should complete the resumed transfer");
        assert!(manager.apply_staged());
        assert_eq!(backend.read_text(), Some(full.to_vec()));
    }

    #[tokio::test]
    async fn pending_fetch_resumes_a_contiguous_prefix() {
        let backend = Arc::new(MemoryClipboard::default());
        let manager = ClipboardManager::new(backend);
        let peer = openlogi_flow::sas::PublicKey::new([12; 32]);
        let announce = proto::ClipboardAnnounce {
            sequence: 2,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: 6,
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(manager.accept_announce(peer, &announce).await.is_some());
        manager
            .apply_remote(peer, 2, 0, b"abc".to_vec(), None)
            .await
            .expect("prefix should be retained");
        assert_eq!(
            manager.pending_fetch().await,
            Some((peer, 2, TEXT_MIME.to_owned(), 3))
        );
    }

    #[tokio::test]
    async fn interrupted_text_transfer_keeps_received_chunks_for_resume() {
        let manager = ClipboardManager::new(Arc::new(MemoryClipboard::default()));
        let peer = openlogi_flow::sas::PublicKey::new([15; 32]);
        let full = b"hello world";
        let announce = proto::ClipboardAnnounce {
            sequence: 3,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: full.len() as u64,
                sha256: Some(digest(full).to_vec()),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(manager.accept_announce(peer, &announce).await.is_some());
        manager
            .apply_remote_chunk(peer, 3, 0, b"hello ")
            .await
            .expect("received chunk should be retained");
        assert_eq!(
            manager.pending_fetch().await,
            Some((peer, 3, TEXT_MIME.to_owned(), 6))
        );
        manager
            .apply_remote(peer, 3, 6, b"world".to_vec(), Some(digest(b"world")))
            .await
            .expect("the resumed suffix should complete the transfer");
    }

    #[tokio::test]
    async fn pending_fetch_uses_announcement_order_across_peers() {
        let manager = ClipboardManager::new(Arc::new(MemoryClipboard::default()));
        let first_peer = openlogi_flow::sas::PublicKey::new([13; 32]);
        let second_peer = openlogi_flow::sas::PublicKey::new([14; 32]);
        let announce = |sequence| proto::ClipboardAnnounce {
            sequence,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: 1,
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(
            manager
                .accept_announce(first_peer, &announce(9))
                .await
                .is_some()
        );
        assert!(
            manager
                .accept_announce(second_peer, &announce(1))
                .await
                .is_some()
        );
        assert_eq!(
            manager.pending_fetch().await,
            Some((second_peer, 1, TEXT_MIME.to_owned(), 0))
        );
    }

    #[tokio::test]
    async fn generation_reset_drops_remote_prefetch_without_touching_local_clipboard() {
        let backend = Arc::new(MemoryClipboard::default());
        *backend.value.lock().unwrap() = Some(b"local".to_vec());
        let manager = ClipboardManager::new(Arc::clone(&backend) as Arc<dyn ClipboardBackend>);
        let _ = manager.poll_local().await;
        let peer = openlogi_flow::sas::PublicKey::new([16; 32]);
        let announce = proto::ClipboardAnnounce {
            sequence: 1,
            formats: vec![proto::ClipboardFormat {
                mime: TEXT_MIME.to_owned(),
                size_bytes: 6,
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(manager.accept_announce(peer, &announce).await.is_some());
        manager.reset_remote().await;
        assert_eq!(manager.pending_fetch().await, None);
        assert!(!manager.apply_staged());
        assert_eq!(backend.read_text(), Some(b"local".to_vec()));
    }

    #[test]
    fn file_list_paths_are_platform_neutral_and_strictly_flat() {
        for path in [
            "/tmp/file.txt",
            "../file.txt",
            "folder/file.txt",
            "C:file.txt",
            "file\\name.txt",
        ] {
            let list = proto::FileList {
                files: vec![proto::FileEntry {
                    relative_path: path.to_owned(),
                    size_bytes: 1,
                    ..Default::default()
                }],
                ..Default::default()
            };
            assert_eq!(
                validate_file_entries(&list.files),
                Err(ClipboardError::InvalidFileList)
            );
        }
        let valid = proto::FileList {
            files: vec![proto::FileEntry {
                relative_path: "file.txt".to_owned(),
                size_bytes: 1,
                ..Default::default()
            }],
            ..Default::default()
        };
        assert_eq!(validate_file_entries(&valid.files), Ok(()));
    }

    #[test]
    fn file_list_rejects_duplicate_names_and_excess_size() {
        let duplicate = vec![
            proto::FileEntry {
                relative_path: "same.txt".to_owned(),
                size_bytes: 1,
                ..Default::default()
            },
            proto::FileEntry {
                relative_path: "same.txt".to_owned(),
                size_bytes: 1,
                ..Default::default()
            },
        ];
        assert_eq!(
            validate_file_entries(&duplicate),
            Err(ClipboardError::InvalidFileList)
        );
        let oversized = vec![proto::FileEntry {
            relative_path: "large.bin".to_owned(),
            size_bytes: MAX_FILE_BYTES + 1,
            ..Default::default()
        }];
        assert_eq!(
            validate_file_entries(&oversized),
            Err(ClipboardError::TooLarge)
        );
    }

    #[tokio::test]
    async fn file_list_size_must_match_its_announcement() {
        let manager = ClipboardManager::new(Arc::new(MemoryClipboard::default()));
        let peer = openlogi_flow::sas::PublicKey::new([15; 32]);
        let list = proto::FileList {
            files: vec![proto::FileEntry {
                relative_path: "file.txt".to_owned(),
                size_bytes: 1,
                ..Default::default()
            }],
            ..Default::default()
        };
        let bytes = encode_message(&list).expect("file-list encoding");
        let announce = proto::ClipboardAnnounce {
            sequence: 3,
            formats: vec![proto::ClipboardFormat {
                mime: FILES_MIME.to_owned(),
                size_bytes: bytes.len() as u64 + 1,
                sha256: None,
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(manager.accept_announce(peer, &announce).await.is_some());
        assert_eq!(
            manager
                .validate_remote_file_list(peer, 3, &bytes, None)
                .await,
            Err(ClipboardError::ChecksumMismatch)
        );
    }
}
