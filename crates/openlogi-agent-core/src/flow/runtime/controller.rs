use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use openlogi_core::config::{Config, FlowConfig};
use openlogi_hid::ChannelPool;
use openlogi_hook::CursorSample;
use openlogi_hook::edge::{
    ArmedSides, DisplayRect, EdgeCrossing, EdgeDetector, EdgeDetectorParams, ExposedEdges,
};
use openlogi_ipc::{FlowCommandError, FlowLinkState, FlowPeerStatus, FlowStatus};
use tokio::sync::{mpsc, oneshot};
use tracing::warn;

use super::FlowGeneration;
use crate::flow::FlowDeviceSnapshot;
use crate::flow::clipboard::{ClipboardManager, PasteOutcome, default_backend};
use crate::flow::config::CompiledFlowConfig;
use crate::flow::handoff::{fetch_remote_clipboard, start_outgoing};
use crate::observable::ObservableState;
use crate::receiver_access::ReceiverAccess;

const CONTROL_QUEUE: usize = 4;
const GEOMETRY_REFRESH: Duration = Duration::from_secs(2);

/// Cloneable owner of Flow's dormant configuration and armed network runtime.
#[derive(Clone)]
pub struct FlowController {
    inner: Arc<ControllerInner>,
}

struct ControllerInner {
    config: RwLock<FlowConfig>,
    devices: RwLock<Vec<FlowDeviceSnapshot>>,
    observable: Arc<ObservableState>,
    control_tx: mpsc::UnboundedSender<Control>,
    control_rx: Mutex<Option<mpsc::UnboundedReceiver<Control>>>,
    movement_tx: mpsc::Sender<Movement>,
    movement_rx: Mutex<Option<mpsc::Receiver<Movement>>>,
    edge_settings: Arc<RwLock<EdgeSettings>>,
    channel_pool: ChannelPool,
    receiver_access: ReceiverAccess,
    clipboard: Arc<ClipboardManager>,
    armed: AtomicBool,
}

/// Bounded, callback-safe input seam for pointer movement.
#[derive(Clone)]
pub struct FlowInputHandle {
    movement: mpsc::Sender<Movement>,
    control: mpsc::UnboundedSender<Control>,
    clipboard: Arc<ClipboardManager>,
}

#[derive(Clone, Copy)]
struct Movement {
    cursor: CursorSample,
}

pub(super) enum Control {
    Reconfigure(FlowConfig),
    /// A reload that changed only `[[flow.layout]]` (and possibly
    /// `require_modifier`): re-map edges on the running generation.
    Relayout(FlowConfig),
    Devices(Vec<FlowDeviceSnapshot>),
    Crossing(EdgeCrossing),
    PairCompleted,
    PairStart {
        address: String,
        reply: oneshot::Sender<Result<(), FlowCommandError>>,
    },
    PairListen {
        reply: oneshot::Sender<Result<(), FlowCommandError>>,
    },
    PairConfirm {
        reply: oneshot::Sender<Result<(), FlowCommandError>>,
    },
    PairReject {
        reply: oneshot::Sender<Result<(), FlowCommandError>>,
    },
    PairCancel {
        reply: oneshot::Sender<Result<(), FlowCommandError>>,
    },
    Paste,
}

#[derive(Clone)]
struct EdgeSettings {
    enabled: bool,
    require_modifier: bool,
    sides: ArmedSides,
    revision: u64,
}

impl FlowController {
    #[must_use]
    pub fn new(
        config: FlowConfig,
        observable: Arc<ObservableState>,
        channel_pool: ChannelPool,
        receiver_access: ReceiverAccess,
    ) -> Self {
        let (control_tx, control_rx) = mpsc::unbounded_channel();
        let (movement_tx, movement_rx) = mpsc::channel(CONTROL_QUEUE);
        let edge_settings = edge_settings(&config, 0);
        let clipboard = Arc::new(ClipboardManager::new(default_backend()));
        observable.set_flow(status_from_config(&config));
        Self {
            inner: Arc::new(ControllerInner {
                config: RwLock::new(config),
                devices: RwLock::new(Vec::new()),
                observable,
                control_tx,
                control_rx: Mutex::new(Some(control_rx)),
                movement_tx,
                movement_rx: Mutex::new(Some(movement_rx)),
                edge_settings: Arc::new(RwLock::new(edge_settings)),
                channel_pool,
                receiver_access,
                clipboard,
                armed: AtomicBool::new(false),
            }),
        }
    }

