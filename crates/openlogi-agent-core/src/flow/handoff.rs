use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use openlogi_flow::frame::{FrameKind, InboundRole, MAX_CHUNK_LEN};
use openlogi_flow::generated as proto;
use openlogi_flow::identity::same_device;
use openlogi_flow::sas::PublicKey;
use openlogi_flow::transport::{
    BulkRpcResponse, IncomingRpc, NotificationEvent, RpcEvent, error_envelope, message_envelope,
};
use sha2::{Digest, Sha256};
use tokio::sync::{Mutex, oneshot};
use tokio::time::Instant;
use tracing::debug;

use super::clipboard::{MAX_CLIPBOARD_BYTES, MAX_FILE_LIST_BYTES};
use super::runtime::GenerationState;
use super::{RuntimeDevice, is_pointing_device};

const ARM_TIMEOUT: Duration = Duration::from_secs(3);
const COMPLETED_LIMIT: usize = 64;

mod sender;

pub(super) use sender::start_outgoing;

#[derive(Default)]
pub(super) struct HandoffBook {
    incoming: Mutex<IncomingLedger>,
    outgoing: Mutex<HashMap<u64, OutgoingWaiter>>,
    sender_busy: std::sync::atomic::AtomicBool,
}

#[derive(Default)]
struct IncomingLedger {
    pending: Option<PendingIncoming>,
    completed: HashMap<(PublicKey, u64), CompletedIncoming>,
    completion_order: VecDeque<(PublicKey, u64)>,
}

struct PendingIncoming {
    peer: PublicKey,
    transfer_id: u64,
    entry: proto::EntryPoint,
    devices: Vec<PendingDevice>,
    accepted_at: Option<Instant>,
}

struct PendingDevice {
    key: String,
    identity: proto::DeviceIdentity,
    pointing: bool,
    arrived_at: Option<Instant>,
}

#[derive(Clone)]
struct CompletedIncoming {
    accept: proto::HandoffAccept,
    result: proto::HandoffResult,
}

struct OutgoingWaiter {
    peer: PublicKey,
    result: oneshot::Sender<OutgoingSignal>,
}

enum OutgoingSignal {
    Result(proto::HandoffResult),
    Cancelled,
}

enum ArmDecision {
    New(proto::HandoffAccept),
    Duplicate(proto::HandoffAccept),
    Replay {
        accept: proto::HandoffAccept,
        result: proto::HandoffResult,
    },
    Reject(proto::HandoffReject),
}

impl HandoffBook {
    #[cfg(test)]
    pub(super) async fn has_outgoing(&self) -> bool {
        !self.outgoing.lock().await.is_empty()
    }

    #[cfg(test)]
    pub(super) async fn has_completed_incoming(&self) -> bool {
        !self.incoming.lock().await.completed.is_empty()
    }

    #[cfg(test)]
    pub(super) async fn has_accepted_incoming(&self) -> bool {
        self.incoming
            .lock()
            .await
            .pending
            .as_ref()
            .is_some_and(|pending| pending.accepted_at.is_some())
    }

    #[cfg(test)]
    pub(super) async fn completed_incoming_result(&self) -> Option<proto::HandoffResult> {
        self.incoming
            .lock()
            .await
            .completed
            .values()
            .next()
            .map(|completed| completed.result.clone())
    }

