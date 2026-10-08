use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Write as _};
use std::net::{Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

use buffa::EnumValue;
use openlogi_core::config::{Config, FlowPeer};
use openlogi_flow::discovery::{
    CandidateSource, DEFAULT_PORT, ManualCandidateSource, MdnsAdvertiser, MdnsCandidateSource,
    MdnsRecord, collect_candidates,
};
use openlogi_flow::frame::FrameKind;
use openlogi_flow::generated as proto;
use openlogi_flow::identity::same_device;
use openlogi_flow::pairing::{
    DEFAULT_PAIRING_TIMEOUT, PairingAbortReason, PairingSession, PairingState, PeerKeyStore,
    PersistPeerKeyError,
};
use openlogi_flow::sas::PublicKey;
use openlogi_flow::session::{
    LinkState, PeerConfig, PeerSessionHandle, SessionManager, SessionPolicy, TrustedInitialState,
    TrustedStateProvider,
};
use openlogi_flow::transport::{
    FlowConnection, FlowEndpoint, MachineIdentity, NotificationEvent, PeerTrust, RpcEvent,
    SessionTrust, error_envelope, message_envelope,
};
use openlogi_hid::{ChannelPool, DeviceRoute};
use openlogi_hook::edge::{EdgeSide, ExposedEdges};
use openlogi_ipc::{FlowLinkState, FlowPeerStatus, FlowStatus};
use thiserror::Error;
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;
use tracing::{info, warn};

use super::clipboard::ClipboardManager;
use super::config::CompiledFlowConfig;
use super::handoff::{HandoffBook, handle_notification, handle_rpc, inventory_changed};
use super::{FlowDeviceSnapshot, RuntimeDevice, is_pointing_device};
use crate::observable::ObservableState;
use crate::receiver_access::{ExclusiveAccessReason, ReceiverAccess};

const FLOW_IDENTITY_FILE: &str = "flow-identity.pk8";
const PROTOCOL_MIN: u32 = 1;
const PROTOCOL_MAX: u32 = 1;
const PAIRING_REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

mod controller;

pub use controller::{FlowController, FlowInputHandle};

struct FlowGeneration {
    state: Arc<GenerationState>,
    sessions: SessionManager,
    tasks: Vec<JoinHandle<()>>,
    _advertiser: Option<MdnsAdvertiser>,
    endpoint: Arc<FlowEndpoint>,
    trust: PeerTrust,
    pairing: Arc<Mutex<Option<ActivePairing>>>,
    pairing_reserved: Arc<AtomicBool>,
    pairing_window: Arc<AtomicBool>,
    control_tx: mpsc::UnboundedSender<controller::Control>,
}

struct ActivePairing {
    connection: Arc<FlowConnection>,
    session: PairingSession,
    address: String,
    machine_name: String,
}

/// Stages the state-machine persistence callback until the runtime can commit
/// the peer record and promote the live connection as one operation.
///
/// `PairingSession` deliberately keeps persistence injected so the protocol
/// crate stays host-agnostic. The runtime must not write `config.toml` from
/// that callback: a later connection promotion can still fail, and a config
/// record without a live trusted connection is a misleading half-complete
/// pairing. `complete_pairing` is the single durable commit point.
struct PendingPeerStore {
    expected: PublicKey,
}

impl PendingPeerStore {
    fn new(expected: PublicKey) -> Self {
        Self { expected }
    }
}

impl PeerKeyStore for PendingPeerStore {
    fn persist_peer_key(&mut self, key: PublicKey) -> Result<(), PersistPeerKeyError> {
        if key != self.expected {
            return Err(PersistPeerKeyError::new(
                "pairing callback returned an unexpected peer key",
            ));
        }
        Ok(())
    }
}

impl FlowGeneration {
    #[expect(
        clippy::too_many_lines,
        reason = "startup owns identity, endpoint, discovery, sessions, and task wiring as one lifecycle"
    )]
    async fn start(
        config: Arc<CompiledFlowConfig>,
        snapshots: &[FlowDeviceSnapshot],
        observable: Arc<ObservableState>,
        channel_pool: ChannelPool,
        receiver_access: ReceiverAccess,
        clipboard: Arc<ClipboardManager>,
        control_tx: mpsc::UnboundedSender<controller::Control>,
    ) -> Result<Self, FlowRuntimeError> {
        let identity = tokio::task::spawn_blocking(load_machine_identity)
            .await
            .map_err(|error| FlowRuntimeError::IdentityTask(error.to_string()))??;
        let mut capabilities = vec![EnumValue::from(proto::Capability::ClipboardText as i32)];
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        capabilities.push(EnumValue::from(proto::Capability::ClipboardFiles as i32));
        let hello = proto::Hello {
            proto_min: PROTOCOL_MIN,
            proto_max: PROTOCOL_MAX,
            public_key: identity.public_key().as_bytes().to_vec(),
            session_nonce: rand::random::<[u8; 16]>().to_vec(),
            machine_name: machine_name(),
            platform: platform().into(),
            app_version: env!("CARGO_PKG_VERSION").to_owned(),
            capabilities,
            ..Default::default()
        };
        // Keep a single trust object that can admit one unknown identity only
        // while an explicit pairing command is active. Pairing starts disabled
        // so normal Flow connections remain strictly pinned.
        let trust = PeerTrust::pairing(config.peers.iter().map(|peer| peer.public_key));
        trust.disable_pairing();
        let endpoint = Arc::new(FlowEndpoint::bind(
            SocketAddr::from((Ipv4Addr::UNSPECIFIED, DEFAULT_PORT)),
            identity,
            trust.clone(),
            hello,
        )?);
        let record = MdnsRecord::new(endpoint.public_key(), PROTOCOL_MIN, PROTOCOL_MAX)?;
        let advertiser = match MdnsAdvertiser::start(record, endpoint.local_addr()?.port()) {
            Ok(advertiser) => Some(advertiser),
            Err(error) => {
                warn!(%error, "Flow mDNS advertisement unavailable — manual addresses remain active");
                None
            }
        };
        let browser: Option<Arc<dyn CandidateSource>> =
            match MdnsCandidateSource::browse(PROTOCOL_MIN, PROTOCOL_MAX) {
                Ok(browser) => Some(Arc::new(browser)),
                Err(error) => {
                    warn!(%error, "Flow mDNS browsing unavailable — manual addresses only");
                    None
                }
            };
        let peers = config.peers.iter().map(|peer| {
            let mut sources = Vec::<Arc<dyn CandidateSource>>::new();
            if let Some(browser) = &browser {
                sources.push(Arc::clone(browser));
            }
            if !peer.addresses.is_empty() {
                sources.push(Arc::new(ManualCandidateSource::new(peer.addresses.clone())));
            }
            PeerConfig {
                public_key: peer.public_key,
                sources,
            }
        });
        let state = Arc::new(GenerationState::new(
            Arc::clone(&config),
            snapshots,
            observable,
            channel_pool,
            receiver_access,
            clipboard,
        ));
        let provider: Arc<dyn TrustedStateProvider> = state.clone();
        let mut sessions = SessionManager::start(
            Arc::clone(&endpoint),
            peers,
            provider,
            SessionPolicy::default(),
        )?;
        let pairing_connections = sessions
            .take_pairing_connections()
            .ok_or_else(|| FlowRuntimeError::Pairing("pairing receiver unavailable".to_owned()))?;
        let pairing = Arc::new(Mutex::new(None));
        let pairing_reserved = Arc::new(AtomicBool::new(false));
        let pairing_window = Arc::new(AtomicBool::new(false));
        let handles: Vec<_> = sessions.peers().cloned().collect();
        let mut tasks = Vec::with_capacity(handles.len() * 2 + 2);
        tasks.push(tokio::spawn(run_clipboard_loop(Arc::clone(&state))));
        tasks.push(tokio::spawn(run_pairing_acceptor(
            Arc::clone(&state),
            trust.clone(),
            Arc::clone(&pairing),
            Arc::clone(&pairing_reserved),
            Arc::clone(&pairing_window),
            pairing_connections,
            control_tx.clone(),
        )));
        for handle in handles {
            tasks.push(tokio::spawn(watch_link_state(
                Arc::clone(&state),
                handle.clone(),
            )));
            tasks.push(tokio::spawn(watch_connection(Arc::clone(&state), handle)));
        }
        info!(peers = config.peers.len(), "Flow runtime armed");
        Ok(Self {
            state,
            sessions,
            tasks,
            _advertiser: advertiser,
            endpoint,
            trust,
            pairing,
            pairing_reserved,
            pairing_window,
            control_tx,
        })
    }

    #[expect(
        clippy::too_many_lines,
        reason = "outgoing pairing owns discovery, authentication, and active-session publication"
    )]
    pub(super) async fn pair_start(
        &self,
        address: String,
    ) -> Result<(), openlogi_ipc::FlowCommandError> {
        if !self.state.config.enabled {
            return Err(openlogi_ipc::FlowCommandError::Disabled);
        }
        if self
            .pairing_reserved
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(openlogi_ipc::FlowCommandError::AlreadyActive);
        }
        if self.pairing_window.load(Ordering::Acquire) {
            self.pairing_reserved.store(false, Ordering::Release);
            return Err(openlogi_ipc::FlowCommandError::AlreadyActive);
        }
        if address.trim().is_empty() {
            self.pairing_reserved.store(false, Ordering::Release);
            return Err(openlogi_ipc::FlowCommandError::Invalid {
                message: "Flow peer address is empty".to_owned(),
            });
        }
        self.trust.enable_pairing();
        self.state
            .set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Connecting {
                address: address.clone(),
            }));
        let mut candidate_connection = None;
        let result = async {
            let source = Arc::new(ManualCandidateSource::new([address.clone()]));
            let candidates = collect_candidates(
                &[source as Arc<dyn CandidateSource>],
                PublicKey::new([0; 32]),
            )
            .await
            .map_err(|error| openlogi_ipc::FlowCommandError::Connection {
                message: error.to_string(),
            })?;
            let mut connected = None;
            for candidate in candidates {
                if let Ok(Ok(connection)) =
                    tokio::time::timeout(PAIRING_REQUEST_TIMEOUT, self.endpoint.connect(candidate))
                        .await
                {
                    connected = Some(Arc::new(connection));
                    break;
                }
            }
            let Some(connection) = connected else {
                return Err(openlogi_ipc::FlowCommandError::Connection {
                    message: format!("could not connect to {address}"),
                });
            };
            candidate_connection = Some(Arc::clone(&connection));
            let mut session = PairingSession::new(
                connection.local_key(),
                connection.peer_key(),
                connection.local_nonce(),
                connection.peer_nonce(),
            );
            let request = session.start().map_err(pairing_command_error)?;
            let response =
                message_envelope(FrameKind::PairStart, &request).map_err(pairing_command_error)?;
            let response = tokio::time::timeout(PAIRING_REQUEST_TIMEOUT, connection.call(response))
                .await
                .map_err(|_| openlogi_ipc::FlowCommandError::Connection {
                    message: "pairing prompt timed out".to_owned(),
                })?
                .map_err(pairing_command_error)?;
            let prompted = response
                .decode::<proto::PairPrompted>(openlogi_flow::frame::InboundRole::Notification)
                .map_err(|error| openlogi_ipc::FlowCommandError::Protocol {
                    message: format!("invalid PairPrompted response: {error:?}"),
                })?;
            session
                .receive_prompted(&prompted, Instant::now())
                .map_err(pairing_command_error)?;
            let active = ActivePairing {
                machine_name: connection.peer_hello().machine_name.clone(),
                connection,
                session,
                address,
            };
            self.state
                .set_pairing_phase(Some(pairing_phase(&active.session, &active.machine_name)));
            *self.pairing.lock().await = Some(active);
            candidate_connection = None;
            self.spawn_pairing_connection_task();
            Ok(())
        }
        .await;
        if let Err(error) = &result {
            if let Some(connection) = candidate_connection {
                connection.close();
            }
            self.trust.disable_pairing();
            self.pairing_window.store(false, Ordering::Release);
            self.pairing_reserved.store(false, Ordering::Release);
            self.state
                .set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Failed(
                    pairing_failure(error),
                )));
        }
        result
    }

    pub(super) async fn pair_listen(&self) -> Result<(), openlogi_ipc::FlowCommandError> {
        if !self.state.config.enabled {
            return Err(openlogi_ipc::FlowCommandError::Disabled);
        }
        if self.pairing.lock().await.is_some()
            || self.pairing_reserved.load(Ordering::Acquire)
            || self
                .pairing_window
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
        {
            return Err(openlogi_ipc::FlowCommandError::AlreadyActive);
        }
        self.trust.enable_pairing();
        self.state
            .set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Connecting {
                address: "incoming".to_owned(),
            }));
        let state = Arc::clone(&self.state);
        let trust = self.trust.clone();
        let window = Arc::clone(&self.pairing_window);
        tokio::spawn(async move {
            tokio::time::sleep(DEFAULT_PAIRING_TIMEOUT).await;
            if window.swap(false, Ordering::AcqRel) && state.is_active() {
                trust.disable_pairing();
                state.set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Failed(
                    openlogi_ipc::FlowPairingFailure::Timeout,
                )));
            }
        });
        Ok(())
    }

    #[expect(
        clippy::too_many_lines,
        reason = "confirmation owns local SAS state, remote response, and simultaneous-completion cleanup"
    )]
    pub(super) async fn pair_confirm(&self) -> Result<(), openlogi_ipc::FlowCommandError> {
        let connection = {
            let guard = self.pairing.lock().await;
            let Some(active) = guard.as_ref() else {
                return Err(openlogi_ipc::FlowCommandError::NoActiveSession);
            };
            Arc::clone(&active.connection)
        };
        {
            let mut guard = self.pairing.lock().await;
            let Some(active) = guard.as_mut() else {
                return Err(openlogi_ipc::FlowCommandError::NoActiveSession);
            };
            let mut store = PendingPeerStore::new(active.session.peer_key());
            active
                .session
                .confirm_local(Instant::now(), &mut store)
                .map_err(pairing_command_error)?;
            self.state
                .set_pairing_phase(Some(pairing_phase(&active.session, &active.machine_name)));
        }
        let request = message_envelope(FrameKind::PairConfirm, &proto::PairConfirm::default())
            .map_err(pairing_command_error)?;
        let outcome =
            match tokio::time::timeout(PAIRING_REQUEST_TIMEOUT, connection.call(request)).await {
                Err(_) if pairing_already_completed(&self.state) => return Ok(()),
                Err(_) => Err(openlogi_ipc::FlowCommandError::Connection {
                    message: "pairing confirmation timed out".to_owned(),
                }),
                Ok(Ok(response)) => response
                    .decode::<proto::PairOutcome>(openlogi_flow::frame::InboundRole::Notification)
                    .map_err(|error| openlogi_ipc::FlowCommandError::Protocol {
                        message: format!("invalid PairOutcome response: {error:?}"),
                    }),
                Ok(Err(error)) => Err(pairing_command_error(error)),
            };
        let outcome = match outcome {
            Ok(outcome) => outcome,
            Err(error) => {
                if pairing_already_completed(&self.state) {
                    return Ok(());
                }
                fail_pairing(
                    &self.state,
                    &self.trust,
                    &self.pairing,
                    &self.pairing_reserved,
                    pairing_failure(&error),
                )
                .await;
                return Err(error);
            }
        };
        let paired = {
            let mut guard = self.pairing.lock().await;
            let Some(active) = guard.as_mut() else {
                if pairing_already_completed(&self.state) {
                    return Ok(());
                }
                return Err(openlogi_ipc::FlowCommandError::Unavailable);
            };
            let mut store = PendingPeerStore::new(active.session.peer_key());
            let result = active
                .session
                .receive_outcome_with_store(&outcome, &mut store)
                .map_err(pairing_command_error);
            if let Err(error) = result {
                drop(guard);
                fail_pairing(
                    &self.state,
                    &self.trust,
                    &self.pairing,
                    &self.pairing_reserved,
                    pairing_failure(&error),
                )
                .await;
                return Err(error);
            }
            self.state
                .set_pairing_phase(Some(pairing_phase(&active.session, &active.machine_name)));
            active.session.state() == PairingState::Paired
        };
        if paired {
            // The peer may have confirmed on its own RPC stream at the same
            // time. Its handler can complete and remove the shared session
            // before this call receives the matching outcome; in that case
            // the durable commit and generation restart already happened.
            let Some(mut active) = self.pairing.lock().await.take() else {
                return Ok(());
            };
            match complete_pairing(&self.state, &self.trust, &mut active, &self.control_tx) {
                Ok(()) => self.pairing_reserved.store(false, Ordering::Release),
                Err(error) => {
                    active.connection.close();
                    self.trust.disable_pairing();
                    self.pairing_reserved.store(false, Ordering::Release);
                    self.state
                        .set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Failed(
                            pairing_failure(&error),
                        )));
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    pub(super) async fn pair_reject(&self) -> Result<(), openlogi_ipc::FlowCommandError> {
        self.finish_pairing(PairingAbortReason::CodeMismatch, true)
            .await
    }

    pub(super) async fn pair_cancel(&self) -> Result<(), openlogi_ipc::FlowCommandError> {
        self.finish_pairing(PairingAbortReason::UserCancelled, false)
            .await
    }

    async fn finish_pairing(
        &self,
        reason: PairingAbortReason,
        rejected: bool,
    ) -> Result<(), openlogi_ipc::FlowCommandError> {
        let Some(mut active) = self.pairing.lock().await.take() else {
            return Err(openlogi_ipc::FlowCommandError::NoActiveSession);
        };
        let _ = active.session.abort(reason);
        let abort = proto::PairAbort {
            reason: proto::PairAbortReason::from(reason).into(),
            ..Default::default()
        };
        if let Ok(envelope) = message_envelope(FrameKind::PairAbort, &abort) {
            let _ = active.connection.notify(envelope).await;
        }
        active.connection.close();
        self.trust.disable_pairing();
        self.pairing_window.store(false, Ordering::Release);
        self.pairing_reserved.store(false, Ordering::Release);
        self.state
            .set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Failed(if rejected {
                openlogi_ipc::FlowPairingFailure::Rejected
            } else {
                openlogi_ipc::FlowPairingFailure::Cancelled
            })));
        Ok(())
    }

    fn spawn_pairing_connection_task(&self) {
        tokio::spawn(run_pairing_connection(
            Arc::clone(&self.state),
            self.trust.clone(),
            Arc::clone(&self.pairing),
            Arc::clone(&self.pairing_reserved),
            self.control_tx.clone(),
        ));
    }

    async fn update_devices(&self, snapshots: &[FlowDeviceSnapshot]) {
        self.state.update_devices(snapshots);
        self.state.publish_device_state().await;
        inventory_changed(Arc::clone(&self.state)).await;
    }

    async fn shutdown(mut self) {
        {
            let _lifecycle = self.state.lifecycle.lock().await;
            self.state.active.store(false, Ordering::Release);
        }
        if let Some(active) = self.pairing.lock().await.take() {
            active.connection.close();
        }
        self.trust.disable_pairing();
        self.pairing_window.store(false, Ordering::Release);
        self.pairing_reserved.store(false, Ordering::Release);
        self.state.clipboard.reset_remote().await;
        self.sessions.shutdown().await;
        for task in self.tasks.drain(..) {
            let _ = task.await;
        }
    }
}