    /// Start Flow networking and edge processing after the agent's dormancy gate.
    pub fn arm(&self) {
        if self.inner.armed.swap(true, Ordering::AcqRel) {
            return;
        }
        let control = self
            .inner
            .control_rx
            .lock()
            .ok()
            .and_then(|mut receiver| receiver.take());
        let movement = self
            .inner
            .movement_rx
            .lock()
            .ok()
            .and_then(|mut receiver| receiver.take());
        let (Some(control), Some(movement)) = (control, movement) else {
            warn!("Flow controller channels unavailable — Flow remains disabled");
            // A failed channel handoff must not leave the controller looking
            // armed. This is observable by pairing/config callers and would
            // otherwise prevent a later lifecycle re-arm from retrying.
            self.inner.armed.store(false, Ordering::Release);
            return;
        };
        let config = self
            .inner
            .config
            .read()
            .map_or_else(|_| FlowConfig::default(), |config| config.clone());
        let devices = self
            .inner
            .devices
            .read()
            .map_or_else(|_| Vec::new(), |devices| devices.clone());
        tokio::spawn(run_controller(
            Arc::clone(&self.inner),
            control,
            config,
            devices,
        ));
        tokio::spawn(run_edge_input(
            movement,
            Arc::clone(&self.inner.edge_settings),
            self.inner.control_tx.clone(),
        ));
    }

    /// Apply a live `[flow]` config reload.
    ///
    /// Every agent config reload lands here, most of them for unrelated
    /// settings. Only a change to the `[flow]` section touches Flow, and only
    /// a change beyond the edge layout and modifier restarts networking.
    pub fn update_config(&self, config: &FlowConfig) {
        let change = match self.inner.config.write() {
            Ok(mut current) => {
                let change = classify_change(&current, config);
                *current = config.clone();
                change
            }
            Err(_) => FlowChange::Restart,
        };
        if change == FlowChange::None {
            return;
        }
        let revision = self
            .inner
            .edge_settings
            .read()
            .map_or(1, |settings| settings.revision.wrapping_add(1));
        if let Ok(mut settings) = self.inner.edge_settings.write() {
            *settings = edge_settings(config, revision);
        }
        let armed = self.inner.armed.load(Ordering::Acquire);
        let command = match change {
            FlowChange::None => return,
            // The edge input reads the new settings itself; a running
            // generation keeps publishing its own live status.
            FlowChange::Edges if armed => return,
            FlowChange::Edges => None,
            FlowChange::Layout => Some(Control::Relayout(config.clone())),
            FlowChange::Restart => Some(Control::Reconfigure(config.clone())),
        };
        if armed && command.is_some_and(|command| self.inner.control_tx.send(command).is_ok()) {
            return;
        }
        self.inner.observable.set_flow(status_from_config(config));
    }