    async fn arm(
        &self,
        peer: PublicKey,
        request: &proto::HandoffRequest,
        local_devices: &[RuntimeDevice],
        enabled: bool,
    ) -> ArmDecision {
        let reject = |reason: proto::HandoffRejectReason, detail: &str| {
            ArmDecision::Reject(proto::HandoffReject {
                transfer_id: request.transfer_id,
                reason: reason.into(),
                detail: detail.to_owned(),
                ..Default::default()
            })
        };
        if !enabled {
            return reject(proto::HandoffRejectReason::Disabled, "Flow is disabled");
        }
        if request.transfer_id == 0 || request.devices.is_empty() || !valid_entry(request) {
            return reject(
                proto::HandoffRejectReason::NotReady,
                "invalid handoff request",
            );
        }

        let key = (peer, request.transfer_id);
        let mut ledger = self.incoming.lock().await;
        if let Some(completed) = ledger.completed.get(&key) {
            return ArmDecision::Replay {
                accept: completed.accept.clone(),
                result: completed.result.clone(),
            };
        }
        if let Some(pending) = &ledger.pending {
            if pending.peer == peer && pending.transfer_id == request.transfer_id {
                return ArmDecision::Duplicate(accept(request.transfer_id));
            }
            return reject(
                proto::HandoffRejectReason::AlreadyPending,
                "another transfer is already armed",
            );
        }

        let mut matched = Vec::with_capacity(request.devices.len());
        for requested in &request.devices {
            let local = local_devices
                .iter()
                .find(|local| same_device(requested, &local.identity).unwrap_or(false));
            let Some(local) = local else {
                return reject(
                    proto::HandoffRejectReason::UnknownDevice,
                    "a requested device is not configured locally",
                );
            };
            if local.snapshot.online {
                return reject(
                    proto::HandoffRejectReason::NotReady,
                    "a requested device is already online on the receiver",
                );
            }
            if matched
                .iter()
                .any(|device: &PendingDevice| device.key == local.snapshot.config_key)
            {
                return reject(
                    proto::HandoffRejectReason::UnknownDevice,
                    "the request repeats one physical device",
                );
            }
            matched.push(PendingDevice {
                key: local.snapshot.config_key.clone(),
                identity: local.identity.clone(),
                pointing: is_pointing_device(local.snapshot.kind),
                arrived_at: None,
            });
        }

        ledger.pending = Some(PendingIncoming {
            peer,
            transfer_id: request.transfer_id,
            entry: request.entry.as_option().cloned().unwrap_or_default(),
            devices: matched,
            accepted_at: None,
        });
        ArmDecision::New(accept(request.transfer_id))
    }

    async fn mark_accepted(&self, peer: PublicKey, transfer_id: u64) -> bool {
        let mut ledger = self.incoming.lock().await;
        let Some(pending) = ledger.pending.as_mut() else {
            return false;
        };
        if pending.peer != peer || pending.transfer_id != transfer_id {
            return false;
        }
        if pending.accepted_at.is_some() {
            return false;
        }
        pending.accepted_at = Some(Instant::now());
        true
    }

    async fn observe(&self, devices: &[RuntimeDevice]) -> Option<CompletedTransfer> {
        let mut ledger = self.incoming.lock().await;
        let pending = ledger.pending.as_mut()?;
        for expected in &mut pending.devices {
            if expected.arrived_at.is_none()
                && devices.iter().any(|device| {
                    device.snapshot.config_key == expected.key && device.snapshot.online
                })
            {
                expected.arrived_at = Some(Instant::now());
            }
        }
        let accepted = pending.accepted_at?;
        if pending
            .devices
            .iter()
            .all(|device| device.arrived_at.is_some())
        {
            return Some(complete_pending(&mut ledger, accepted, false));
        }
        None
    }

    async fn expire(&self, peer: PublicKey, transfer_id: u64) -> Option<CompletedTransfer> {
        let mut ledger = self.incoming.lock().await;
        let pending = ledger.pending.as_ref()?;
        if pending.peer != peer || pending.transfer_id != transfer_id {
            return None;
        }
        let accepted = pending.accepted_at?;
        Some(complete_pending(&mut ledger, accepted, true))
    }

    async fn cancel_unaccepted(&self, peer: PublicKey, transfer_id: u64) -> bool {
        let mut ledger = self.incoming.lock().await;
        if ledger.pending.as_ref().is_some_and(|pending| {
            pending.peer == peer
                && pending.transfer_id == transfer_id
                && pending.accepted_at.is_none()
        }) {
            ledger.pending = None;
            true
        } else {
            false
        }
    }