pub(super) struct GenerationState {
    pub(super) config: Arc<CompiledFlowConfig>,
    pub(super) devices: RwLock<Vec<RuntimeDevice>>,
    connections: RwLock<HashMap<PublicKey, Arc<FlowConnection>>>,
    link_states: RwLock<HashMap<PublicKey, LinkState>>,
    remote_states: RwLock<HashMap<PublicKey, RemotePeerState>>,
    observable: Arc<ObservableState>,
    channel_pool: ChannelPool,
    receiver_access: ReceiverAccess,
    device_revision: AtomicU64,
    peer_revision: AtomicU64,
    active: AtomicBool,
    pub(super) lifecycle: Mutex<()>,
    pub(super) handoffs: HandoffBook,
    pub(super) clipboard: Arc<ClipboardManager>,
    pairing_phase: RwLock<Option<openlogi_ipc::FlowPairingPhase>>,
}

#[derive(Clone, Default)]
struct RemotePeerState {
    device_revision: u64,
    devices: Vec<proto::DeviceView>,
    peer_revision: u64,
    held: Vec<proto::DeviceIdentity>,
}

#[derive(Clone)]
pub(super) struct OutgoingDevice {
    route: DeviceRoute,
    host: u8,
    pub(super) identity: proto::DeviceIdentity,
}