    /// Validates a candidate Flow configuration without starting networking.
    pub fn validate_config(config: &FlowConfig) -> Result<(), String> {
        CompiledFlowConfig::compile(config)
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    /// Publish a fresh inventory-derived Flow device snapshot.
    pub(crate) fn update_devices(&self, devices: Vec<FlowDeviceSnapshot>) {
        if let Ok(mut current) = self.inner.devices.write() {
            current.clone_from(&devices);
        }
        if self.inner.armed.load(Ordering::Acquire) {
            let _ = self.inner.control_tx.send(Control::Devices(devices));
        }
    }

    /// Clone the bounded input seam installed in the OS hook.
    #[must_use]
    pub fn input(&self) -> FlowInputHandle {
        FlowInputHandle {
            movement: self.inner.movement_tx.clone(),
            control: self.inner.control_tx.clone(),
            clipboard: Arc::clone(&self.inner.clipboard),
        }
    }

    /// Queue a detector-confirmed edge crossing without blocking the input hook.
    pub fn crossing(&self, crossing: EdgeCrossing) {
        let _ = self.inner.control_tx.send(Control::Crossing(crossing));
    }

    /// Begin a cross-machine Flow pairing ceremony.
    pub async fn pair_start(&self, address: String) -> Result<(), FlowCommandError> {
        let (reply, result) = oneshot::channel();
        self.send_pairing_command(Control::PairStart { address, reply }, result)
            .await
    }

    /// Confirm the currently displayed Flow pairing code.
    pub async fn pair_confirm(&self) -> Result<(), FlowCommandError> {
        let (reply, result) = oneshot::channel();
        self.send_pairing_command(Control::PairConfirm { reply }, result)
            .await
    }

    /// Open a one-shot inbound Flow pairing window for an unknown peer.
    pub async fn pair_listen(&self) -> Result<(), FlowCommandError> {
        let (reply, result) = oneshot::channel();
        self.send_pairing_command(Control::PairListen { reply }, result)
            .await
    }

    /// Reject the currently displayed Flow pairing code.
    pub async fn pair_reject(&self) -> Result<(), FlowCommandError> {
        let (reply, result) = oneshot::channel();
        self.send_pairing_command(Control::PairReject { reply }, result)
            .await
    }

    /// Cancel the currently active Flow pairing ceremony.
    pub async fn pair_cancel(&self) -> Result<(), FlowCommandError> {
        let (reply, result) = oneshot::channel();
        self.send_pairing_command(Control::PairCancel { reply }, result)
            .await
    }

    async fn send_pairing_command(
        &self,
        command: Control,
        result: oneshot::Receiver<Result<(), FlowCommandError>>,
    ) -> Result<(), FlowCommandError> {
        if !self.inner.armed.load(Ordering::Acquire) {
            return Err(FlowCommandError::Unavailable);
        }
        self.inner
            .control_tx
            .send(command)
            .map_err(|_| FlowCommandError::Unavailable)?;
        result.await.unwrap_or(Err(FlowCommandError::Unavailable))
    }
}

impl FlowInputHandle {
    /// Queue one pointer movement without blocking the OS hook callback.
    pub fn try_moved(&self, cursor: CursorSample) {
        let _ = self.movement.try_send(Movement { cursor });
    }

    /// Notify the Flow runtime that the local user invoked paste.
    ///
    /// A staged remote value is handed to the clipboard worker (the hook
    /// thread never writes the clipboard itself); otherwise the runtime pulls
    /// one pending remote clipboard generation, if available.
    pub fn try_paste(&self) {
        match self.clipboard.request_paste() {
            PasteOutcome::NothingStaged | PasteOutcome::Failed => {
                let _ = self.control.send(Control::Paste);
            }
            PasteOutcome::Applied | PasteOutcome::Pending => {}
        }
    }
}

/// How far a `[flow]` reload reaches into the running Flow runtime.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FlowChange {
    /// Nothing in `[flow]` changed.
    None,
    /// Only `require_modifier`: the edge input picks it up by itself.
    Edges,
    /// The edge layout changed (peers, devices and networking did not).
    Layout,
    /// Anything else: rebuild the generation.
    Restart,
}

fn classify_change(current: &FlowConfig, next: &FlowConfig) -> FlowChange {
    if current == next {
        return FlowChange::None;
    }
    let networking = |config: &FlowConfig| FlowConfig {
        require_modifier: false,
        layout: Vec::new(),
        ..config.clone()
    };
    if networking(current) != networking(next) {
        FlowChange::Restart
    } else if current.layout != next.layout {
        FlowChange::Layout
    } else {
        FlowChange::Edges
    }
}

fn status_from_config(config: &FlowConfig) -> FlowStatus {
    CompiledFlowConfig::compile(config).map_or_else(
        |_| FlowStatus {
            enabled: config.enabled,
            peers: config
                .peers
                .iter()
                .map(|peer| FlowPeerStatus {
                    name: peer.name.clone(),
                    public_key: peer.public_key.clone(),
                    state: FlowLinkState::Lost,
                })
                .collect(),
            pairing: None,
        },
        |compiled| compiled.status(),
    )
}