    async fn cancel_incoming(&self, peer: PublicKey, transfer_id: u64) -> bool {
        let mut ledger = self.incoming.lock().await;
        if ledger
            .pending
            .as_ref()
            .is_some_and(|pending| pending.peer == peer && pending.transfer_id == transfer_id)
        {
            ledger.pending = None;
            true
        } else {
            false
        }
    }

    async fn register_outgoing(
        &self,
        peer: PublicKey,
        transfer_id: u64,
    ) -> oneshot::Receiver<OutgoingSignal> {
        let (sender, receiver) = oneshot::channel();
        self.outgoing.lock().await.insert(
            transfer_id,
            OutgoingWaiter {
                peer,
                result: sender,
            },
        );
        receiver
    }

    async fn remove_outgoing(&self, transfer_id: u64) {
        self.outgoing.lock().await.remove(&transfer_id);
    }

    async fn deliver_result(&self, peer: PublicKey, result: proto::HandoffResult) -> bool {
        let mut outgoing = self.outgoing.lock().await;
        let Some(waiter) = outgoing.remove(&result.transfer_id) else {
            return false;
        };
        if waiter.peer != peer {
            outgoing.insert(result.transfer_id, waiter);
            return false;
        }
        let _ = waiter.result.send(OutgoingSignal::Result(result));
        true
    }

    async fn cancel_outgoing(&self, peer: PublicKey, transfer_id: u64) -> bool {
        let mut outgoing = self.outgoing.lock().await;
        let Some(waiter) = outgoing.remove(&transfer_id) else {
            return false;
        };
        if waiter.peer != peer {
            outgoing.insert(transfer_id, waiter);
            return false;
        }
        let _ = waiter.result.send(OutgoingSignal::Cancelled);
        true
    }

    /// Drops all in-flight transfers owned by a disconnected peer and wakes
    /// outgoing waiters so a stale connection cannot block the next crossing.
    pub(super) async fn forget_peer(&self, peer: PublicKey) {
        {
            let mut incoming = self.incoming.lock().await;
            if incoming
                .pending
                .as_ref()
                .is_some_and(|pending| pending.peer == peer)
            {
                incoming.pending = None;
            }
            incoming
                .completed
                .retain(|(candidate, _), _| *candidate != peer);
            incoming
                .completion_order
                .retain(|(candidate, _)| *candidate != peer);
        }
        let mut outgoing = self.outgoing.lock().await;
        let current = std::mem::take(&mut *outgoing);
        for (transfer_id, waiter) in current {
            if waiter.peer == peer {
                let _ = waiter.result.send(OutgoingSignal::Cancelled);
            } else {
                outgoing.insert(transfer_id, waiter);
            }
        }
    }
}

pub(super) async fn handle_rpc(state: Arc<GenerationState>, peer: PublicKey, event: RpcEvent) {
    let RpcEvent::Request(rpc) = event else {
        return;
    };
    if rpc.request().kind == FrameKind::ClipboardFetch {
        let Ok(request) = rpc
            .request()
            .decode::<proto::ClipboardFetch>(InboundRole::Request)
        else {
            return;
        };
        respond_clipboard_fetch(state, rpc, request).await;
        return;
    }
    if rpc.request().kind == FrameKind::FileFetch {
        let Ok(request) = rpc
            .request()
            .decode::<proto::FileFetch>(InboundRole::Request)
        else {
            return;
        };
        respond_file_fetch(state, rpc, request).await;
        return;
    }
    if rpc.request().kind != FrameKind::HandoffRequest {
        return;
    }
    let Ok(request) = rpc
        .request()
        .decode::<proto::HandoffRequest>(InboundRole::Request)
    else {
        return;
    };
    let devices = state
        .devices
        .read()
        .map_or_else(|_| Vec::new(), |guard| guard.clone());
    let decision = state
        .handoffs
        .arm(
            peer,
            &request,
            &devices,
            state.config.enabled && state.is_active(),
        )
        .await;
    respond_to_arm(state, peer, rpc, decision).await;
}