impl GenerationState {
    fn new(
        config: Arc<CompiledFlowConfig>,
        snapshots: &[FlowDeviceSnapshot],
        observable: Arc<ObservableState>,
        channel_pool: ChannelPool,
        receiver_access: ReceiverAccess,
        clipboard: Arc<ClipboardManager>,
    ) -> Self {
        let devices = runtime_devices(&config, snapshots);
        Self {
            config,
            devices: RwLock::new(devices),
            connections: RwLock::new(HashMap::new()),
            link_states: RwLock::new(HashMap::new()),
            remote_states: RwLock::new(HashMap::new()),
            observable,
            channel_pool,
            receiver_access,
            device_revision: AtomicU64::new(1),
            peer_revision: AtomicU64::new(1),
            active: AtomicBool::new(true),
            lifecycle: Mutex::new(()),
            handoffs: HandoffBook::default(),
            clipboard,
            pairing_phase: RwLock::new(None),
        }
    }

    pub(super) fn set_pairing_phase(&self, phase: Option<openlogi_ipc::FlowPairingPhase>) {
        if let Ok(mut current) = self.pairing_phase.write() {
            *current = phase;
        }
        self.publish_status();
    }

    pub(super) fn is_active(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }

    fn update_devices(&self, snapshots: &[FlowDeviceSnapshot]) {
        if let Ok(mut devices) = self.devices.write() {
            *devices = runtime_devices(&self.config, snapshots);
            self.device_revision.fetch_add(1, Ordering::Relaxed);
            self.peer_revision.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub(super) fn devices_snapshot(&self) -> Vec<RuntimeDevice> {
        self.devices
            .read()
            .map_or_else(|_| Vec::new(), |devices| devices.clone())
    }

    pub(super) fn connection(&self, peer: PublicKey) -> Option<Arc<FlowConnection>> {
        self.connections
            .read()
            .ok()
            .and_then(|connections| connections.get(&peer).cloned())
    }

    pub(super) fn connections_snapshot(&self) -> Vec<Arc<FlowConnection>> {
        self.connections.read().map_or_else(
            |_| Vec::new(),
            |connections| connections.values().cloned().collect(),
        )
    }

    fn set_connection(&self, peer: PublicKey, connection: Option<Arc<FlowConnection>>) {
        if let Ok(mut connections) = self.connections.write() {
            match connection {
                Some(connection) => {
                    connections.insert(peer, connection);
                }
                None => {
                    connections.remove(&peer);
                }
            }
        }
    }

    async fn clear_peer_state(&self, peer: PublicKey) {
        if let Ok(mut states) = self.remote_states.write() {
            states.remove(&peer);
        }
        self.handoffs.forget_peer(peer).await;
        self.clipboard.forget_peer(peer).await;
    }

    pub(super) fn update_remote_devices(
        &self,
        peer: PublicKey,
        announce: proto::AnnounceDevices,
    ) -> bool {
        let Ok(mut states) = self.remote_states.write() else {
            return false;
        };
        let state = states.entry(peer).or_default();
        if announce.revision < state.device_revision {
            return false;
        }
        state.device_revision = announce.revision;
        state.devices = announce.devices;
        true
    }

    pub(super) fn update_remote_state(
        &self,
        peer: PublicKey,
        peer_status: proto::PeerState,
    ) -> bool {
        let Ok(mut remote_states) = self.remote_states.write() else {
            return false;
        };
        let state = remote_states.entry(peer).or_default();
        if peer_status.revision < state.peer_revision {
            return false;
        }
        state.peer_revision = peer_status.revision;
        state.held = peer_status.held;
        true
    }

    pub(super) fn remote_holds_any(&self, peer: PublicKey, devices: &[OutgoingDevice]) -> bool {
        let Ok(states) = self.remote_states.read() else {
            return false;
        };
        let Some(state) = states.get(&peer) else {
            return false;
        };
        devices.iter().any(|device| {
            state
                .held
                .iter()
                .any(|held| same_device(held, &device.identity).unwrap_or(false))
                || state.devices.iter().any(|view| {
                    view.connected
                        && view.identity.as_option().is_some_and(|identity| {
                            same_device(identity, &device.identity).unwrap_or(false)
                        })
                })
        })
    }

    async fn set_link_state(&self, peer: PublicKey, state: LinkState) {
        let _lifecycle = self.lifecycle.lock().await;
        if !self.is_active() {
            return;
        }
        if let Ok(mut states) = self.link_states.write() {
            states.insert(peer, state);
        }
        self.publish_status();
    }

    fn publish_status(&self) {
        let states = self.link_states.read().ok();
        self.observable.set_flow(FlowStatus {
            enabled: self.config.enabled,
            peers: self
                .config
                .peers
                .iter()
                .map(|peer| FlowPeerStatus {
                    name: peer.name.clone(),
                    public_key: peer.canonical_key.clone(),
                    state: states
                        .as_ref()
                        .and_then(|states| states.get(&peer.public_key))
                        .copied()
                        .map_or(FlowLinkState::Lost, ipc_link_state),
                })
                .collect(),
            pairing: self
                .pairing_phase
                .read()
                .ok()
                .and_then(|phase| phase.clone()),
        });
    }

    pub(super) fn outgoing_devices(&self, peer: &str) -> Vec<OutgoingDevice> {
        let mut devices: Vec<_> = self
            .devices_snapshot()
            .into_iter()
            .filter(|device| device.snapshot.online)
            .filter_map(|device| {
                let route = device.snapshot.route.clone()?;
                let host = device.channels.get(peer).copied()?;
                Some((
                    device.snapshot.kind,
                    OutgoingDevice {
                        route,
                        host,
                        identity: device.identity,
                    },
                ))
            })
            .collect();
        devices.sort_by_key(|(kind, _)| {
            if is_pointing_device(*kind) {
                0
            } else if *kind == openlogi_core::device::DeviceKind::Keyboard {
                2
            } else {
                1
            }
        });
        devices.into_iter().map(|(_, device)| device).collect()
    }

    pub(super) async fn switch_devices(
        &self,
        devices: &[OutgoingDevice],
    ) -> Result<bool, openlogi_hid::HostSwitchError> {
        let _lease = self
            .receiver_access
            .acquire_exclusive(ExclusiveAccessReason::HostTransition)
            .await;
        if !self.is_active() {
            return Ok(false);
        }
        let targets: Vec<_> = devices
            .iter()
            .map(|device| (device.route.clone(), device.host))
            .collect();
        openlogi_hid::switch_hosts(&targets, &self.channel_pool).await?;
        Ok(true)
    }

    pub(super) async fn send_result(&self, peer: PublicKey, result: proto::HandoffResult) {
        let Some(connection) = self.connection(peer) else {
            return;
        };
        if let Ok(envelope) = message_envelope(FrameKind::HandoffResult, &result) {
            let _ = connection.notify(envelope).await;
        }
    }

    pub(super) async fn send_cancel(
        &self,
        peer: PublicKey,
        transfer_id: u64,
        reason: proto::HandoffCancelReason,
    ) {
        let Some(connection) = self.connection(peer) else {
            return;
        };
        let cancel = proto::HandoffCancel {
            transfer_id,
            reason: reason.into(),
            ..Default::default()
        };
        if let Ok(envelope) = message_envelope(FrameKind::HandoffCancel, &cancel) {
            let _ = connection.notify(envelope).await;
        }
    }

    async fn publish_device_state(&self) {
        let initial = self.initial_state(PublicKey::new([0; 32]));
        let connections: Vec<_> = self.connections.read().map_or_else(
            |_| Vec::new(),
            |connections| connections.values().cloned().collect(),
        );
        for connection in connections {
            if let Ok(envelope) =
                message_envelope(FrameKind::AnnounceDevices, &initial.announce_devices)
            {
                let _ = connection.notify(envelope).await;
            }
            if let Ok(envelope) = message_envelope(FrameKind::PeerState, &initial.peer_state) {
                let _ = connection.notify(envelope).await;
            }
        }
    }
}

impl TrustedStateProvider for GenerationState {
    fn initial_state(&self, _peer_key: PublicKey) -> TrustedInitialState {
        let devices = self.devices_snapshot();
        TrustedInitialState {
            announce_devices: proto::AnnounceDevices {
                devices: devices
                    .iter()
                    .map(|device| {
                        let mut view = proto::DeviceView {
                            channel_to_me: u32::from(
                                device.channels.get("self").copied().unwrap_or_default(),
                            ),
                            connected: device.snapshot.online,
                            host_count: device
                                .channels
                                .values()
                                .copied()
                                .max()
                                .map_or(0, |host| u32::from(host) + 1),
                            ..Default::default()
                        };
                        *view.identity.get_or_insert_default() = device.identity.clone();
                        view
                    })
                    .collect(),
                revision: self.device_revision.load(Ordering::Relaxed),
                ..Default::default()
            },
            peer_state: proto::PeerState {
                flow_enabled: self.config.enabled,
                held: devices
                    .iter()
                    .filter(|device| device.snapshot.online)
                    .map(|device| device.identity.clone())
                    .collect(),
                revision: self.peer_revision.load(Ordering::Relaxed),
                ..Default::default()
            },
        }
    }
}

fn runtime_devices(
    config: &CompiledFlowConfig,
    snapshots: &[FlowDeviceSnapshot],
) -> Vec<RuntimeDevice> {
    snapshots
        .iter()
        .filter_map(|snapshot| {
            let channels = config.devices.get(&snapshot.config_key)?.clone();
            let identity = snapshot.identity();
            (!identity.ids.is_empty()).then(|| RuntimeDevice {
                snapshot: snapshot.clone(),
                identity,
                channels,
            })
        })
        .collect()
}

async fn watch_link_state(state: Arc<GenerationState>, handle: PeerSessionHandle) {
    let peer = handle.public_key();
    let mut changes = handle.subscribe_state();
    let current = *changes.borrow_and_update();
    state.set_link_state(peer, current).await;
    while changes.changed().await.is_ok() {
        let current = *changes.borrow_and_update();
        state.set_link_state(peer, current).await;
    }
    state.set_link_state(peer, LinkState::Lost).await;
}

async fn watch_connection(state: Arc<GenerationState>, handle: PeerSessionHandle) {
    let peer = handle.public_key();
    let mut changes = handle.subscribe_connection();
    let mut application: Option<JoinHandle<()>> = None;
    loop {
        if let Some(task) = application.take() {
            task.abort();
            let _ = task.await;
        }
        let connection = changes.borrow_and_update().clone();
        // Device and clipboard revisions are scoped to a live session. A peer
        // may restart its agent and begin again at revision/sequence one.
        state.clear_peer_state(peer).await;
        state.set_connection(peer, connection.clone());
        if let Some(connection) = connection {
            application = Some(tokio::spawn(run_application_connection(
                Arc::clone(&state),
                peer,
                connection,
            )));
        }
        if changes.changed().await.is_err() {
            break;
        }
    }
    if let Some(task) = application {
        task.abort();
        let _ = task.await;
    }
    state.set_connection(peer, None);
}

async fn run_application_connection(
    state: Arc<GenerationState>,
    peer: PublicKey,
    connection: Arc<FlowConnection>,
) {
    loop {
        tokio::select! {
            rpc = connection.accept_rpc() => match rpc {
                Ok(event @ (RpcEvent::Request(_) | RpcEvent::Rejected(_))) => {
                    handle_rpc(Arc::clone(&state), peer, event).await;
                }
                Err(_) => return,
            },
            notification = connection.accept_notification() => match notification {
                Ok(event @ (NotificationEvent::Notification(_) | NotificationEvent::Dropped(_))) => {
                    handle_notification(Arc::clone(&state), peer, event).await;
                }
                Err(_) => return,
            },
        }
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "inbound pairing owns admission, prompt exchange, and active-session publication"
)]
async fn run_pairing_acceptor(
    state: Arc<GenerationState>,
    trust: PeerTrust,
    pairing: Arc<Mutex<Option<ActivePairing>>>,
    pairing_reserved: Arc<AtomicBool>,
    pairing_window: Arc<AtomicBool>,
    mut incoming: mpsc::Receiver<FlowConnection>,
    control_tx: mpsc::UnboundedSender<controller::Control>,
) {
    while state.is_active() {
        let Some(connection) = incoming.recv().await else {
            return;
        };
        if !pairing_window.load(Ordering::Acquire)
            || connection.trust() != SessionTrust::Untrusted
            || trust.pairing_candidate() != Some(connection.peer_key())
            || pairing_reserved
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
        {
            connection.close();
            continue;
        }
        pairing_window.store(false, Ordering::Release);
        let connection = Arc::new(connection);
        let Ok(Ok(RpcEvent::Request(rpc))) =
            tokio::time::timeout(PAIRING_REQUEST_TIMEOUT, connection.accept_rpc()).await
        else {
            connection.close();
            fail_pairing(
                &state,
                &trust,
                &pairing,
                &pairing_reserved,
                openlogi_ipc::FlowPairingFailure::Connection {
                    message: "pairing connection did not provide PairStart".to_owned(),
                },
            )
            .await;
            continue;
        };
        if rpc.request().kind != FrameKind::PairStart {
            if let Ok(error) = error_envelope(proto::ErrorCode::Invalid, "expected PairStart") {
                let _ = rpc.respond(error).await;
            }
            connection.close();
            fail_pairing(
                &state,
                &trust,
                &pairing,
                &pairing_reserved,
                openlogi_ipc::FlowPairingFailure::Protocol {
                    message: "expected PairStart".to_owned(),
                },
            )
            .await;
            continue;
        }
        let mut session = PairingSession::new(
            connection.local_key(),
            connection.peer_key(),
            connection.local_nonce(),
            connection.peer_nonce(),
        );
        let Ok(prompt) = session.receive_start(Instant::now(), None) else {
            connection.close();
            fail_pairing(
                &state,
                &trust,
                &pairing,
                &pairing_reserved,
                openlogi_ipc::FlowPairingFailure::Protocol {
                    message: "PairStart is invalid in the current state".to_owned(),
                },
            )
            .await;
            continue;
        };
        let Ok(response) = message_envelope(FrameKind::PairPrompted, &prompt) else {
            connection.close();
            fail_pairing(
                &state,
                &trust,
                &pairing,
                &pairing_reserved,
                openlogi_ipc::FlowPairingFailure::Protocol {
                    message: "could not encode pairing prompt".to_owned(),
                },
            )
            .await;
            continue;
        };
        if rpc.respond(response).await.is_err() {
            connection.close();
            fail_pairing(
                &state,
                &trust,
                &pairing,
                &pairing_reserved,
                openlogi_ipc::FlowPairingFailure::Connection {
                    message: "could not send pairing prompt".to_owned(),
                },
            )
            .await;
            continue;
        }
        let machine_name = connection.peer_hello().machine_name.clone();
        let address = connection.remote_addr().to_string();
        let active = ActivePairing {
            connection,
            session,
            address,
            machine_name,
        };
        let mut pairing_guard = pairing.lock().await;
        if pairing_guard.is_some() {
            active.connection.close();
            drop(pairing_guard);
            fail_pairing(
                &state,
                &trust,
                &pairing,
                &pairing_reserved,
                openlogi_ipc::FlowPairingFailure::AlreadyActive,
            )
            .await;
            continue;
        }
        state.set_pairing_phase(Some(pairing_phase(&active.session, &active.machine_name)));
        *pairing_guard = Some(active);
        drop(pairing_guard);
        tokio::spawn(run_pairing_connection(
            Arc::clone(&state),
            trust.clone(),
            Arc::clone(&pairing),
            Arc::clone(&pairing_reserved),
            control_tx.clone(),
        ));
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "pairing owns the bounded RPC, notification, timeout, and cleanup state machine"
)]
async fn run_pairing_connection(
    state: Arc<GenerationState>,
    trust: PeerTrust,
    pairing: Arc<Mutex<Option<ActivePairing>>>,
    pairing_reserved: Arc<AtomicBool>,
    control_tx: mpsc::UnboundedSender<controller::Control>,
) {
    while state.is_active() {
        let connection = {
            let guard = pairing.lock().await;
            let Some(active) = guard.as_ref() else {
                return;
            };
            if active.session.state() == PairingState::Paired {
                return;
            }
            Arc::clone(&active.connection)
        };
        let rpc = connection.accept_rpc();
        let notification = connection.accept_notification();
        tokio::pin!(rpc);
        tokio::pin!(notification);
        tokio::select! {
            event = &mut rpc => {
                match event {
                    Ok(RpcEvent::Request(request)) => {
                        handle_pairing_rpc(
                            Arc::clone(&state),
                            trust.clone(),
                            Arc::clone(&pairing),
                            Arc::clone(&pairing_reserved),
                            control_tx.clone(),
                            request,
                        )
                        .await;
                    }
                    Ok(RpcEvent::Rejected(_)) => {
                        fail_pairing(
                            &state,
                            &trust,
                            &pairing,
                            &pairing_reserved,
                            openlogi_ipc::FlowPairingFailure::Protocol {
                                message: "peer rejected a pairing request".to_owned(),
                            },
                        ).await;
                        return;
                    }
                    Err(_) => {
                        fail_pairing(
                            &state,
                            &trust,
                            &pairing,
                            &pairing_reserved,
                            openlogi_ipc::FlowPairingFailure::Connection {
                                message: "pairing connection closed".to_owned(),
                            },
                        ).await;
                        return;
                    }
                }
            }
            event = &mut notification => {
                match event {
                    Ok(NotificationEvent::Notification(notification))
                        if notification.kind == FrameKind::PairAbort =>
                    {
                        handle_pairing_abort(
                            Arc::clone(&state),
                            trust.clone(),
                            Arc::clone(&pairing),
                            Arc::clone(&pairing_reserved),
                            notification,
                        )
                        .await;
                        return;
                    }
                    Ok(NotificationEvent::Notification(_) | NotificationEvent::Dropped(_)) => {}
                    Err(_) => {
                        fail_pairing(
                            &state,
                            &trust,
                            &pairing,
                            &pairing_reserved,
                            openlogi_ipc::FlowPairingFailure::Connection {
                                message: "pairing connection closed".to_owned(),
                            },
                        ).await;
                        return;
                    }
                }
            }
            () = tokio::time::sleep(Duration::from_millis(250)) => {
                let timed_out = {
                    let mut guard = pairing.lock().await;
                    let Some(active) = guard.as_mut() else { return; };
                    active.session.check_timeout(Instant::now()).is_some()
                };
                if timed_out {
                    let connection = pairing
                        .lock()
                        .await
                        .as_ref()
                        .map(|active| Arc::clone(&active.connection));
                    if let Some(connection) = connection
                        && let Ok(envelope) = message_envelope(
                            FrameKind::PairAbort,
                            &proto::PairAbort {
                                reason: proto::PairAbortReason::Timeout.into(),
                                ..Default::default()
                            },
                        )
                    {
                        let _ = connection.notify(envelope).await;
                    }
                    fail_pairing(
                        &state,
                        &trust,
                        &pairing,
                        &pairing_reserved,
                        openlogi_ipc::FlowPairingFailure::Timeout,
                    ).await;
                    return;
                }
            }
        }
    }
}

async fn handle_pairing_rpc(
    state: Arc<GenerationState>,
    trust: PeerTrust,
    pairing: Arc<Mutex<Option<ActivePairing>>>,
    pairing_reserved: Arc<AtomicBool>,
    control_tx: mpsc::UnboundedSender<controller::Control>,
    request: openlogi_flow::transport::IncomingRpc,
) {
    if request.request().kind != FrameKind::PairConfirm {
        if let Ok(error) = error_envelope(proto::ErrorCode::Invalid, "expected PairConfirm") {
            let _ = request.respond(error).await;
        }
        return;
    }
    let outcome = {
        let mut guard = pairing.lock().await;
        let Some(active) = guard.as_mut() else {
            return;
        };
        let mut store = PendingPeerStore::new(active.session.peer_key());
        match active.session.receive_confirm(Instant::now(), &mut store) {
            Ok(outcome) => {
                state.set_pairing_phase(Some(pairing_phase(&active.session, &active.machine_name)));
                Ok(outcome)
            }
            Err(error) => Err(error.to_string()),
        }
    };
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(detail) => {
            if let Ok(response) = error_envelope(proto::ErrorCode::Invalid, &detail) {
                let _ = request.respond(response).await;
            }
            fail_pairing(
                &state,
                &trust,
                &pairing,
                &pairing_reserved,
                openlogi_ipc::FlowPairingFailure::Protocol { message: detail },
            )
            .await;
            return;
        }
    };
    let Ok(response) = message_envelope(FrameKind::PairOutcome, &outcome) else {
        fail_pairing(
            &state,
            &trust,
            &pairing,
            &pairing_reserved,
            openlogi_ipc::FlowPairingFailure::Protocol {
                message: "could not encode pairing outcome".to_owned(),
            },
        )
        .await;
        return;
    };
    if request.respond(response).await.is_err() {
        fail_pairing(
            &state,
            &trust,
            &pairing,
            &pairing_reserved,
            openlogi_ipc::FlowPairingFailure::Connection {
                message: "could not send pairing outcome".to_owned(),
            },
        )
        .await;
        return;
    }
    let paired = pairing
        .lock()
        .await
        .as_ref()
        .is_some_and(|active| active.session.state() == PairingState::Paired);
    if paired {
        let Some(mut active) = pairing.lock().await.take() else {
            return;
        };
        match complete_pairing(&state, &trust, &mut active, &control_tx) {
            Ok(()) => pairing_reserved.store(false, Ordering::Release),
            Err(error) => {
                active.connection.close();
                trust.disable_pairing();
                pairing_reserved.store(false, Ordering::Release);
                state.set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Failed(
                    pairing_failure(&error),
                )));
            }
        }
    }
}