fn edge_settings(config: &FlowConfig, revision: u64) -> EdgeSettings {
    let compiled = CompiledFlowConfig::compile(config).ok();
    let sides = compiled.as_ref().map_or(ArmedSides::NONE, |compiled| {
        ArmedSides::from_sides(compiled.layout.keys().copied())
    });
    EdgeSettings {
        enabled: compiled.as_ref().is_some_and(|compiled| compiled.enabled),
        require_modifier: config.require_modifier,
        sides,
        revision,
    }
}

async fn run_controller(
    inner: Arc<ControllerInner>,
    mut control: mpsc::UnboundedReceiver<Control>,
    initial_config: FlowConfig,
    mut devices: Vec<FlowDeviceSnapshot>,
) {
    let mut generation = start_generation(&inner, &initial_config, &devices).await;
    while let Some(command) = control.recv().await {
        match command {
            Control::Reconfigure(config) => {
                generation = restart_generation(&inner, generation, &config, &devices).await;
            }
            Control::Relayout(config) => {
                let compiled = CompiledFlowConfig::compile(&config);
                if let (Some(active), Ok(compiled)) = (generation.as_ref(), compiled) {
                    active.state.set_layout(compiled.layout);
                } else {
                    // No running generation, or a layout that does not compile:
                    // take the full path, which reports the error.
                    generation = restart_generation(&inner, generation, &config, &devices).await;
                }
            }
            Control::Devices(next) => {
                devices = next;
                if let Some(active) = &generation {
                    active.update_devices(&devices).await;
                }
            }
            Control::Crossing(crossing) => {
                if let Some(active) = &generation {
                    start_outgoing(Arc::clone(&active.state), crossing);
                }
            }
            Control::PairCompleted => {
                let next = match Config::load_or_default() {
                    Ok(config) => config,
                    Err(error) => {
                        warn!(%error, "Flow pairing completed but config reload failed");
                        continue;
                    }
                };
                if let Some(active) = generation.take() {
                    active.shutdown().await;
                }
                if let Ok(mut current) = inner.config.write() {
                    *current = next.flow.clone();
                }
                generation = start_generation(&inner, &next.flow, &devices).await;
            }
            Control::PairStart { address, reply } => {
                let result = match generation.as_ref() {
                    Some(active) => active.pair_start(address).await,
                    None => Err(FlowCommandError::Unavailable),
                };
                let _ = reply.send(result);
            }
            Control::PairConfirm { reply } => {
                let result = match generation.as_ref() {
                    Some(active) => active.pair_confirm().await,
                    None => Err(FlowCommandError::Unavailable),
                };
                let _ = reply.send(result);
            }
            Control::PairListen { reply } => {
                let result = match generation.as_ref() {
                    Some(active) => active.pair_listen().await,
                    None => Err(FlowCommandError::Unavailable),
                };
                let _ = reply.send(result);
            }
            Control::PairReject { reply } => {
                let result = match generation.as_ref() {
                    Some(active) => active.pair_reject().await,
                    None => Err(FlowCommandError::Unavailable),
                };
                let _ = reply.send(result);
            }
            Control::PairCancel { reply } => {
                let result = match generation.as_ref() {
                    Some(active) => active.pair_cancel().await,
                    None => Err(FlowCommandError::Unavailable),
                };
                let _ = reply.send(result);
            }
            Control::Paste => {
                let Some(active) = generation
                    .as_ref()
                    .filter(|active| active.state.config.clipboard)
                else {
                    continue;
                };
                let Some((peer, sequence, mime, offset)) =
                    active.state.clipboard.pending_fetch().await
                else {
                    continue;
                };
                fetch_remote_clipboard(Arc::clone(&active.state), peer, sequence, mime, offset)
                    .await;
            }
        }
    }
    if let Some(active) = generation {
        active.shutdown().await;
    }
}

async fn restart_generation(
    inner: &Arc<ControllerInner>,
    current: Option<FlowGeneration>,
    config: &FlowConfig,
    devices: &[FlowDeviceSnapshot],
) -> Option<FlowGeneration> {
    if let Some(active) = current {
        active.shutdown().await;
    }
    start_generation(inner, config, devices).await
}

