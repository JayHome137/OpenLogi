use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use openlogi_flow::frame::{Envelope, FrameKind, InboundRole};
use openlogi_flow::generated as proto;
use openlogi_flow::transport::{FlowConnection, message_envelope};
use openlogi_hook::edge::{EdgeCrossing, EdgeSide};
use tracing::{debug, info, warn};

use super::OutgoingSignal;
use crate::flow::config::CompiledPeer;
use crate::flow::runtime::{GenerationState, OutgoingDevice};

const NETWORK_SLACK: Duration = Duration::from_secs(2);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_PEER_ARM_TIMEOUT: Duration = Duration::from_secs(10);

pub(in crate::flow) fn start_outgoing(state: Arc<GenerationState>, crossing: EdgeCrossing) {
    if !state.is_active()
        || state
            .handoffs
            .sender_busy
            .swap(true, std::sync::atomic::Ordering::AcqRel)
    {
        return;
    }
    tokio::spawn(async move {
        // A crossing here means the devices are here: settle any transfer
        // still waiting for the inventory to notice them.
        if let Some(completed) = state.handoffs.complete_on_departure().await {
            super::finish_incoming(Arc::clone(&state), completed).await;
        }
        let acknowledgment = run_outgoing(&state, crossing).await;
        // The devices are gone, so nothing here can cross again until they
        // come back, and when they do that crossing must not queue behind
        // this transfer's arrival acknowledgment (up to its whole deadline).
        state
            .handoffs
            .sender_busy
            .store(false, std::sync::atomic::Ordering::Release);
        if let Some(acknowledgment) = acknowledgment {
            await_acknowledgment(&state, acknowledgment).await;
        }
    });
}

/// What a crossing hands off, captured from one consistent generation view.
struct OutgoingPlan {
    peer: CompiledPeer,
    connection: Arc<FlowConnection>,
    targets: Vec<OutgoingDevice>,
}

/// Validates a crossing under the lifecycle lock and releases it again.
///
/// The lock is held only for this snapshot and later around the host switch
/// itself, never across the network round trips (up to ~2 s for acceptance,
/// and the arrival acknowledgment, awaited once the lock and the busy flag
/// are released). Holding it for the whole
/// transaction stalled config reloads (`shutdown`), link-state updates and
/// incoming handoffs for as long as the peer took to answer.
async fn plan_outgoing(state: &GenerationState, crossing: EdgeCrossing) -> Option<OutgoingPlan> {
    let _lifecycle = state.lifecycle.lock().await;
    if !state.is_active() {
        return None;
    }
    let peer = state.layout_peer(crossing.side)?.clone();
    let Some(connection) = state.connection(peer.public_key) else {
        debug!(peer = %peer.name, "Flow edge ignored while peer is disconnected");
        return None;
    };
    let targets = state.outgoing_devices(&peer.name);
    if targets.is_empty() {
        warn!(peer = %peer.name, "Flow edge has no online configured devices to hand off");
        return None;
    }
    if state.remote_holds_any(peer.public_key, &targets) {
        warn!(
            peer = %peer.name,
            "Flow edge ignored because the peer still reports one target device as held"
        );
        return None;
    }
    Some(OutgoingPlan {
        peer,
        connection,
        targets,
    })
}

/// A switched transfer still waiting for the receiver's arrival result.
struct Acknowledgment {
    peer: String,
    transfer_id: u64,
    deadline: Duration,
    result: tokio::sync::oneshot::Receiver<OutgoingSignal>,
}

/// Run one outgoing handoff up to the host switch; returns the pending
/// acknowledgment when the switch was issued.
async fn run_outgoing(
    state: &Arc<GenerationState>,
    crossing: EdgeCrossing,
) -> Option<Acknowledgment> {
    let OutgoingPlan {
        peer,
        connection,
        targets,
    } = plan_outgoing(state, crossing).await?;

    let transfer_id = random_transfer_id();
    let mut request = proto::HandoffRequest {
        transfer_id,
        devices: targets
            .iter()
            .map(|target| target.identity.clone())
            .collect(),
        sent_at_ms: unix_millis(),
        ..Default::default()
    };
    *request.entry.get_or_insert_default() = entry_from_crossing(crossing);
    let Ok(envelope) = message_envelope(FrameKind::HandoffRequest, &request) else {
        return None;
    };
    // Register before opening the RPC stream: QUIC does not order the response
    // stream against the receiver's HandoffResult notification stream.
    let result = state
        .handoffs
        .register_outgoing(peer.public_key, transfer_id)
        .await;
    let Some(deadline) = request_acceptance(&connection, &peer.name, transfer_id, envelope).await
    else {
        state.handoffs.remove_outgoing(transfer_id).await;
        return None;
    };
    // A config reload deactivates a generation at this lock boundary: the
    // host switch runs entirely on the generation that accepted, or not at
    // all (switch_devices re-checks `is_active` under the lock and returns
    // Ok(false), which cancels the peer's pending arrival).
    let switched = {
        let _lifecycle = state.lifecycle.lock().await;
        state.switch_devices(&targets).await
    };
    match switched {
        Ok(true) => {
            // Peers see the devices gone now, not once the inventory notices.
            state.publish_device_state().await;
            release_departed_modifiers(state, &targets);
        }
        Ok(false) => {
            state.handoffs.remove_outgoing(transfer_id).await;
            state
                .send_cancel(
                    peer.public_key,
                    transfer_id,
                    proto::HandoffCancelReason::Shutdown,
                )
                .await;
            return None;
        }
        Err(error) => {
            state.handoffs.remove_outgoing(transfer_id).await;
            warn!(%error, peer = %peer.name, "Flow host switch failed after receiver acceptance");
            state
                .send_cancel(
                    peer.public_key,
                    transfer_id,
                    proto::HandoffCancelReason::SwitchFailed,
                )
                .await;
            return None;
        }
    }

    Some(Acknowledgment {
        peer: peer.name,
        transfer_id,
        deadline,
        result,
    })
}