async fn handle_pairing_abort(
    state: Arc<GenerationState>,
    trust: PeerTrust,
    pairing: Arc<Mutex<Option<ActivePairing>>>,
    pairing_reserved: Arc<AtomicBool>,
    notification: openlogi_flow::frame::Envelope,
) {
    let Ok(abort) =
        notification.decode::<proto::PairAbort>(openlogi_flow::frame::InboundRole::Notification)
    else {
        fail_pairing(
            &state,
            &trust,
            &pairing,
            &pairing_reserved,
            openlogi_ipc::FlowPairingFailure::Protocol {
                message: "invalid PairAbort payload".to_owned(),
            },
        )
        .await;
        return;
    };
    let failure = match abort.reason.as_known() {
        Some(proto::PairAbortReason::CodeMismatch) => openlogi_ipc::FlowPairingFailure::Rejected,
        Some(proto::PairAbortReason::Timeout) => openlogi_ipc::FlowPairingFailure::Timeout,
        Some(proto::PairAbortReason::UserCancelled) => openlogi_ipc::FlowPairingFailure::Cancelled,
        Some(proto::PairAbortReason::Unspecified) | None => {
            openlogi_ipc::FlowPairingFailure::Protocol {
                message: "invalid PairAbort reason".to_owned(),
            }
        }
    };
    let valid = {
        let mut guard = pairing.lock().await;
        let Some(active) = guard.as_mut() else {
            return;
        };
        active.session.receive_abort(&abort).is_ok()
    };
    if valid {
        fail_pairing(&state, &trust, &pairing, &pairing_reserved, failure).await;
    } else {
        fail_pairing(
            &state,
            &trust,
            &pairing,
            &pairing_reserved,
            openlogi_ipc::FlowPairingFailure::Protocol {
                message: "PairAbort is invalid in the current state".to_owned(),
            },
        )
        .await;
    }
}