async fn respond_clipboard_fetch(
    state: Arc<GenerationState>,
    rpc: IncomingRpc,
    request: proto::ClipboardFetch,
) {
    let fetched = if request.mime == super::clipboard::FILES_MIME {
        state
            .clipboard
            .fetch_file_list(request.sequence, request.offset)
            .await
    } else {
        state
            .clipboard
            .fetch(request.sequence, &request.mime, request.offset)
            .await
            .map(|(local, bytes)| (local.sequence, local.bytes.len() as u64, bytes))
    };
    let Ok((sequence, total_size, bytes)) = fetched else {
        if let Ok(error) = error_envelope(
            proto::ErrorCode::Invalid,
            "clipboard sequence, MIME, or offset is invalid",
        ) {
            let _ = rpc.respond(error).await;
        }
        return;
    };
    let Ok(head) = message_envelope(
        FrameKind::ClipboardData,
        &proto::ClipboardData {
            sequence,
            mime: request.mime,
            total_size,
            ..Default::default()
        },
    ) else {
        respond_clipboard_error(rpc, "could not encode clipboard response").await;
        return;
    };
    let mut chunks = Vec::with_capacity(bytes.len().div_ceil(MAX_CHUNK_LEN));
    for chunk in bytes.chunks(MAX_CHUNK_LEN) {
        let Ok(frame) = message_envelope(
            FrameKind::Chunk,
            &proto::Chunk {
                data: chunk.to_vec(),
                ..Default::default()
            },
        ) else {
            respond_clipboard_error(rpc, "could not encode clipboard chunk").await;
            return;
        };
        chunks.push(frame);
    }
    let checksum: [u8; 32] = Sha256::digest(&bytes).into();
    let Ok(end) = message_envelope(
        FrameKind::ChunkEnd,
        &proto::ChunkEnd {
            sha256: Some(checksum.to_vec()),
            ..Default::default()
        },
    ) else {
        respond_clipboard_error(rpc, "could not encode clipboard terminator").await;
        return;
    };
    let _ = rpc.respond_bulk(head, chunks, end).await;
}

async fn respond_file_fetch(
    state: Arc<GenerationState>,
    rpc: IncomingRpc,
    request: proto::FileFetch,
) {
    let fetched = state
        .clipboard
        .fetch_file(request.sequence, request.file_index, request.offset)
        .await;
    let Ok((sequence, total_size, bytes)) = fetched else {
        if let Ok(error) = error_envelope(
            proto::ErrorCode::Invalid,
            "file generation or index is invalid",
        ) {
            let _ = rpc.respond(error).await;
        }
        return;
    };
    let head = proto::ClipboardData {
        sequence,
        mime: "application/octet-stream".to_owned(),
        total_size,
        ..Default::default()
    };
    let Ok(head) = message_envelope(FrameKind::ClipboardData, &head) else {
        return;
    };
    let chunks = bytes
        .chunks(MAX_CHUNK_LEN)
        .map(|chunk| {
            message_envelope(
                FrameKind::Chunk,
                &proto::Chunk {
                    data: chunk.to_vec(),
                    ..Default::default()
                },
            )
        })
        .collect::<Result<Vec<_>, _>>();
    let Ok(chunks) = chunks else {
        return;
    };
    let checksum: [u8; 32] = Sha256::digest(&bytes).into();
    let Ok(end) = message_envelope(
        FrameKind::ChunkEnd,
        &proto::ChunkEnd {
            sha256: Some(checksum.to_vec()),
            ..Default::default()
        },
    ) else {
        return;
    };
    let _ = rpc.respond_bulk(head, chunks, end).await;
}

async fn respond_clipboard_error(rpc: IncomingRpc, detail: &str) {
    if let Ok(error) = error_envelope(proto::ErrorCode::Internal, detail) {
        let _ = rpc.respond(error).await;
    }
}

