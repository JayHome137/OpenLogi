# TwinDesk Flow mechanism-borrow plan

Status: design proposal only. This records mechanism-level lessons from the
TwinDesk comparison; it does not import or adapt TwinDesk code, helpers, or
protocol. The product boundary remains OpenLogi Flow's Logitech HID++
`ChangeHost` handoff.

## Current baseline

The current Flow already computes exposed display edges and applies a dwell,
approach-speed, rearm-distance, and cooldown policy in `openlogi-hook`. Its
agent-core handoff asks the receiver to arm and return `HandoffAccept` before
issuing `ChangeHost`, tracks attempts by `transfer_id`, supports cancellation,
and waits for positive arrival evidence. Departed-keyboard modifiers also have
a release path. TwinDesk's value here is a comparison checklist for edge
geometry, ownership transitions, and failure lifecycle, not an implementation
template.

## Layer placement

- **Agent-core Flow (`openlogi-agent-core/src/flow`)** owns the handoff
  transaction, validation against current peer/device state, timeout policy,
  cancellation, and recovery decisions. Keep network waits outside the
  lifecycle lock and keep the host switch as the point of no return.
- **Flow protocol (`openlogi-flow/proto/flow.v1.proto`)** remains the typed,
  versioned peer contract. Current edge tuning is local policy and does not
  need wire fields. Append typed Flow fields/messages only when a cross-peer
  fact is required, with compatibility and capability rules documented in
  `FLOW-PROTOCOL.md`. Never use TwinDesk `k.*`/`kvm.*`, ports 47800/47801, or
  its framing.
- **Hook (`openlogi-hook`)** owns platform cursor observations and pure
  exposed-edge detection. Preserve the present pass-through behavior: Flow
  does not capture or swallow ordinary OS input. Reuse or extend OpenLogi's
  own platform APIs only if a proven host-switch requirement needs them.
- **Inject (`openlogi-inject`)** remains limited to local cursor placement and
  existing local input lifecycle operations. It must not become a remote
  keystroke/pointer injection backend under this plan.
- **Helper boundary** is not needed for the current HID++ handoff. If a later,
  separately approved product requires privileged capture, first define a
  narrow OpenLogi-owned helper API, permission lifecycle, process identity,
  fail-open/fail-closed behavior, and packaging. No TwinDesk helper source or
  derived helper design is to be copied.
- **Desktop UI (`openlogi-desktop`)** owns local Flow layout, modifier guard,
  peer status, and actionable handoff diagnostics. Keep it an IPC client; do
  not put HID I/O or peer-protocol handling in the GUI.

## MVP steps

1. **Freeze the existing handoff invariants with focused proofs.** Exercise
   exposed-edge geometry on irregular multi-display layouts, dwell versus fast
   approach, cooldown/rearm, and modifier-gated crossing. Acceptance: tests
   show no crossing through an internal display edge, no repeated trigger while
   latched, and no `ChangeHost` before a matching receiver acceptance.
2. **Prove transaction failure and recovery boundaries.** Cover rejection,
   lost/late acceptance, switch failure after acceptance, receiver timeout,
   cancellation, duplicate/replayed transfer IDs, disconnect during a pending
   arrival, and device return while the prior acknowledgement is pending.
   Acceptance: every path clears or supersedes pending state, never switches
   twice for one transfer, and exposes a useful local diagnostic; no blind
   automatic reverse switch is attempted after device ownership is uncertain.
3. **Audit input lifecycle around the physical device handoff.** Verify
   held-modifier release when the keyboard leaves, preservation when it stays,
   and that ordinary pointer/button/key input is neither swallowed nor
   duplicated by Flow. Acceptance: regression tests cover departure and
   return, while Flow still carries no OS input frames across the network.
4. **Only then consider policy controls.** If reports show defaults are
   inadequate, add a small local configuration surface for dwell/guard
   behavior and expose effective state through existing IPC/UI ownership.
   Acceptance: defaults preserve current behavior, invalid values are rejected
   at the config owner, and the edge detector applies a live update without
   restarting peer sessions. No peer schema change unless the policy must be
   negotiated by both machines.

Each implementation step should land as its own focused PR slice after this
design-only branch. Run the narrow hook/agent-core tests first, then the
affected crate checks and UI verification only for crates actually changed.

## Branch and PR plan

- **This branch (`feat/twindesk-flow-borrow`)**: this design note and the GM
  conclusion only. No runtime code, schema edits, UI changes, push, or PR in
  this round.
- **Future PR 1**: focused geometry and edge-trigger regression proofs, plus
  only the smallest verified detector correction if a test exposes a defect.
- **Future PR 2**: handoff lifecycle/recovery proofs and any narrowly scoped
  agent-core fix revealed by them. Keep the existing typed Flow messages and
  `Accept`-before-`ChangeHost` contract unless evidence requires an append-only
  protocol addition.
- **Future PR 3, conditional**: local tuning and UI only if the MVP proves
  users need it. A software KVM or remote OS-input path is a separate product
  decision and is outside this branch and plan.

All future work targets `openlogi-custom` through normal PR review. `master`
continues to mirror upstream; do not move its history or force-update the
custom branch tip.

## Risks and non-goals

- **License boundary:** TwinDesk is GPL-3.0 while OpenLogi is MIT/Apache-2.0.
  Borrow only independently stated behavior and testable requirements. Do not
  copy, translate, adapt, or link TwinDesk code or helper logic; request legal
  review if a future design creates a derivative-work or distribution
  question.
- **Permissions and platform coverage:** macOS input permissions, Linux
  display-server/input restrictions, and Windows secure-desktop/UIPI behavior
  matter if capture is ever proposed. The current handoff path should not gain
  new OS-level capture permissions.
- **Two input/ownership sources:** remote OS input would compete with the
  physical Logitech device and make held-state ownership ambiguous. It is
  explicitly excluded; HID++ `ChangeHost` remains the sole handoff path.
- **Switch uncertainty:** after `ChangeHost`, the sender may lose its device
  connection before learning the result. Arrival timeout is diagnostic, not
  proof that an automatic reverse switch is safe. Preserve positive arrival
  evidence and explicit cancellation semantics.
- **Protocol and compatibility:** no TwinDesk message names, ports, helpers,
  or wire assumptions. Any necessary cross-peer extension belongs in the
  OpenLogi Flow protobuf schema, is append-only, and needs skew tests.
- **Non-goals:** software KVM, remote keyboard/mouse event transport, global
  capture-and-swallow, Android control, protocol interoperability with
  TwinDesk, and a new privileged helper in this round.

## Source comparison

The decision follows the final evaluation at
`/workspace/agent-tools/twindesk-gm-report.md` and spot checks of OpenLogi's
`docs/FLOW-DESIGN.md`, `crates/openlogi-hook/src/edge/detector.rs`,
`crates/openlogi-agent-core/src/flow/handoff/`, and
`crates/openlogi-flow/proto/flow.v1.proto`. TwinDesk was read only to compare
edge-map, capture ordering, and cleanup concepts; no source was reused.