fn complete_pairing(
    state: &GenerationState,
    trust: &PeerTrust,
    active: &mut ActivePairing,
    control_tx: &mpsc::UnboundedSender<controller::Control>,
) -> Result<(), openlogi_ipc::FlowCommandError> {
    let key = active.session.peer_key();
    let public_key = format_public_key(key);
    let mut config =
        Config::load_or_default().map_err(|error| openlogi_ipc::FlowCommandError::Persistence {
            message: error.to_string(),
        })?;
    let base_name = if active.machine_name.trim().is_empty() {
        "OpenLogi peer".to_owned()
    } else {
        active.machine_name.trim().to_owned()
    };
    let mut name = base_name.clone();
    let mut suffix = 2_u32;
    while config
        .flow
        .peers
        .iter()
        .any(|peer| peer.name == name && peer.public_key != public_key)
    {
        name = format!("{base_name} ({suffix})");
        suffix = suffix.saturating_add(1);
    }
    if let Some(peer) = config
        .flow
        .peers
        .iter_mut()
        .find(|peer| peer.public_key == public_key)
    {
        name.clone_from(&peer.name);
        if !active.address.is_empty() && !peer.addresses.contains(&active.address) {
            peer.addresses.push(active.address.clone());
        }
    } else {
        config.flow.peers.push(FlowPeer {
            name: name.clone(),
            public_key: public_key.clone(),
            addresses: if active.address.is_empty() {
                Vec::new()
            } else {
                vec![active.address.clone()]
            },
        });
    }
    active
        .connection
        .promote_after_pairing(&active.session)
        .map_err(pairing_command_error)?;
    let inserted_pin = trust.pin(key);
    if let Err(error) = config.save_atomic() {
        if inserted_pin {
            let _ = trust.unpin(key);
        }
        active.connection.revoke_pairing_promotion();
        return Err(openlogi_ipc::FlowCommandError::Persistence {
            message: error.to_string(),
        });
    }
    trust.disable_pairing();
    state.set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Paired {
        name: name.clone(),
        public_key: public_key.clone(),
    }));
    let _ = control_tx.send(controller::Control::PairCompleted);
    Ok(())
}

fn pairing_phase(session: &PairingSession, machine_name: &str) -> openlogi_ipc::FlowPairingPhase {
    let public_key = format_public_key(session.peer_key());
    match session.state() {
        PairingState::Prompted {
            local_confirmed,
            peer_confirmed,
            ..
        } => openlogi_ipc::FlowPairingPhase::Prompted {
            public_key,
            machine_name: machine_name.to_owned(),
            sas: session
                .sas_code()
                .map_or_else(|| "------".to_owned(), |code| code.to_string()),
            local_confirmed,
            peer_confirmed,
        },
        PairingState::Paired => openlogi_ipc::FlowPairingPhase::Paired {
            name: machine_name.to_owned(),
            public_key,
        },
        PairingState::Rejected => {
            openlogi_ipc::FlowPairingPhase::Failed(openlogi_ipc::FlowPairingFailure::Rejected)
        }
        PairingState::TimedOut => {
            openlogi_ipc::FlowPairingPhase::Failed(openlogi_ipc::FlowPairingFailure::Timeout)
        }
        PairingState::Aborted(reason) => openlogi_ipc::FlowPairingPhase::Failed(match reason {
            PairingAbortReason::CodeMismatch => openlogi_ipc::FlowPairingFailure::Rejected,
            PairingAbortReason::Timeout => openlogi_ipc::FlowPairingFailure::Timeout,
            PairingAbortReason::UserCancelled => openlogi_ipc::FlowPairingFailure::Cancelled,
        }),
        PairingState::Idle | PairingState::AwaitingPrompt => {
            openlogi_ipc::FlowPairingPhase::Connecting {
                address: String::new(),
            }
        }
    }
}