async fn start_generation(
    inner: &Arc<ControllerInner>,
    config: &FlowConfig,
    devices: &[FlowDeviceSnapshot],
) -> Option<FlowGeneration> {
    inner.observable.set_flow(status_from_config(config));
    let compiled = match CompiledFlowConfig::compile(config) {
        Ok(compiled) => Arc::new(compiled),
        Err(error) => {
            warn!(%error, "invalid Flow configuration — networking not started");
            return None;
        }
    };
    inner.observable.set_flow(compiled.status());
    if !compiled.enabled {
        return None;
    }
    match FlowGeneration::start(
        compiled,
        devices,
        Arc::clone(&inner.observable),
        inner.channel_pool.clone(),
        inner.receiver_access.clone(),
        Arc::clone(&inner.clipboard),
        inner.control_tx.clone(),
    )
    .await
    {
        Ok(generation) => Some(generation),
        Err(error) => {
            warn!(%error, "Flow runtime failed to start");
            None
        }
    }
}

async fn run_edge_input(
    mut movement: mpsc::Receiver<Movement>,
    settings: Arc<RwLock<EdgeSettings>>,
    control: mpsc::UnboundedSender<Control>,
) {
    let epoch = Instant::now();
    let mut input = EdgeInput::default();
    while let Some(movement) = movement.recv().await {
        let current = settings.read().map_or_else(
            |_| edge_settings(&FlowConfig::default(), 0),
            |value| value.clone(),
        );
        let timestamp = movement
            .cursor
            .timestamp
            .checked_duration_since(epoch)
            .unwrap_or(Duration::ZERO);
        let crossing = input.sample(
            &current,
            &movement.cursor,
            Instant::now(),
            timestamp,
            || openlogi_hook::display_rects().unwrap_or_default(),
        );
        if let Some(crossing) = crossing {
            let _ = control.send(Control::Crossing(crossing));
        }
    }
}

/// The edge detector plus its refresh bookkeeping.
///
/// One detector lives for as long as Flow edges stay enabled. Geometry and
/// side changes are applied to it in place, so the latch left by a crossing
/// survives the periodic geometry refresh and a released modifier; replacing
/// the detector would let a cursor still pinned to the edge cross again.
#[derive(Default)]
struct EdgeInput {
    detector: Option<EdgeDetector>,
    active_revision: Option<u64>,
    refreshed_at: Option<Instant>,
}

impl EdgeInput {
    fn sample(
        &mut self,
        settings: &EdgeSettings,
        cursor: &CursorSample,
        now: Instant,
        timestamp: Duration,
        displays: impl FnOnce() -> Vec<DisplayRect>,
    ) -> Option<EdgeCrossing> {
        if !settings.enabled {
            *self = Self::default();
            return None;
        }
        if settings.require_modifier && !cursor.control_down {
            if let Some(detector) = self.detector.as_mut() {
                detector.suspend();
            }
            return None;
        }
        let refresh = self.detector.is_none()
            || self.active_revision != Some(settings.revision)
            || self
                .refreshed_at
                .is_none_or(|at| now.duration_since(at) >= GEOMETRY_REFRESH);
        if refresh {
            self.refresh(settings, &displays());
            self.refreshed_at = Some(now);
        }
        self.detector.as_mut()?.update(cursor.position, timestamp)
    }