async fn respond_to_arm(
    state: Arc<GenerationState>,
    peer: PublicKey,
    rpc: IncomingRpc,
    decision: ArmDecision,
) {
    match decision {
        ArmDecision::New(acceptance) => {
            let transfer_id = acceptance.transfer_id;
            let Ok(envelope) = message_envelope(FrameKind::HandoffAccept, &acceptance) else {
                return;
            };
            if rpc.respond(envelope).await.is_err() {
                state.handoffs.cancel_unaccepted(peer, transfer_id).await;
                return;
            }
            accept_pending(state, peer, transfer_id).await;
        }
        ArmDecision::Duplicate(acceptance) => {
            let transfer_id = acceptance.transfer_id;
            if let Ok(envelope) = message_envelope(FrameKind::HandoffAccept, &acceptance)
                && rpc.respond(envelope).await.is_ok()
            {
                accept_pending(state, peer, transfer_id).await;
            }
        }
        ArmDecision::Replay { accept, result } => {
            let Ok(envelope) = message_envelope(FrameKind::HandoffAccept, &accept) else {
                return;
            };
            if rpc.respond(envelope).await.is_ok() {
                let _lifecycle = state.lifecycle.lock().await;
                if state.is_active() {
                    state.send_result(peer, result).await;
                }
            }
        }
        ArmDecision::Reject(rejection) => {
            if let Ok(envelope) = message_envelope(FrameKind::HandoffReject, &rejection) {
                let _ = rpc.respond(envelope).await;
            }
        }
    }
}

async fn accept_pending(state: Arc<GenerationState>, peer: PublicKey, transfer_id: u64) {
    let completed = {
        let _lifecycle = state.lifecycle.lock().await;
        if !state.is_active() {
            state.handoffs.cancel_incoming(peer, transfer_id).await;
            state
                .send_cancel(peer, transfer_id, proto::HandoffCancelReason::Shutdown)
                .await;
            return;
        }
        if state.handoffs.mark_accepted(peer, transfer_id).await {
            spawn_arm_timeout(Arc::clone(&state), peer, transfer_id);
            state.handoffs.observe(&state.devices_snapshot()).await
        } else {
            None
        }
    };
    if let Some(completed) = completed {
        finish_incoming(state, completed).await;
    }
}

fn spawn_arm_timeout(state: Arc<GenerationState>, peer: PublicKey, transfer_id: u64) {
    tokio::spawn(async move {
        tokio::time::sleep(ARM_TIMEOUT).await;
        if let Some(completed) = state.handoffs.expire(peer, transfer_id).await {
            finish_incoming(state, completed).await;
        }
    });
}

pub(super) async fn inventory_changed(state: Arc<GenerationState>) {
    if let Some(completed) = state.handoffs.observe(&state.devices_snapshot()).await {
        finish_incoming(state, completed).await;
    }
}

async fn finish_incoming(state: Arc<GenerationState>, completed: CompletedTransfer) {
    let _lifecycle = state.lifecycle.lock().await;
    if !state.is_active() {
        state
            .send_cancel(
                completed.peer,
                completed.result.transfer_id,
                proto::HandoffCancelReason::Shutdown,
            )
            .await;
        return;
    }
    if completed.warp_pointer {
        super::runtime::warp_entry(&completed.entry);
    }
    state.send_result(completed.peer, completed.result).await;
}