fn pairing_already_completed(state: &GenerationState) -> bool {
    state
        .pairing_phase
        .read()
        .is_ok_and(|phase| matches!(&*phase, Some(openlogi_ipc::FlowPairingPhase::Paired { .. })))
}

fn format_public_key(key: PublicKey) -> String {
    let mut value = String::from("ed25519:");
    for byte in key.as_bytes() {
        use std::fmt::Write as _;
        let _ = write!(value, "{byte:02x}");
    }
    value
}

#[expect(
    clippy::needless_pass_by_value,
    reason = "used directly as map_err callback, which supplies owned protocol errors"
)]
fn pairing_command_error(error: impl ToString) -> openlogi_ipc::FlowCommandError {
    openlogi_ipc::FlowCommandError::Protocol {
        message: error.to_string(),
    }
}

fn pairing_failure(error: &openlogi_ipc::FlowCommandError) -> openlogi_ipc::FlowPairingFailure {
    match error {
        openlogi_ipc::FlowCommandError::Disabled | openlogi_ipc::FlowCommandError::Unavailable => {
            openlogi_ipc::FlowPairingFailure::Unavailable
        }
        openlogi_ipc::FlowCommandError::AlreadyActive => {
            openlogi_ipc::FlowPairingFailure::AlreadyActive
        }
        openlogi_ipc::FlowCommandError::NoActiveSession => {
            openlogi_ipc::FlowPairingFailure::NoActiveSession
        }
        openlogi_ipc::FlowCommandError::Invalid { message }
        | openlogi_ipc::FlowCommandError::Protocol { message } => {
            openlogi_ipc::FlowPairingFailure::Protocol {
                message: message.clone(),
            }
        }
        openlogi_ipc::FlowCommandError::Connection { message } => {
            openlogi_ipc::FlowPairingFailure::Connection {
                message: message.clone(),
            }
        }
        openlogi_ipc::FlowCommandError::Persistence { message } => {
            openlogi_ipc::FlowPairingFailure::Persistence {
                message: message.clone(),
            }
        }
    }
}

async fn fail_pairing(
    state: &GenerationState,
    trust: &PeerTrust,
    pairing: &Mutex<Option<ActivePairing>>,
    pairing_reserved: &AtomicBool,
    failure: openlogi_ipc::FlowPairingFailure,
) {
    let connection = pairing.lock().await.take().map(|active| active.connection);
    if let Some(connection) = connection {
        connection.close();
    }
    trust.disable_pairing();
    pairing_reserved.store(false, Ordering::Release);
    state.set_pairing_phase(Some(openlogi_ipc::FlowPairingPhase::Failed(failure)));
}

async fn run_clipboard_loop(state: Arc<GenerationState>) {
    let mut interval = tokio::time::interval(Duration::from_millis(250));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        interval.tick().await;
        if !state.is_active() {
            return;
        }
        let Some(announce) = state.clipboard.poll_local().await else {
            continue;
        };
        let Ok(envelope) = message_envelope(FrameKind::ClipboardAnnounce, &announce) else {
            continue;
        };
        for connection in state.connections_snapshot() {
            let _ = connection.notify(envelope.clone()).await;
        }
    }
}

pub(super) fn warp_entry(entry: &proto::EntryPoint) {
    let Some(side) = entry.side.as_known() else {
        return;
    };
    let displays = openlogi_hook::display_rects().unwrap_or_default();
    let edges = ExposedEdges::from_displays(&displays);
    let Some((x, y)) = point_on_edge(&edges, side, entry.t) else {
        return;
    };
    if !openlogi_inject::warp_cursor(x, y) {
        warn!(x, y, "Flow device arrived but cursor positioning failed");
    }
}

fn point_on_edge(edges: &ExposedEdges, side: proto::Side, t: f64) -> Option<(f64, f64)> {
    const INSET: f64 = 1.0;
    let side = match side {
        proto::Side::Left => EdgeSide::Left,
        proto::Side::Right => EdgeSide::Right,
        proto::Side::Top => EdgeSide::Top,
        proto::Side::Bottom => EdgeSide::Bottom,
        proto::Side::Unspecified => return None,
    };
    let segments: Vec<_> = edges.for_side(side).collect();
    let total: f64 = segments
        .iter()
        .map(|segment| segment.end() - segment.start())
        .sum();
    if total <= 0.0 {
        return None;
    }
    let mut offset = t.clamp(0.0, 1.0) * total;
    let segment = segments.iter().find(|segment| {
        let length = segment.end() - segment.start();
        if offset <= length {
            true
        } else {
            offset -= length;
            false
        }
    })?;
    let along = (segment.start() + offset).min(segment.end());
    Some(match side {
        EdgeSide::Left => (segment.coordinate() + INSET, along),
        EdgeSide::Right => (segment.coordinate() - INSET, along),
        EdgeSide::Top => (along, segment.coordinate() + INSET),
        EdgeSide::Bottom => (along, segment.coordinate() - INSET),
    })
}

const fn ipc_link_state(state: LinkState) -> FlowLinkState {
    match state {
        LinkState::Connected => FlowLinkState::Connected,
        LinkState::Degraded => FlowLinkState::Degraded,
        LinkState::Lost => FlowLinkState::Lost,
    }
}

fn machine_name() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .ok()
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "OpenLogi".to_owned())
}

fn platform() -> proto::Platform {
    if cfg!(target_os = "macos") {
        proto::Platform::Macos
    } else if cfg!(target_os = "linux") {
        if std::env::var_os("WAYLAND_DISPLAY").is_some() {
            proto::Platform::LinuxWayland
        } else {
            proto::Platform::LinuxX11
        }
    } else if cfg!(target_os = "windows") {
        proto::Platform::Windows
    } else {
        proto::Platform::Other
    }
}

fn load_machine_identity() -> Result<MachineIdentity, FlowRuntimeError> {
    let path = openlogi_core::paths::data_dir()?.join(FLOW_IDENTITY_FILE);
    load_machine_identity_at(&path)
}

fn load_machine_identity_at(path: &Path) -> Result<MachineIdentity, FlowRuntimeError> {
    match fs::read(path) {
        Ok(bytes) => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt as _;
                fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            }
            return MachineIdentity::from_pkcs8(bytes).map_err(FlowRuntimeError::from);
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let identity = MachineIdentity::generate()?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    match options.open(path) {
        Ok(mut file) => {
            file.write_all(identity.private_key_pkcs8())?;
            file.sync_all()?;
            Ok(identity)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            MachineIdentity::from_pkcs8(fs::read(path)?).map_err(FlowRuntimeError::from)
        }
        Err(error) => Err(error.into()),
    }
}