/// Log how the receiver reported the transfer's arrival.
async fn await_acknowledgment(state: &GenerationState, acknowledgment: Acknowledgment) {
    let Acknowledgment {
        peer,
        transfer_id,
        deadline,
        result,
    } = acknowledgment;
    match tokio::time::timeout(deadline, result).await {
        Ok(Ok(OutgoingSignal::Result(result))) => {
            info!(
                peer,
                transfer_id,
                outcome = result.outcome.to_i32(),
                "Flow handoff completed"
            );
        }
        Ok(Ok(OutgoingSignal::Cancelled)) => {
            debug!(peer, transfer_id, "Flow handoff cancelled by peer");
        }
        Ok(Err(_)) | Err(_) => {
            state.handoffs.remove_outgoing(transfer_id).await;
            warn!(peer, transfer_id, "Flow arrival acknowledgment timed out");
        }
    }
}

/// How long a departed keyboard's modifiers are left alone, so a receiver
/// that releases keys on disconnect does so first.
const MODIFIER_RELEASE_DELAY: Duration = Duration::from_millis(300);

/// A keyboard that left with a modifier down (Ctrl held to cross, say) never
/// sends its release here; release what is still down once it has gone.
fn release_departed_modifiers(state: &Arc<GenerationState>, targets: &[OutgoingDevice]) {
    let keys: Vec<String> = targets
        .iter()
        .filter(|target| !target.pointing)
        .map(|target| target.key.clone())
        .collect();
    if keys.is_empty() {
        // Every keyboard stayed: a modifier down now is held on purpose.
        return;
    }
    let state = Arc::clone(state);
    tokio::spawn(async move {
        tokio::time::sleep(MODIFIER_RELEASE_DELAY).await;
        if !state.all_departed(&keys) {
            // A keyboard came back: what it holds down now is held.
            return;
        }
        let released = openlogi_inject::release_stuck_modifiers();
        if released > 0 {
            info!(
                released,
                "Flow released modifier keys the departed keyboard left down"
            );
        }
    });
}

async fn request_acceptance(
    connection: &FlowConnection,
    peer_name: &str,
    transfer_id: u64,
    request: Envelope,
) -> Option<Duration> {
    let response = match tokio::time::timeout(REQUEST_TIMEOUT, connection.call(request)).await {
        Ok(Ok(response)) => response,
        Ok(Err(error)) => {
            debug!(%error, peer = peer_name, "Flow handoff request failed");
            return None;
        }
        Err(_) => {
            debug!(peer = peer_name, "Flow handoff request timed out");
            return None;
        }
    };
    if response.kind == FrameKind::HandoffReject {
        if let Ok(rejection) = response.decode::<proto::HandoffReject>(InboundRole::Request) {
            debug!(
                peer = peer_name,
                reason = rejection.reason.to_i32(),
                "Flow handoff rejected"
            );
        }
        return None;
    }
    if response.kind != FrameKind::HandoffAccept {
        return None;
    }
    let Ok(acceptance) = response.decode::<proto::HandoffAccept>(InboundRole::Request) else {
        return None;
    };
    let arm_timeout = Duration::from_millis(u64::from(acceptance.arm_timeout_ms));
    if acceptance.transfer_id != transfer_id
        || arm_timeout.is_zero()
        || arm_timeout > MAX_PEER_ARM_TIMEOUT
    {
        warn!(
            peer = peer_name,
            "Flow peer returned an invalid handoff acceptance"
        );
        return None;
    }
    Some(arm_timeout + NETWORK_SLACK)
}

fn entry_from_crossing(crossing: EdgeCrossing) -> proto::EntryPoint {
    let mut entry = proto::EntryPoint {
        side: receiver_side(crossing.side).into(),
        t: crossing.t.clamp(0.0, 1.0),
        ..Default::default()
    };
    *entry.velocity.get_or_insert_default() = proto::Vec2 {
        x: crossing.velocity.x,
        y: crossing.velocity.y,
        ..Default::default()
    };
    entry
}

const fn receiver_side(side: EdgeSide) -> proto::Side {
    match side {
        EdgeSide::Left => proto::Side::Right,
        EdgeSide::Right => proto::Side::Left,
        EdgeSide::Top => proto::Side::Bottom,
        EdgeSide::Bottom => proto::Side::Top,
    }
}

fn random_transfer_id() -> u64 {
    loop {
        let id = rand::random();
        if id != 0 {
            return id;
        }
    }
}

fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
        })
}