pub(super) async fn handle_notification(
    state: Arc<GenerationState>,
    peer: PublicKey,
    event: NotificationEvent,
) {
    let NotificationEvent::Notification(notification) = event else {
        return;
    };
    match notification.kind {
        FrameKind::AnnounceDevices => {
            let Ok(announce) =
                notification.decode::<proto::AnnounceDevices>(InboundRole::Notification)
            else {
                return;
            };
            if !state.update_remote_devices(peer, announce) {
                debug!("stale Flow device announcement ignored");
            }
        }
        FrameKind::PeerState => {
            let Ok(peer_state) = notification.decode::<proto::PeerState>(InboundRole::Notification)
            else {
                return;
            };
            if !state.update_remote_state(peer, peer_state) {
                debug!("stale Flow peer state ignored");
            }
        }
        FrameKind::HandoffResult => {
            let Ok(result) = notification.decode::<proto::HandoffResult>(InboundRole::Notification)
            else {
                return;
            };
            if !state.handoffs.deliver_result(peer, result.clone()).await {
                debug!(
                    transfer_id = result.transfer_id,
                    "stale Flow handoff result ignored"
                );
            }
        }
        FrameKind::HandoffCancel => {
            let Ok(cancel) = notification.decode::<proto::HandoffCancel>(InboundRole::Notification)
            else {
                return;
            };
            let incoming = state
                .handoffs
                .cancel_incoming(peer, cancel.transfer_id)
                .await;
            let outgoing = state
                .handoffs
                .cancel_outgoing(peer, cancel.transfer_id)
                .await;
            if !(incoming || outgoing) {
                debug!(
                    transfer_id = cancel.transfer_id,
                    "stale Flow handoff cancel ignored"
                );
            }
        }
        FrameKind::ClipboardAnnounce => {
            let Ok(announce) =
                notification.decode::<proto::ClipboardAnnounce>(InboundRole::Notification)
            else {
                return;
            };
            // Prefetch into the Flow clipboard cache, but do not touch the host
            // clipboard until the input hook observes Cmd/Ctrl+V.
            if let Some((sequence, mime)) = state.clipboard.accept_announce(peer, &announce).await {
                let fetch_state = Arc::clone(&state);
                tokio::spawn(async move {
                    fetch_remote_clipboard(fetch_state, peer, sequence, mime, 0).await;
                });
            }
        }
        _ => {}
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "clipboard and file-list fetch share one validated transfer lifecycle"
)]
pub(super) async fn fetch_remote_clipboard(
    state: Arc<GenerationState>,
    peer: PublicKey,
    sequence: u64,
    mime: String,
    offset: u64,
) {
    let Some(connection) = state.connection(peer) else {
        return;
    };
    let Ok(request) = message_envelope(
        FrameKind::ClipboardFetch,
        &proto::ClipboardFetch {
            sequence,
            mime: mime.clone(),
            offset,
            ..Default::default()
        },
    ) else {
        return;
    };
    let Ok(response) = connection.call_bulk(request).await else {
        return;
    };
    let BulkRpcResponse::Data(response) = response else {
        return;
    };
    if mime == super::clipboard::TEXT_MIME {
        let Some((total_size, bytes, checksum)) =
            read_text_bulk_response(state.as_ref(), response, peer, sequence, offset).await
        else {
            return;
        };
        if total_size <= MAX_CLIPBOARD_BYTES as u64 {
            let _ = state
                .clipboard
                .apply_remote(peer, sequence, offset, bytes, checksum)
                .await;
        }
        return;
    }
    let max_size = if mime == super::clipboard::FILES_MIME {
        MAX_FILE_LIST_BYTES
    } else {
        return;
    };
    let Some((total_size, bytes, checksum)) =
        read_bulk_response(response, sequence, &mime, offset, max_size).await
    else {
        return;
    };
    if mime != super::clipboard::FILES_MIME || offset != 0 {
        return;
    }
    if total_size > MAX_FILE_LIST_BYTES as u64 {
        return;
    }
    let Ok(entries) = state
        .clipboard
        .validate_remote_file_list(peer, sequence, &bytes, checksum)
        .await
    else {
        return;
    };
    let mut files = Vec::with_capacity(entries.len());
    for (index, entry) in entries.iter().enumerate() {
        let Ok(request) = message_envelope(
            FrameKind::FileFetch,
            &proto::FileFetch {
                sequence,
                file_index: u32::try_from(index).unwrap_or(u32::MAX),
                offset: 0,
                ..Default::default()
            },
        ) else {
            return;
        };
        let Ok(BulkRpcResponse::Data(response)) = connection.call_bulk(request).await else {
            return;
        };
        let Some((total_size, bytes, checksum)) = read_bulk_response(
            response,
            sequence,
            "application/octet-stream",
            0,
            usize::try_from(entry.size_bytes).unwrap_or(usize::MAX),
        )
        .await
        else {
            return;
        };
        let file_hash: [u8; 32] = Sha256::digest(&bytes).into();
        if total_size != entry.size_bytes
            || bytes.len() as u64 != entry.size_bytes
            || checksum.is_some_and(|expected| expected != file_hash)
        {
            return;
        }
        files.push((entry.relative_path.clone(), bytes));
    }
    let identity_digest = super::clipboard::file_identity_digest(&proto::FileList {
        files: entries,
        ..Default::default()
    });
    let _ = state
        .clipboard
        .apply_remote_files(peer, sequence, files, identity_digest)
        .await;
}