#[derive(Debug, Error)]
enum FlowRuntimeError {
    #[error(transparent)]
    Paths(#[from] openlogi_core::paths::PathsError),
    #[error("Flow identity I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error(transparent)]
    Identity(#[from] openlogi_flow::transport::IdentityError),
    #[error(transparent)]
    Transport(#[from] openlogi_flow::transport::TransportError),
    #[error(transparent)]
    Discovery(#[from] openlogi_flow::discovery::DiscoveryError),
    #[error(transparent)]
    Session(#[from] openlogi_flow::session::SessionManagerError),
    #[error("Flow pairing runtime failed: {0}")]
    Pairing(String),
    #[error("Flow identity task failed: {0}")]
    IdentityTask(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use openlogi_core::device::DeviceKind;
    use openlogi_fixture::{
        CassetteExchange, FIXTURE_SCHEMA_VERSION, HidCassette, ReportSupport, RequestMatch,
    };
    use openlogi_flow::transport::{MachineIdentity, PeerTrust};
    use openlogi_hid::replay::{
        ChannelConnection, NodePresence, OpenOutcome, RawWriterAvailability, ReplayBackend,
        ReplayChannel, ReplayNode, ReplayTopology,
    };
    use openlogi_hook::edge::DisplayRect;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;
    use std::time::Duration;
    use tempfile::tempdir;

    #[test]
    fn maps_entry_across_disconnected_exposed_segments() {
        let displays = [
            DisplayRect::new(0.0, 0.0, 100.0, 100.0).unwrap(),
            DisplayRect::new(0.0, 200.0, 100.0, 100.0).unwrap(),
        ];
        let edges = ExposedEdges::from_displays(&displays);
        assert_eq!(
            point_on_edge(&edges, proto::Side::Left, 0.25),
            Some((1.0, 50.0))
        );
        assert_eq!(
            point_on_edge(&edges, proto::Side::Left, 0.75),
            Some((1.0, 250.0))
        );
    }

    #[test]
    fn maps_entry_to_each_side_inside_the_display_bounds() {
        let edges =
            ExposedEdges::from_displays(&[DisplayRect::new(0.0, 0.0, 100.0, 80.0).unwrap()]);
        assert_eq!(
            point_on_edge(&edges, proto::Side::Left, 0.25),
            Some((1.0, 20.0))
        );
        assert_eq!(
            point_on_edge(&edges, proto::Side::Right, 0.25),
            Some((99.0, 20.0))
        );
        assert_eq!(
            point_on_edge(&edges, proto::Side::Top, 0.25),
            Some((25.0, 1.0))
        );
        assert_eq!(
            point_on_edge(&edges, proto::Side::Bottom, 0.25),
            Some((25.0, 79.0))
        );
        assert_eq!(
            point_on_edge(&edges, proto::Side::Right, -1.0),
            Some((99.0, 0.0))
        );
        assert_eq!(
            point_on_edge(&edges, proto::Side::Right, 2.0),
            Some((99.0, 80.0))
        );
        assert_eq!(point_on_edge(&edges, proto::Side::Unspecified, 0.5), None);
    }

    #[test]
    fn machine_identity_is_persistent_and_private() {
        let directory = tempdir().expect("temporary directory");
        let path = directory.path().join(FLOW_IDENTITY_FILE);
        let first = load_machine_identity_at(&path).expect("generate identity");

        #[cfg(unix)]
        {
            let mode = fs::metadata(&path)
                .expect("identity metadata")
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
                .expect("loosen permissions for reload test");
        }

        let second = load_machine_identity_at(&path).expect("reload identity");
        assert_eq!(first.public_key(), second.public_key());
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(&path)
                .expect("identity metadata")
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn invalid_machine_identity_is_not_silently_replaced() {
        let directory = tempdir().expect("temporary directory");
        let path = directory.path().join(FLOW_IDENTITY_FILE);
        let invalid = b"not a PKCS#8 Ed25519 private key";
        fs::write(&path, invalid).expect("write invalid identity");

        assert!(matches!(
            load_machine_identity_at(&path),
            Err(FlowRuntimeError::Identity(_))
        ));
        assert_eq!(fs::read(path).expect("read invalid identity"), invalid);
    }

    #[tokio::test]
    async fn crossing_switches_replayed_device_and_reports_receiver_arrival() {
        let devices = [
            test_device("mouse", 0xb35b, DeviceKind::Mouse, "flow-mouse"),
            test_device("keyboard", 0xb35c, DeviceKind::Keyboard, "flow-keyboard"),
        ];
        let channels = ["flow-mouse", "flow-keyboard"];
        let mut pair = TestFlowPair::new_devices(
            devices
                .into_iter()
                .zip(channels)
                .map(|(device, channel)| (device, change_host_cassette(channel)))
                .collect(),
        )
        .await;
        pair.start_crossing();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let complete = channels.iter().all(|channel| {
                    pair.backend
                        .channel_completion(channel)
                        .is_ok_and(|completion| {
                            completion.channel_open_count > 0
                                && completion.unmatched_requests.is_empty()
                                && completion.unconsumed_required.is_empty()
                        })
                });
                if complete {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("handoff ChangeHost replay did not complete"));
        for channel in channels {
            let completion = pair
                .backend
                .channel_completion(channel)
                .expect("ChangeHost channel");
            assert_eq!(completion.channel_open_count, 1);
            assert!(completion.unmatched_requests.is_empty());
        }
        pair.backend
            .require_complete()
            .expect("ChangeHost cassette fully consumed");

        pair.arrive_all().await;
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if pair.receiver.handoffs.has_completed_incoming().await {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("receiver must record the arrival result");
        let result = pair
            .receiver
            .handoffs
            .completed_incoming_result()
            .await
            .expect("completed handoff result");
        assert_eq!(
            result.outcome.as_known(),
            Some(proto::HandoffOutcome::Arrived)
        );
        assert_eq!(result.arrivals.len(), 2);
        assert!(result.arrivals.iter().all(|arrival| arrival.arrived));
        let mut arrived_devices: Vec<_> = result
            .arrivals
            .iter()
            .map(|arrival| {
                arrival
                    .device
                    .as_option()
                    .expect("arrival identifies its device")
                    .name
                    .as_str()
            })
            .collect();
        arrived_devices.sort_unstable();
        assert_eq!(
            arrived_devices,
            [
                "flow-test-keyboard-flow-keyboard",
                "flow-test-mouse-flow-mouse"
            ]
        );
        tokio::time::timeout(Duration::from_secs(2), async {
            while pair.sender.handoffs.has_outgoing().await {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("sender must consume the receiver arrival result");
        pair.close().await;
    }

    #[tokio::test]
    async fn multi_device_handoff_reports_partial_when_only_mouse_arrives() {
        let devices = [
            test_device("mouse", 0xb35b, DeviceKind::Mouse, "partial-mouse"),
            test_device("keyboard", 0xb35c, DeviceKind::Keyboard, "partial-keyboard"),
        ];
        let channels = ["partial-mouse", "partial-keyboard"];
        let mut pair = TestFlowPair::new_devices(
            devices
                .into_iter()
                .zip(channels)
                .map(|(device, channel)| (device, change_host_cassette(channel)))
                .collect(),
        )
        .await;
        pair.start_crossing();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let complete = channels.iter().all(|channel| {
                    pair.backend
                        .channel_completion(channel)
                        .is_ok_and(|completion| completion.is_complete())
                });
                if complete {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("both devices must switch before arrival tracking begins");

        pair.arrive_indices(&[0]).await;
        tokio::time::timeout(Duration::from_secs(5), async {
            while !pair.receiver.handoffs.has_completed_incoming().await {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("receiver must report partial arrival after its arm deadline");
        let result = pair
            .receiver
            .handoffs
            .completed_incoming_result()
            .await
            .expect("completed partial handoff result");
        assert_eq!(
            result.outcome.as_known(),
            Some(proto::HandoffOutcome::Partial)
        );
        assert_eq!(result.arrivals.len(), 2);
        assert_eq!(
            result
                .arrivals
                .iter()
                .filter(|arrival| arrival.arrived)
                .count(),
            1
        );
        let arrival_by_device: HashMap<_, _> = result
            .arrivals
            .iter()
            .map(|arrival| {
                (
                    arrival
                        .device
                        .as_option()
                        .expect("arrival identifies its device")
                        .name
                        .as_str(),
                    arrival.arrived,
                )
            })
            .collect();
        assert_eq!(
            arrival_by_device.get("flow-test-mouse-partial-mouse"),
            Some(&true)
        );
        assert_eq!(
            arrival_by_device.get("flow-test-keyboard-partial-keyboard"),
            Some(&false)
        );
        assert_eq!(
            result
                .arrivals
                .iter()
                .filter(|arrival| !arrival.arrived)
                .count(),
            1
        );
        pair.close().await;
    }

    #[tokio::test]
    async fn failed_change_host_cancels_accepted_handoff_without_arrival_result() {
        const CHANNEL: &str = "flow-change-host-failure";
        let pair = TestFlowPair::new(change_host_feature_missing_cassette(CHANNEL)).await;
        let feature_lookup = [0x10, 0xff, 0x00, 0x00, 0x18, 0x14, 0x00];
        let response_barrier = pair
            .backend
            .hold_next_response(CHANNEL, RequestMatch::Hidpp20, &feature_lookup)
            .expect("ChangeHost lookup response barrier");

        pair.start_crossing();
        tokio::time::timeout(Duration::from_secs(2), async {
            while !pair.receiver.handoffs.has_accepted_incoming().await {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("receiver acceptance must be bounded");
        assert!(pair.receiver.handoffs.has_accepted_incoming().await);
        tokio::time::timeout(Duration::from_secs(2), response_barrier.request_written())
            .await
            .expect("sender must attempt ChangeHost after receiver acceptance");
        response_barrier.release();

        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if !pair.receiver.handoffs.has_accepted_incoming().await
                    && !pair.sender.handoffs.has_outgoing().await
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("SwitchFailed cancellation must clear both pending handoffs");
        assert!(!pair.receiver.handoffs.has_completed_incoming().await);
        pair.backend
            .require_complete()
            .expect("unsupported ChangeHost fixture fully consumed");
        pair.close().await;
    }

    struct TestFlowPair {
        backend: Arc<ReplayBackend>,
        sender: Arc<GenerationState>,
        receiver: Arc<GenerationState>,
        receiver_snapshots: Vec<FlowDeviceSnapshot>,
        sender_connection: Arc<FlowConnection>,
        receiver_connection: Arc<FlowConnection>,
        application_loops: [JoinHandle<()>; 2],
        _endpoints: [Arc<FlowEndpoint>; 2],
    }

    impl TestFlowPair {
        async fn new(cassette: HidCassette) -> Self {
            let channel = cassette.channel.clone();
            Self::new_devices(vec![(
                test_device("mouse", 0xb35b, DeviceKind::Mouse, &channel),
                cassette,
            )])
            .await
        }

        #[expect(
            clippy::too_many_lines,
            reason = "the shared test fixture wires both peers, QUIC, and replay backend"
        )]
        async fn new_devices(devices: Vec<(FlowDeviceSnapshot, HidCassette)>) -> Self {
            let product_ids: HashMap<_, _> = devices
                .iter()
                .map(|(snapshot, _)| match snapshot.route.as_ref() {
                    Some(DeviceRoute::Direct { product_id, .. }) => {
                        (snapshot.config_key.as_str(), *product_id)
                    }
                    _ => panic!("test Flow device must use a direct route"),
                })
                .collect();
            let backend = Arc::new(
                ReplayBackend::new(
                    ReplayTopology {
                        nodes: devices
                            .iter()
                            .map(|(snapshot, cassette)| ReplayNode {
                                info: openlogi_hid::NodeInfo {
                                    id: openlogi_hid::NodeId::from(format!(
                                        "flow-node-{}",
                                        snapshot.config_key
                                    )),
                                    vendor_id: 0x046d,
                                    product_id: product_ids[snapshot.config_key.as_str()],
                                    usage_page: 0xff00,
                                    usage_id: 0x0002,
                                    name: format!("Flow replay {}", snapshot.config_key),
                                    manufacturer: Some("Logitech".into()),
                                    serial_number: snapshot.serial.clone(),
                                },
                                presence: NodePresence::Present,
                                open_outcome: OpenOutcome::Hidpp,
                                channel: Some(cassette.channel.clone()),
                                raw_writer: RawWriterAvailability::Unavailable,
                                receiver_slots: Vec::new(),
                            })
                            .collect(),
                        channels: devices
                            .iter()
                            .map(|(_, cassette)| ReplayChannel {
                                id: cassette.channel.clone(),
                                connection: ChannelConnection::Connected,
                                report_support: ReportSupport::ShortAndLong,
                            })
                            .collect(),
                    },
                    devices
                        .iter()
                        .map(|(_, cassette)| cassette.clone())
                        .collect(),
                )
                .expect("valid Flow replay fixture"),
            );

            let sender_identity = MachineIdentity::generate().expect("sender identity");
            let receiver_identity = MachineIdentity::generate().expect("receiver identity");
            let sender_key = sender_identity.public_key();
            let receiver_key = receiver_identity.public_key();
            let sender_endpoint = Arc::new(
                test_endpoint(&sender_identity, receiver_key, [31; 16]).expect("sender endpoint"),
            );
            let receiver_endpoint = Arc::new(
                test_endpoint(&receiver_identity, sender_key, [32; 16]).expect("receiver endpoint"),
            );
            let receiver_acceptor = Arc::clone(&receiver_endpoint);
            let accept = tokio::spawn(async move { receiver_acceptor.accept().await });
            let sender_connection = Arc::new(
                sender_endpoint
                    .connect(receiver_endpoint.local_addr().expect("receiver address"))
                    .await
                    .expect("QUIC connection"),
            );
            let receiver_connection = Arc::new(
                accept
                    .await
                    .expect("accept task")
                    .expect("accepted QUIC connection"),
            );
            let snapshots: Vec<_> = devices
                .iter()
                .map(|(snapshot, _)| snapshot.clone())
                .collect();
            let sender = Arc::new(test_generation(
                receiver_key,
                "receiver",
                &snapshots,
                ChannelPool::with_backend(backend.clone()),
            ));
            let mut receiver_snapshots = snapshots.clone();
            for snapshot in &mut receiver_snapshots {
                snapshot.route = None;
                snapshot.online = false;
            }
            let empty_backend = Arc::new(
                ReplayBackend::new(
                    ReplayTopology {
                        nodes: Vec::new(),
                        channels: Vec::new(),
                    },
                    Vec::new(),
                )
                .expect("empty receiver replay backend"),
            );
            let receiver = Arc::new(test_generation(
                sender_key,
                "sender",
                &receiver_snapshots,
                ChannelPool::with_backend(empty_backend),
            ));
            sender.set_connection(receiver_key, Some(Arc::clone(&sender_connection)));
            receiver.set_connection(sender_key, Some(Arc::clone(&receiver_connection)));
            let sender_loop = tokio::spawn(run_application_connection(
                Arc::clone(&sender),
                receiver_key,
                Arc::clone(&sender_connection),
            ));
            let receiver_loop = tokio::spawn(run_application_connection(
                Arc::clone(&receiver),
                sender_key,
                Arc::clone(&receiver_connection),
            ));

            Self {
                backend,
                sender,
                receiver,
                receiver_snapshots,
                sender_connection,
                receiver_connection,
                application_loops: [sender_loop, receiver_loop],
                _endpoints: [sender_endpoint, receiver_endpoint],
            }
        }

        fn start_crossing(&self) {
            super::super::handoff::start_outgoing(
                Arc::clone(&self.sender),
                openlogi_hook::edge::EdgeCrossing {
                    side: EdgeSide::Right,
                    t: 0.5,
                    velocity: openlogi_hook::edge::Velocity { x: 1.0, y: 0.0 },
                },
            );
        }

        async fn arrive_all(&mut self) {
            self.arrive_indices(&(0..self.receiver_snapshots.len()).collect::<Vec<_>>())
                .await;
        }

        async fn arrive_indices(&mut self, indices: &[usize]) {
            for &index in indices {
                self.receiver_snapshots[index].online = true;
            }
            self.receiver.update_devices(&self.receiver_snapshots);
            inventory_changed(Arc::clone(&self.receiver)).await;
        }

        async fn close(self) {
            for task in &self.application_loops {
                task.abort();
            }
            for task in self.application_loops {
                let _ = task.await;
            }
            self.sender_connection.close();
            self.receiver_connection.close();
        }
    }

    fn test_endpoint(
        identity: &MachineIdentity,
        peer: PublicKey,
        nonce: [u8; 16],
    ) -> Result<FlowEndpoint, openlogi_flow::transport::TransportError> {
        FlowEndpoint::bind(
            SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
            identity.clone(),
            PeerTrust::pinned([peer]),
            proto::Hello {
                proto_min: 1,
                proto_max: 1,
                public_key: identity.public_key().as_bytes().to_vec(),
                session_nonce: nonce.to_vec(),
                machine_name: "flow-runtime-test".into(),
                app_version: "test".into(),
                ..Default::default()
            },
        )
    }

    fn test_generation(
        peer: PublicKey,
        peer_name: &str,
        snapshots: &[FlowDeviceSnapshot],
        channel_pool: ChannelPool,
    ) -> GenerationState {
        let devices = snapshots
            .iter()
            .map(|snapshot| {
                (
                    snapshot.config_key.clone(),
                    std::collections::BTreeMap::from([("self".into(), 0), (peer_name.into(), 1)]),
                )
            })
            .collect();
        GenerationState::new(
            Arc::new(CompiledFlowConfig {
                enabled: true,
                peers: vec![super::super::config::CompiledPeer {
                    name: peer_name.into(),
                    public_key: peer,
                    canonical_key: super::super::config::format_public_key(peer),
                    addresses: Vec::new(),
                }],
                layout: HashMap::from([(EdgeSide::Right, 0)]),
                devices,
            }),
            snapshots,
            Arc::new(ObservableState::new("flow-test".into())),
            channel_pool,
            crate::receiver_access::ReceiverAccess::default(),
            Arc::new(ClipboardManager::new(
                crate::flow::clipboard::default_backend(),
            )),
        )
    }

    fn test_device(
        name: &str,
        product_id: u16,
        kind: DeviceKind,
        channel: &str,
    ) -> FlowDeviceSnapshot {
        FlowDeviceSnapshot {
            config_key: format!("flow-test-{name}-{channel}"),
            route: Some(DeviceRoute::Direct {
                vendor_id: 0x046d,
                product_id,
            }),
            serial: Some(format!("FLOW-TEST-{name}")),
            unit_id: [0; 4],
            kind,
            online: true,
        }
    }

    fn change_host_cassette(channel: &str) -> HidCassette {
        fn h20(request: Vec<u8>, response: Vec<u8>) -> CassetteExchange {
            CassetteExchange {
                request_match: RequestMatch::Hidpp20,
                request,
                response: Some(response),
                required: true,
            }
        }
        let short = |device, feature, function, payload: [u8; 3]| {
            vec![
                0x10, device, feature, function, payload[0], payload[1], payload[2],
            ]
        };
        HidCassette {
            schema_version: FIXTURE_SCHEMA_VERSION,
            name: "flow ChangeHost handoff".into(),
            channel: channel.into(),
            report_support: ReportSupport::ShortAndLong,
            exchanges: vec![
                h20(
                    short(0xff, 0, 0x10, [0, 0, 0]),
                    short(0xff, 0, 0x10, [4, 0, 0]),
                ),
                h20(
                    short(0xff, 0, 0, [0x18, 0x14, 0]),
                    short(0xff, 0, 0, [4, 0, 0]),
                ),
                h20(short(0xff, 4, 0, [0, 0, 0]), short(0xff, 4, 0, [2, 0, 0])),
                h20(
                    short(0xff, 0, 0, [0x18, 0x15, 0]),
                    short(0xff, 0, 0, [5, 0, 0]),
                ),
                h20(
                    short(0xff, 5, 0x10, [1, 0, 0]),
                    short(0xff, 5, 0x10, [1, 1, 0]),
                ),
                CassetteExchange {
                    request_match: RequestMatch::Hidpp20,
                    request: short(0xff, 4, 0x10, [1, 0, 0]),
                    response: None,
                    required: true,
                },
            ],
        }
    }

    fn change_host_feature_missing_cassette(channel: &str) -> HidCassette {
        let short = |device, feature, function, payload: [u8; 3]| {
            vec![
                0x10, device, feature, function, payload[0], payload[1], payload[2],
            ]
        };
        HidCassette {
            schema_version: FIXTURE_SCHEMA_VERSION,
            name: "flow ChangeHost unsupported".into(),
            channel: channel.into(),
            report_support: ReportSupport::ShortAndLong,
            exchanges: vec![
                CassetteExchange {
                    request_match: RequestMatch::Hidpp20,
                    request: short(0xff, 0, 0x10, [0, 0, 0]),
                    response: Some(short(0xff, 0, 0x10, [4, 0, 0])),
                    required: true,
                },
                CassetteExchange {
                    request_match: RequestMatch::Hidpp20,
                    request: short(0xff, 0, 0, [0x18, 0x14, 0]),
                    response: Some(short(0xff, 0, 0, [0, 0, 0])),
                    required: true,
                },
            ],
        }
    }
}