    fn refresh(&mut self, settings: &EdgeSettings, displays: &[DisplayRect]) {
        self.active_revision = Some(settings.revision);
        if displays.is_empty() {
            // A failed display query keeps the last known geometry (and its
            // latch) rather than dropping edge detection.
            return;
        }
        let edges = ExposedEdges::from_displays(displays);
        match self.detector.as_mut() {
            Some(detector) => {
                if detector.edges() != &edges {
                    detector.set_edges(edges);
                }
                detector.set_armed_sides(settings.sides);
            }
            None => {
                self.detector = Some(EdgeDetector::new(
                    edges,
                    settings.sides,
                    EdgeDetectorParams::default(),
                ));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use openlogi_core::config::{FlowEdge, FlowLayout, FlowPeer};
    use openlogi_hook::{CursorPosition, CursorSample, edge::EdgeSide};

    use super::*;

    fn configured(enabled: bool, require_modifier: bool) -> FlowConfig {
        FlowConfig {
            enabled,
            require_modifier,
            peers: vec![FlowPeer {
                name: "desk".into(),
                public_key:
                    "ed25519:0000000000000000000000000000000000000000000000000000000000000000"
                        .into(),
                addresses: Vec::new(),
            }],
            layout: vec![FlowLayout {
                edge: FlowEdge::Right,
                peer: "desk".into(),
            }],
            ..FlowConfig::default()
        }
    }

    #[test]
    fn only_flow_networking_changes_restart_the_runtime() {
        let base = configured(true, false);
        assert_eq!(classify_change(&base, &base.clone()), FlowChange::None);

        let modifier = FlowConfig {
            require_modifier: true,
            ..base.clone()
        };
        assert_eq!(classify_change(&base, &modifier), FlowChange::Edges);

        let mut moved = base.clone();
        moved.layout[0].edge = FlowEdge::Left;
        assert_eq!(classify_change(&base, &moved), FlowChange::Layout);
        let moved_and_modifier = FlowConfig {
            require_modifier: true,
            ..moved.clone()
        };
        assert_eq!(
            classify_change(&base, &moved_and_modifier),
            FlowChange::Layout
        );

        for restart in [
            FlowConfig {
                enabled: false,
                ..base.clone()
            },
            FlowConfig {
                clipboard: false,
                ..base.clone()
            },
            FlowConfig {
                peers: Vec::new(),
                layout: Vec::new(),
                ..base.clone()
            },
        ] {
            assert_eq!(classify_change(&base, &restart), FlowChange::Restart);
        }
        let mut readdressed = base.clone();
        readdressed.peers[0].addresses.push("10.0.0.7".into());
        assert_eq!(classify_change(&base, &readdressed), FlowChange::Restart);
    }

    #[tokio::test]
    async fn unrelated_reloads_do_not_reach_the_runtime() {
        let (control_tx, mut control_rx) = mpsc::unbounded_channel();
        let controller = test_controller(configured(true, false), control_tx);
        controller.update_config(&configured(true, false));
        assert!(control_rx.try_recv().is_err());

        let mut moved = configured(true, false);
        moved.layout[0].edge = FlowEdge::Top;
        controller.update_config(&moved);
        assert!(matches!(control_rx.try_recv(), Ok(Control::Relayout(_))));

        controller.update_config(&FlowConfig::default());
        assert!(matches!(control_rx.try_recv(), Ok(Control::Reconfigure(_))));
    }

    /// An armed controller whose control channel the test owns.
    fn test_controller(
        config: FlowConfig,
        control_tx: mpsc::UnboundedSender<Control>,
    ) -> FlowController {
        let (movement_tx, _) = mpsc::channel(CONTROL_QUEUE);
        FlowController {
            inner: Arc::new(ControllerInner {
                edge_settings: Arc::new(RwLock::new(edge_settings(&config, 0))),
                config: RwLock::new(config),
                devices: RwLock::new(Vec::new()),
                observable: Arc::new(ObservableState::new("flow-controller-test".into())),
                control_tx,
                control_rx: Mutex::new(None),
                movement_tx,
                movement_rx: Mutex::new(None),
                channel_pool: ChannelPool::with_backend(Arc::new(
                    openlogi_hid::replay::ReplayBackend::new(
                        openlogi_hid::replay::ReplayTopology {
                            nodes: Vec::new(),
                            channels: Vec::new(),
                        },
                        Vec::new(),
                    )
                    .expect("empty replay backend"),
                )),
                receiver_access: ReceiverAccess::default(),
                clipboard: Arc::new(ClipboardManager::new(default_backend())),
                armed: AtomicBool::new(true),
            }),
        }
    }

    #[test]
    fn edge_settings_rebuild_on_config_reload() {
        let initial = edge_settings(&configured(true, true), 4);
        assert!(initial.enabled);
        assert!(initial.require_modifier);
        assert!(initial.sides.contains(EdgeSide::Right));
        assert_eq!(initial.revision, 4);

        let disabled = edge_settings(&FlowConfig::default(), 5);
        assert!(!disabled.enabled);
        assert!(!disabled.require_modifier);
        assert_eq!(disabled.sides, ArmedSides::NONE);
        assert_eq!(disabled.revision, 5);
    }

    fn sample_at(x: f64, control_down: bool) -> CursorSample {
        CursorSample {
            position: CursorPosition { x, y: 50.0 },
            timestamp: Instant::now(),
            control_down,
        }
    }

    fn display() -> Vec<DisplayRect> {
        vec![DisplayRect::new(0.0, 0.0, 100.0, 100.0).expect("valid display")]
    }

    /// Drives one `EdgeInput` with a fixed clock so the geometry refresh
    /// interval can be crossed deterministically.
    fn drive(
        input: &mut EdgeInput,
        settings: &EdgeSettings,
        start: Instant,
        millis: u64,
        x: f64,
        control_down: bool,
    ) -> Option<EdgeCrossing> {
        let offset = Duration::from_millis(millis);
        input.sample(
            settings,
            &sample_at(x, control_down),
            start + offset,
            offset,
            display,
        )
    }

    #[test]
    fn edge_latch_survives_geometry_refresh_while_pinned() {
        let settings = edge_settings(&configured(true, false), 1);
        let mut input = EdgeInput::default();
        let start = Instant::now();
        assert!(drive(&mut input, &settings, start, 0, 99.5, false).is_none());
        assert!(drive(&mut input, &settings, start, 300, 99.5, false).is_some());
        // Pinned to the right edge across several geometry refreshes.
        for millis in [2_500, 5_000, 7_500] {
            assert!(drive(&mut input, &settings, start, millis, 99.5, false).is_none());
            assert!(drive(&mut input, &settings, start, millis + 300, 99.5, false).is_none());
        }
        // Leaving the hysteresis band rearms the edge.
        assert!(drive(&mut input, &settings, start, 8_000, 50.0, false).is_none());
        assert!(drive(&mut input, &settings, start, 8_100, 99.5, false).is_none());
        assert!(drive(&mut input, &settings, start, 8_400, 99.5, false).is_some());
    }

    #[test]
    fn edge_latch_survives_modifier_release_and_config_revision() {
        let settings = edge_settings(&configured(true, true), 1);
        let mut input = EdgeInput::default();
        let start = Instant::now();
        assert!(drive(&mut input, &settings, start, 0, 99.5, true).is_none());
        assert!(drive(&mut input, &settings, start, 300, 99.5, true).is_some());
        assert!(drive(&mut input, &settings, start, 400, 99.5, false).is_none());
        let reloaded = edge_settings(&configured(true, true), 2);
        for millis in [900, 1_200, 1_600] {
            assert!(drive(&mut input, &reloaded, start, millis, 99.5, true).is_none());
        }
    }

    #[test]
    fn disabling_edges_drops_the_detector() {
        let mut input = EdgeInput::default();
        let start = Instant::now();
        let enabled = edge_settings(&configured(true, false), 1);
        assert!(drive(&mut input, &enabled, start, 0, 50.0, false).is_none());
        assert!(input.detector.is_some());
        let disabled = edge_settings(&FlowConfig::default(), 2);
        assert!(drive(&mut input, &disabled, start, 100, 50.0, false).is_none());
        assert!(input.detector.is_none());
    }

    #[tokio::test]
    async fn input_handle_queues_cursor_sample_without_blocking() {
        let (movement, mut received) = mpsc::channel(1);
        let (control, _received_control) = mpsc::unbounded_channel();
        let input = FlowInputHandle {
            movement,
            control,
            clipboard: Arc::new(ClipboardManager::new(default_backend())),
        };
        let sample = CursorSample {
            position: CursorPosition { x: 100.0, y: 50.0 },
            timestamp: Instant::now(),
            control_down: true,
        };

        input.try_moved(sample);

        assert_eq!(
            received.recv().await.map(|movement| movement.cursor),
            Some(sample)
        );
    }
}