async fn read_text_bulk_response(
    state: &GenerationState,
    mut response: openlogi_flow::transport::BulkResponse,
    peer: PublicKey,
    sequence: u64,
    offset: u64,
) -> Option<(u64, Vec<u8>, Option<[u8; 32]>)> {
    let head = response
        .head()
        .decode::<proto::ClipboardData>(InboundRole::Notification)
        .ok()?;
    if head.sequence != sequence || head.mime != super::clipboard::TEXT_MIME {
        return None;
    }
    let total_size = head.total_size;
    let total_size_usize = usize::try_from(total_size).ok()?;
    if total_size_usize > MAX_CLIPBOARD_BYTES {
        return None;
    }
    let offset = usize::try_from(offset).ok()?;
    if offset > total_size_usize {
        return None;
    }
    let expected_size = total_size_usize - offset;
    let mut bytes = Vec::with_capacity(expected_size);
    let checksum = loop {
        let Ok(Some(frame)) = response.next_frame().await else {
            return None;
        };
        match frame.kind {
            FrameKind::Chunk => {
                let chunk = frame
                    .decode::<proto::Chunk>(InboundRole::Notification)
                    .ok()?;
                if chunk.data.len() > MAX_CHUNK_LEN
                    || bytes.len().saturating_add(chunk.data.len()) > expected_size
                {
                    return None;
                }
                let chunk_offset = u64::try_from(offset + bytes.len()).ok()?;
                state
                    .clipboard
                    .apply_remote_chunk(peer, sequence, chunk_offset, &chunk.data)
                    .await
                    .ok()?;
                bytes.extend_from_slice(&chunk.data);
            }
            FrameKind::ChunkEnd => {
                let end = frame
                    .decode::<proto::ChunkEnd>(InboundRole::Notification)
                    .ok()?;
                let checksum = match end.sha256.as_deref() {
                    None => None,
                    Some(value) => Some(<[u8; 32]>::try_from(value).ok()?),
                };
                break checksum;
            }
            _ => return None,
        }
    };
    (bytes.len() == expected_size).then_some((total_size, bytes, checksum))
}

async fn read_bulk_response(
    mut response: openlogi_flow::transport::BulkResponse,
    sequence: u64,
    mime: &str,
    offset: u64,
    max_size: usize,
) -> Option<(u64, Vec<u8>, Option<[u8; 32]>)> {
    let head = response
        .head()
        .decode::<proto::ClipboardData>(InboundRole::Notification)
        .ok()?;
    if head.sequence != sequence || head.mime != mime {
        return None;
    }
    let total_size = head.total_size;
    let total_size_usize = usize::try_from(total_size).ok()?;
    if total_size_usize > max_size {
        return None;
    }
    let offset = usize::try_from(offset).ok()?;
    if offset > total_size_usize {
        return None;
    }
    let expected_size = total_size_usize - offset;
    let mut bytes = Vec::with_capacity(expected_size);
    let checksum = loop {
        let Ok(Some(frame)) = response.next_frame().await else {
            return None;
        };
        match frame.kind {
            FrameKind::Chunk => {
                let chunk = frame
                    .decode::<proto::Chunk>(InboundRole::Notification)
                    .ok()?;
                if chunk.data.len() > MAX_CHUNK_LEN
                    || bytes.len().saturating_add(chunk.data.len()) > expected_size
                {
                    return None;
                }
                bytes.extend_from_slice(&chunk.data);
            }
            FrameKind::ChunkEnd => {
                let end = frame
                    .decode::<proto::ChunkEnd>(InboundRole::Notification)
                    .ok()?;
                let checksum = match end.sha256.as_deref() {
                    None => None,
                    Some(value) => Some(<[u8; 32]>::try_from(value).ok()?),
                };
                break checksum;
            }
            _ => return None,
        }
    };
    (bytes.len() == expected_size).then_some((total_size, bytes, checksum))
}

struct CompletedTransfer {
    peer: PublicKey,
    entry: proto::EntryPoint,
    result: proto::HandoffResult,
    warp_pointer: bool,
}

fn complete_pending(
    ledger: &mut IncomingLedger,
    accepted_at: Instant,
    timed_out: bool,
) -> CompletedTransfer {
    let pending = ledger
        .pending
        .take()
        .unwrap_or_else(|| unreachable!("completion requires a pending transfer"));
    let arrived_count = pending
        .devices
        .iter()
        .filter(|device| device.arrived_at.is_some())
        .count();
    let outcome = if arrived_count == pending.devices.len() {
        proto::HandoffOutcome::Arrived
    } else if arrived_count > 0 {
        proto::HandoffOutcome::Partial
    } else if timed_out {
        proto::HandoffOutcome::Timeout
    } else {
        unreachable!("non-timeout completion has at least one arrival")
    };
    let arrivals = pending
        .devices
        .iter()
        .map(|device| {
            let mut arrival = proto::DeviceArrival {
                arrived: device.arrived_at.is_some(),
                elapsed_ms: device.arrived_at.map_or(0, |arrived| {
                    u32::try_from(arrived.duration_since(accepted_at).as_millis())
                        .unwrap_or(u32::MAX)
                }),
                ..Default::default()
            };
            *arrival.device.get_or_insert_default() = device.identity.clone();
            arrival
        })
        .collect();
    let result = proto::HandoffResult {
        transfer_id: pending.transfer_id,
        outcome: outcome.into(),
        arrivals,
        ..Default::default()
    };
    let completed = CompletedIncoming {
        accept: accept(pending.transfer_id),
        result: result.clone(),
    };
    let key = (pending.peer, pending.transfer_id);
    ledger.completed.insert(key, completed);
    ledger.completion_order.push_back(key);
    while ledger.completion_order.len() > COMPLETED_LIMIT {
        if let Some(expired) = ledger.completion_order.pop_front() {
            ledger.completed.remove(&expired);
        }
    }
    CompletedTransfer {
        peer: pending.peer,
        entry: pending.entry,
        result,
        warp_pointer: pending
            .devices
            .iter()
            .any(|device| device.pointing && device.arrived_at.is_some()),
    }
}

fn accept(transfer_id: u64) -> proto::HandoffAccept {
    proto::HandoffAccept {
        transfer_id,
        arm_timeout_ms: u32::try_from(ARM_TIMEOUT.as_millis())
            .unwrap_or_else(|_| unreachable!("three seconds fits in u32 milliseconds")),
        ..Default::default()
    }
}

fn valid_entry(request: &proto::HandoffRequest) -> bool {
    request.entry.as_option().is_some_and(|entry| {
        entry
            .side
            .as_known()
            .is_some_and(|side| side != proto::Side::Unspecified)
            && entry.t.is_finite()
            && (0.0..=1.0).contains(&entry.t)
    })
}

#[cfg(test)]
mod tests;
