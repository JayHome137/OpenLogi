# Stable v0.9.0 integration review

Status: **source integration blocked; review proposal only**. Recorded on 2026-11-21,
Asia/Shanghai (CST, UTC+8). This branch starts at custom and changes documentation
only. It is not a merged release candidate, and merging this document would not
upgrade the application.

## Scope and verified inputs

- Custom base: `685448ed66e4e01ec82ff94f6d68bf6f683b7376`.
- Latest stable GitHub Release: [v0.9.0](https://github.com/AprilNEA/OpenLogi/releases/tag/v0.9.0),
  published 2026-11-04 07:47:35 CST; commit
  `a5b507ec8802e0ecb7ef3de61ce7868609c9b533`, annotated tag object
  `86d5e51be8818a050f4d32cb94e6e705b2a2b362`.
- Upstream master: `9ca7ef0cbd1f4577ffdc338f8288f8c3a410f013`, also the
  prerelease `v0.9.1-beta.144`, published 2026-11-13 15:17:50 CST.
- User master remains `aeab6038e0e66cab49504a79301da4fdae416455`.
- Common ancestor for custom and stable:
  `525422a4ccb6679a542dd66e957cfa8bd9eed436`.
- Upstream master is tracked separately on
  [chore/upstream-master-snapshot-20261121-9ca7ef0c](https://github.com/JayHome137/OpenLogi/tree/chore/upstream-master-snapshot-20261121-9ca7ef0c).
  Its 144 commits after stable are excluded from the stable candidate.

Both repositories' default branches are `master`. The fork has no published
GitHub release (`releases/latest` returned 404; its releases list was empty).
The live API responses, fetched refs, commands, timestamps, exit codes and source
copies are retained on the review box in
`/workspace/agent-tools/openlogi-upstream-sync-20261121/evidence/`.
The complete Chinese report is `REPORT.md` in that task directory.

## Why the merge stopped

An isolated `git merge --no-commit --no-ff` of the stable commit into the custom
base produced **67 conflicted files**. Both sides independently added Flow at
the same paths, so this is an API and lifecycle migration, not a lockfile repair.
Conflict files, base/ours/theirs index stages, combined diff, and the automatically
merged diff were preserved before `git merge --abort`. No partial resolution or
product-source change remains in this branch. No whole-file side selection was
used. The file-by-file disposition is in the appendix.

The old automated sync's Cargo.lock-only failure was for **master plus stable**,
not custom plus stable. Its [failed run](https://github.com/JayHome137/OpenLogi/actions/runs/43009500095)
does not predict this branch's conflict surface.

Three blockers are reproduced with real parsers in an isolated synthetic fixture
harness: custom accepts `clipboard = false` and `port = 50000`, while the stable
config loader rejects both as unknown fields; the custom empty PairStart wire
message decodes as protobuf under stable but fails the new 32-byte nonce-commitment
validation. A minimal common config passes both loaders. These four passing
probes **prove incompatibility**, not successful migration. The first harness
attempt failed to compile because of a mutable-slice argument; that evidence is
preserved separately from the corrected run.

## Flow assessment from source

Official stable Flow has a real end-to-end implementation for hardware handoff,
including UI, pairing, QUIC, device preparation, host switching, arrival tracking
and reconnection. It is **not a complete substitute for this custom product**.
In particular, protocol declarations for clipboard/file transfer do not mean
the official agent implements those features. This review does not establish
real-hardware acceptance on any platform.

### 1. Entry points, settings and state

Stable adds a home status control and a separate Flow window with arrangement,
device channels, peer removal and pairing:
[crates/openlogi-desktop/src/app/widgets.rs:L46-L76](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-desktop/src/app/widgets.rs#L46-L76),
[crates/openlogi-desktop/src/windows/flow/pairing.rs:L94-L135](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-desktop/src/windows/flow/pairing.rs#L94-L135).
Readiness distinguishes Off, NoPeers, Ready and several Blocked reasons:
[crates/openlogi-desktop/src/state/flow.rs:L80-L205](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-desktop/src/state/flow.rs#L80-L205).
Custom's existing settings page includes clipboard behavior:
[crates/openlogi-desktop/src/windows/settings/flow.rs:L1-L100](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-desktop/src/windows/settings/flow.rs#L1-L100).

Gap/risk: stable readiness does not include pointer-probe availability, permission
failure or the last handoff result. A reachable peer is not sufficient to promise
outgoing handoff. UI migration must retain custom settings and validate both IPC
clients, not merely replace the page. GPUI tests exist but were not executed here.

### 2. Backend registration and IPC

Stable registers its shared controller through the orchestrator and dispatches
pairing commands from the server:
[crates/openlogi-agent-core/src/orchestrator.rs:L712-L738](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/orchestrator.rs#L712-L738),
[crates/openlogi-agent/src/server.rs:L600-L625](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent/src/server.rs#L600-L625).
Custom uses protocol 43; stable uses 45 and a different pairing API:
[crates/openlogi-ipc/src/ipc.rs:L155-L175](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-ipc/src/ipc.rs#L155-L175),
[crates/openlogi-ipc/src/ipc.rs:L169-L184](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-ipc/src/ipc.rs#L169-L184),
[crates/openlogi-ipc/src/ipc.rs:L1194-L1225](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-ipc/src/ipc.rs#L1194-L1225).

Gap/risk: wire enum positions, status structures, GUI requests and mock-agent
responses cannot be selected independently. An explicit combined protocol/version
plan and fixed-byte goldens are required. Passing each baseline's own goldens does
not establish cross-version compatibility.

### 3. Storage and migration

Custom serializes clipboard and optional port fields; stable's strict Flow config
has neither:
[crates/openlogi-core/src/config/flow.rs:L11-L43](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-core/src/config/flow.rs#L11-L43),
[crates/openlogi-core/src/config/flow.rs:L387-L409](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-core/src/config/flow.rs#L387-L409).
The real file loader propagates parse errors:
[crates/openlogi-core/src/config/file.rs:L136-L164](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-core/src/config/file.rs#L136-L164).
Stable introduces validated names, public keys, slots and layout constraints;
its schema-11 history assumes no previously shipped Flow config. That assumption
does not hold for this fork's schema-10 Flow:
[crates/openlogi-core/src/config.rs:L65-L130](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-core/src/config.rs#L65-L130).

Stable preserves identity in `flow-identity.pk8`, uses atomic publication and
Unix private permissions, and has conflict-aware pairing saves:
[crates/openlogi-agent-core/src/flow/identity.rs:L16-L100](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/identity.rs#L16-L100),
[crates/openlogi-agent-core/src/flow/pairing/store.rs:L55-L110](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/pairing/store.rs#L55-L110).
Migration must preserve keys, slots, manual addresses and disabled clipboard
intent, with backups and malformed-config tests. Do not regenerate identities or
silently drop old fields. Pairing addresses and session addresses now use different
ports, so copying address strings alone is insufficient.

### 4. Discovery, connections, authentication and permissions

Stable uses session UDP 42424 and pairing UDP 42425 with distinct mDNS services:
[crates/openlogi-flow/src/discovery.rs:L25-L47](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/discovery.rs#L25-L47).
Manual candidates work when mDNS is unavailable; endpoint binding tries IPv6
dual stack then IPv4:
[crates/openlogi-agent-core/src/flow/runtime.rs:L328-L404](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime.rs#L328-L404).
TLS pins peer keys, allows only an explicit temporary unknown pairing candidate,
uses TLS 1.3, and disables resumption/early data:
[crates/openlogi-flow/src/transport/tls.rs:L142-L224](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/transport/tls.rs#L142-L224),
[crates/openlogi-flow/src/transport.rs:L1098-L1133](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/transport.rs#L1098-L1133).
The new commit/reveal pairing binds identities and Hello messages:
[crates/openlogi-flow/src/pairing.rs:L328-L348](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/pairing.rs#L328-L348),
[crates/openlogi-flow/src/sas.rs:L132-L165](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/sas.rs#L132-L165).
Custom uses the earlier SAS derivation:
[crates/openlogi-flow/src/sas.rs:L123-L149](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-flow/src/sas.rs#L123-L149).

Gap/risk: old pairing is not compatible merely because both advertise protocol
v1. Keep the stronger stable protocol and define an explicit mixed-version/re-pair
policy. Native Wayland is deliberately unsupported for the pointer probe:
[crates/openlogi-hook/src/linux/probe.rs:L1-L34](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-hook/src/linux/probe.rs#L1-L34).
Stable's agent release plist has no Local Network/Bonjour entries, while custom
has a Flow declaration:
[crates/openlogi-desktop/bundle/agent-release/Info.plist:L34-L41](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-desktop/bundle/agent-release/Info.plist#L34-L41),
[crates/openlogi-desktop/bundle/agent-release/Info.plist:L40-L49](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-desktop/bundle/agent-release/Info.plist#L40-L49).
Preserve the custom declaration and review the new pairing service separately.
This is a packaging risk, not a demonstrated macOS permission failure. macOS TCC,
Windows mixed-DPI cursor behavior and native input permissions were not exercised.

### 5. Handoff, timing, concurrency and reconnect

Stable prepares all devices under an exclusive receiver lease, then accepts only
a matching HandoffAccept before issuing any ChangeHost write:
[crates/openlogi-agent-core/src/flow/runtime/sender.rs:L100-L159](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/sender.rs#L100-L159),
[crates/openlogi-agent-core/src/flow/runtime/sender.rs:L173-L250](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/sender.rs#L173-L250).
Budgets are lease 2s, per-device preparation 1s, request 2s, write 1s. The receiver
arms for 3s; sender scheduling bounds writes to its safe window and distinguishes
not-written from attempted writes:
[crates/openlogi-agent-core/src/flow/handoff.rs:L37-L45](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/handoff.rs#L37-L45),
[crates/openlogi-agent-core/src/flow/handoff.rs:L355-L419](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/handoff.rs#L355-L419).
The receiver tracks one pending arrival, deduplicates/replays bounded results,
warps on the first pointing-device arrival and settles all requested devices:
[crates/openlogi-agent-core/src/flow/handoff.rs:L134-L299](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/handoff.rs#L134-L299).
Mouse-first/keyboard-last ordering and configured-but-unlisted Bluetooth identities
are supported:
[crates/openlogi-agent-core/src/flow/devices.rs:L89-L179](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/devices.rs#L89-L179),
[crates/openlogi-agent-core/src/flow/devices.rs:L243-L249](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/devices.rs#L243-L249).

Custom also honors Accept-before-ChangeHost and releases departed keyboard
modifiers after 300ms; stable has no equivalent Flow cleanup call:
[crates/openlogi-agent-core/src/flow/handoff/sender.rs:L128-L165](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-agent-core/src/flow/handoff/sender.rs#L128-L165),
[crates/openlogi-agent-core/src/flow/handoff/sender.rs:L213-L243](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-agent-core/src/flow/handoff/sender.rs#L213-L243).
Stable session retry uses 250ms to 30s backoff with jitter and simultaneous-dial
resolution:
[crates/openlogi-flow/src/session.rs:L64-L71](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/session.rs#L64-L71),
[crates/openlogi-flow/src/session.rs:L452-L536](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/session.rs#L452-L536).

Gap/risk: timeout/cancel is **logical cleanup, not guaranteed physical rollback**
after a radio has moved. Two review concerns still need deterministic tests:
the outgoing crossing guard checks both directions, but the inbound arm path does
not consult `self.outgoing`; and the biased actor loop handles inventory before
deadline expiry while `observe` itself does not reject late arrivals:
[crates/openlogi-agent-core/src/flow/runtime/actor.rs:L149-L174](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/actor.rs#L149-L174),
[crates/openlogi-agent-core/src/flow/runtime/actor.rs:L238-L241](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/actor.rs#L238-L241),
[crates/openlogi-agent-core/src/flow/runtime/actor.rs:L350-L361](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/actor.rs#L350-L361),
[crates/openlogi-agent-core/src/flow/handoff.rs:L223-L258](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/handoff.rs#L223-L258).
These are code-review risks, not reproduced runtime defects.

Stable moves the edge detector from hook to agent-core. Its geometry reset keeps
latch/cooldown, but changing armed sides reconstructs the detector; reconnect
behavior needs an explicit regression test:
[crates/openlogi-agent-core/src/flow/edge/detector.rs:L201-L210](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/edge/detector.rs#L201-L210),
[crates/openlogi-agent-core/src/flow/pointer.rs:L274-L285](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/pointer.rs#L274-L285).
Its arrival inset is 2px, versus custom's 6px. Preserve approved behavior or review
the change explicitly. PR #16's additional eight tests are not in the custom base;
they are a separate review source, not silently merged coverage.

### 6. Error observability and recovery

Stable logs outgoing reports, receiver outcomes, queue overflow and pointer failures:
[crates/openlogi-agent-core/src/flow/runtime/actor.rs:L308-L316](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/actor.rs#L308-L316),
[crates/openlogi-agent-core/src/flow/runtime/actor.rs:L441-L502](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/actor.rs#L441-L502),
[crates/openlogi-agent-core/src/flow/pointer.rs:L335-L354](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/pointer.rs#L335-L354).
Controller restart and startup retry exist:
[crates/openlogi-agent-core/src/flow/controller.rs:L190-L240](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/controller.rs#L190-L240).

Gap/risk: most transaction failures are logs rather than persistent UI status.
The replay cache is in memory, with no persistent transaction journal; reconnect
is not an exactly-once guarantee across process restart. Preserve custom generation
invalidation and stale-message tests when moving to the stable actor lifecycle.

### 7. Security and clipboard boundaries

Stable restricts pre-trust operations, checks frame roles/capabilities and bounds
frame sizes/stream completion:
[crates/openlogi-flow/src/transport.rs:L681-L760](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/transport.rs#L681-L760),
[crates/openlogi-flow/src/frame.rs:L10-L15](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/src/frame.rs#L10-L15).
These are meaningful controls, but authenticated peers still have handoff authority;
per-peer device authorization deserves an explicit policy and tests.

Custom implements text/file clipboard transfer with caps, generation/hash checks,
loop prevention, and filename/path validation:
[crates/openlogi-agent-core/src/flow/clipboard.rs:L28-L43](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-agent-core/src/flow/clipboard.rs#L28-L43),
[crates/openlogi-agent-core/src/flow/clipboard.rs:L993-L1044](https://github.com/JayHome137/OpenLogi/blob/685448ed66e4e01ec82ff94f6d68bf6f683b7376/crates/openlogi-agent-core/src/flow/clipboard.rs#L993-L1044).
Stable advertises no clipboard capabilities and its runtime RPC handler supports
only HandoffRequest:
[crates/openlogi-agent-core/src/flow/runtime.rs:L374-L383](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime.rs#L374-L383),
[crates/openlogi-agent-core/src/flow/runtime/actor.rs:L319-L327](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/actor.rs#L319-L327).
Therefore copying stable's protocol types does not preserve custom clipboard
behavior. Custom's Linux clipboard backend is itself a stub; custom is not claimed
universally complete. Retain clipboard limits and consent semantics if the feature
is ported. No exploitation, hardware access or user-machine access was attempted.

### 8. Tests and what they actually prove

Stable tests execute real QUIC framing/pairing and scripted device preparation,
including reject/mismatched accept/no-write-after-deadline/shutdown cases:
[crates/openlogi-agent-core/src/flow/runtime/sender/tests.rs:L202-L410](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/sender/tests.rs#L202-L410),
[crates/openlogi-agent-core/src/flow/runtime/tests.rs:L96-L162](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/runtime/tests.rs#L96-L162),
[crates/openlogi-flow/tests/quic_protocol.rs:L1-L100](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-flow/tests/quic_protocol.rs#L1-L100).
Receiver tests cover replay, partial/timeout arrivals and cancel behavior:
[crates/openlogi-agent-core/src/flow/handoff/tests.rs:L73-L356](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-agent-core/src/flow/handoff/tests.rs#L73-L356).
GUI tests exercise clicks, layout and mock-agent pairing:
[crates/openlogi-desktop/src/windows/flow/tests.rs:L170-L380](https://github.com/AprilNEA/OpenLogi/blob/a5b507ec8802e0ecb7ef3de61ce7868609c9b533/crates/openlogi-desktop/src/windows/flow/tests.rs#L170-L380).

These prove software paths with loopback/synthetic inventories, not real HID++
switching, native pointer movement, TCC/Local Network grants, mixed-DPI desktops or
mixed custom/stable peers. The multicast test is ignored, not passed. Existing
baseline tests do not cover this fork's migration; the four supplemental probes
demonstrate that gap. The new documentation has its own whitespace, spelling,
reference and diff checks. Full workspace/hardware acceptance is not claimed.

## Required migration sequence before a source PR is ready

1. Agree the retained product surface: clipboard and files, custom port, Bluetooth
   identity/slots, modifier release, edge thresholds/inset, permission declarations,
   and all existing baseline tests. Decide whether to port PR #16's eight tests
   after separate review; leave PR #18's hardware scripts on their own branch.
2. Add an explicit schema-10 custom to combined-schema migration with backup,
   disabled-clipboard/port fixtures, strict validation errors and identity retention.
   Define mixed-version pairing behavior without weakening commit/reveal.
3. Reconcile Flow types, IPC version/goldens, controller/server, GUI and mock agent
   as one API change. Use the stable transaction/lease/deadline design, while
   porting custom clipboard and modifier semantics through a single lifecycle owner.
4. Port edge/arrival/generation/reconnect tests; add simultaneous bidirectional
   handoff, late arrival, peer removal, reconnect while latched, partial physical
   movement and mixed-version tests. Maintain actual Accept-before-ChangeHost proof.
5. Review every auto-merged file as well as the 67 conflicts. Reconcile manifests
   first, then regenerate Cargo.lock from the combined dependency graph; review
   unintended dependency movement and run locked checks. Never select a lockfile
   side as a substitute for resolving API differences.
6. Run the repository's full Rust-bearing post-conflict gate, cross-platform CI and
   a separately authorized hardware acceptance plan. Re-audit workflow behavior
   before pushing product-source changes, because stable changes workflows too.

## Workflows and pending review scope

The snapshot branch is an exact upstream commit. New branch push filters do not
match release, prerelease, CI or sync write paths. The documentation branch keeps
custom's workflows byte-for-byte unchanged. Its draft PR triggers CI and the Build
gate, but it has **no `needs: build` label**: installer/upload jobs must stay skipped.
No workflow was manually dispatched, disabled or edited, and no tag was pushed.
Existing scheduled upstream-sync remains independent and can write master when it
runs; this task did not trigger it.

- [#17](https://github.com/JayHome137/OpenLogi/pull/17) remains the separate
  master-to-custom sync PR and is not this proposal's carrier.
- [#16](https://github.com/JayHome137/OpenLogi/pull/16) remains closed and unmerged.
- [#18](https://github.com/JayHome137/OpenLogi/pull/18) remains the hardware-script PR.

Jay needs to confirm the future source merge scope and migration policy above.
This draft is for review of the blocked integration plan only. It authorizes no
final PR merge, protected-branch update, release/tag, deployment or hardware run.

## Verification recorded for the inspected commits

| Evidence command ID | Result | Scope/result count |
|---|---|---|
| `028-stable-flow-tests` | Exit 0 | 86 passed, 0 failed, 1 ignored |
| `036-stable-agent-flow-tests` | Exit 0 | 86 passed, 0 failed, 0 ignored |
| `040-stable-core-config` | Exit 0 | 194 passed, 0 failed, 0 ignored |
| `041-stable-ipc-wire` | Exit 0 | 34 passed, 0 failed, 0 ignored |
| `042-stable-device-switch` | Exit 0 | 56 passed, 0 failed, 0 ignored |
| `043-stable-build` | Exit 0 | See raw log |
| `044-stable-clippy` | Exit 101 | Source/toolchain lint failure; see raw diagnostics |
| `070-stable-flow-clippy-isolated` | Exit 0 | See raw log |
| `045-custom-flow-tests` | Exit 0 | 56 passed, 0 failed, 1 ignored |
| `046-custom-agent-flow` | Exit 0 | 60 passed, 0 failed, 0 ignored |
| `047-custom-edge-tests` | Exit 0 | 20 passed, 0 failed, 0 ignored |
| `048-custom-ipc-wire` | Exit 0 | 31 passed, 0 failed, 0 ignored |
| `049-custom-core-config` | Exit 0 | 186 passed, 0 failed, 0 ignored |
| `050-custom-device-switch` | Exit 0 | 51 passed, 0 failed, 0 ignored |
| `051-custom-build` | Exit 0 | See raw log |
| `052-custom-clippy` | Exit 101 | Source/toolchain lint failure; see raw diagnostics |
| `072-custom-flow-clippy-isolated` | Exit 101 | Source/toolchain lint failure; see raw diagnostics |
| `053-stable-desktop-check` | Exit 101 | See raw failure; no GUI execution claimed |
| `073-stable-desktop-check-deps-fixed` | Exit 0 | See raw log |
| `054-snapshot-flow-tests` | Exit 0 | 86 passed, 0 failed, 1 ignored |
| `055-snapshot-flow-clippy` | Exit 0 | See raw log |
| `033-format-custom` | Exit 0 | See raw log |
| `034-format-stable` | Exit 0 | See raw log |
| `035-format-snapshot` | Exit 0 | See raw log |
| `061-migration-probes-fixed` | Exit 0 | 4 probes: common config accepted; 3 incompatibilities confirmed |

Workspace tests, builds, checks and Clippy use `--locked`, Linux x86_64 and Rust
1.100.0; formatting uses `cargo fmt --all -- --check`. The comparison probes have
their own task-local lockfile and are supplemental, not a replacement workspace
gate. Combined Clippy checks on both baselines fail in unchanged `openlogi-core`
on six `map_unwrap_or` diagnostics under Rust 1.100.0. Stable Flow alone and master
Flow alone pass Clippy; custom Flow still depends on that failing core. The first
desktop check lacked a C++ compiler; native dependencies were then installed from
the CI list and the identical locked check passed on retry. Clippy failures and environment failures
are retained in full in the box
evidence; they are not converted to passes. This branch's final PR/check links and
final preservation checks are recorded in the box report and PR body.

## Appendix: file-by-file conflict disposition

All rows are **deferred**; the experimental merge was aborted. AA = both added;
UU = both modified. This table is a resolution plan, not a claim of resolved code.

| File | Conflict | Required semantic resolution (not performed) |
|---|---|---|
| `Cargo.lock` | UU | Resolve both manifests first; regenerate and review the combined graph with locked builds; retain clipboard dependencies if retained. |
| `crates/openlogi-agent-core/Cargo.toml` | UU | Reconcile official controller/transport dependencies with custom clipboard/platform dependencies; one runtime owner. |
| `crates/openlogi-agent-core/src/flow.rs` | AA | Reconcile module ownership; retain clipboard/config/handoff features while adopting typed official components. |
| `crates/openlogi-agent-core/src/flow/handoff.rs` | AA | Port custom arrival/replay/generation semantics into the official ledger/deadline model; distinguish attempted writes from cancellation. |
| `crates/openlogi-agent-core/src/flow/handoff/tests.rs` | AA | Retain both test intent sets; prove partial arrival, replay, timeout, keyboard-first observation and no fake physical rollback. |
| `crates/openlogi-agent-core/src/flow/runtime.rs` | AA | Port clipboard handlers, generation invalidation and modifier cleanup through official actor/sender lifecycle; no duplicate runtimes. |
| `crates/openlogi-agent-core/src/observable.rs` | UU | Choose one Flow status owner and reconcile snapshot publication with IPC goldens. |
| `crates/openlogi-agent-core/src/orchestrator.rs` | UU | Reconcile startup/reload/shutdown and shared hardware leases; controller registered once. |
| `crates/openlogi-agent-core/src/runtime/hook.rs` | UU | Preserve custom modifier/edge handoff intent while moving pointer polling to the official owner. |
| `crates/openlogi-agent/src/bin/mock_agent.rs` | UU | Implement the combined IPC pairing/status API and retain scriptable GUI scenarios. |
| `crates/openlogi-agent/src/server.rs` | UU | Reconcile pairing/config mutations and snapshot publication with one controller lifecycle. |
| `crates/openlogi-cli/src/cmd/fixture/record_profile/tests.rs` | UU | Reconcile added inventory/status fields; preserve fixture isolation and existing assertions. |
| `crates/openlogi-core/src/config.rs` | UU | Add an explicit fork schema-10 migration; official schema-11 history alone is insufficient. |
| `crates/openlogi-core/src/config/flow.rs` | AA | Preserve clipboard/port semantics and identity/slot data while introducing validated official types and migration fixtures. |
| `crates/openlogi-desktop/src/services/ipc.rs` | UU | Align all request variants and typed responses with the combined versioned service. |
| `crates/openlogi-desktop/src/services/ipc/request.rs` | UU | Port pairing operations and failure/state feedback together; no stale custom methods. |
| `crates/openlogi-desktop/src/state/settings.rs` | UU | Reconcile config ownership and custom Flow settings with standalone official Flow state. |
| `crates/openlogi-desktop/src/state/tests/device_list.rs` | UU | Update snapshot construction without dropping device-list behavior checks. |
| `crates/openlogi-desktop/src/state/tests/flow.rs` | AA | Retain custom config/feedback assertions and add official readiness/migration cases. |
| `crates/openlogi-desktop/src/state/tests/light_adoption.rs` | UU | Update shared snapshot schema while preserving light adoption race checks. |
| `crates/openlogi-desktop/src/windows/add_device/tests.rs` | UU | Update mock service contract and preserve existing enrollment tests. |
| `crates/openlogi-desktop/src/windows/settings.rs` | UU | Choose settings-to-Flow navigation and preserve custom controls; verify actual rendered interactions. |
| `crates/openlogi-device/src/lib.rs` | UU | Export one prepared-switch API and retain compatible custom callers until ported. |
| `crates/openlogi-device/src/session/host_switch.rs` | UU | Integrate official prepare/apply ownership and deadlines with Bluetooth route/identity semantics. |
| `crates/openlogi-device/src/session/host_switch/tests.rs` | UU | Retain custom switch tests and official prepared-switch/identity/timeout coverage. |
| `crates/openlogi-flow/Cargo.toml` | AA | Unify transport/protobuf versions and required features; review minimum versions before lock regeneration. |
| `crates/openlogi-flow/build.rs` | AA | Choose one protobuf generation pipeline for the reconciled schema; no duplicate generated types. |
| `crates/openlogi-flow/proto/flow.v1.proto` | AA | Retain official commit/reveal security and custom clipboard semantics; document negotiation/mixed-version policy. |
| `crates/openlogi-flow/src/discovery.rs` | AA | Reconcile session/pairing mDNS services and custom manual-port behavior with explicit compatibility tests. |
| `crates/openlogi-flow/src/frame.rs` | AA | Preserve role, frame-size and clipboard chunk limits for the combined message set. |
| `crates/openlogi-flow/src/lib.rs` | AA | Reconcile exports/generated modules; stable excludes the later master-only Clippy patch. |
| `crates/openlogi-flow/src/pairing.rs` | AA | Adopt commit/reveal and explicit trust lifetime; do not downgrade to accept empty custom PairStart. |
| `crates/openlogi-flow/src/sas.rs` | AA | Keep role/identity/Hello-bound commitment verification; define re-pair behavior for older peers. |
| `crates/openlogi-flow/src/session.rs` | AA | Retain bounded retry, heartbeat, simultaneous-dial policy and custom generation/reconnect tests. |
| `crates/openlogi-flow/src/transport.rs` | AA | Reconcile clipboard capabilities with strict pre-trust/role/stream limits and official pairing flow. |
| `crates/openlogi-flow/src/transport/tls.rs` | AA | Preserve mutual pinning and one-candidate lease cleanup; test key removal and stale leases. |
| `crates/openlogi-flow/tests/quic_protocol.rs` | AA | Keep both transport security suites; add mixed-version and clipboard capability cases. |
| `crates/openlogi-flow/tests/session_manager.rs` | AA | Keep retry/disconnect/heartbeat and simultaneous-dial tests under the reconciled transport. |
| `crates/openlogi-ipc/src/ipc.rs` | UU | Define combined version/API/status contract atomically; protocol 43 and 45 are not interchangeable. |
| `crates/openlogi-ipc/tests/wire_format.rs` | UU | Review exact enum positions and fixed-byte goldens after choosing the combined protocol version. |
| `crates/openlogi-ui/locales/be.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/cs.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/da.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/de.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/el.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/en.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/es.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/fi.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/fr.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/it.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/ja.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/ko.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/nb.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/nl.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/pl.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/pt-BR.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/pt-PT.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/ru.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/sv.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/tr.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/uk.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/zh-CN.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/zh-HK.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `crates/openlogi-ui/locales/zh-TW.toml` | UU | Retain custom clipboard/settings keys and official Flow window/pairing strings; enforce parity with the reviewed English key set. |
| `docs/FLOW-DESIGN.md` | AA | Rewrite only after the implemented combined lifecycle is chosen; separate delivered and planned behavior. |
| `docs/FLOW-PROTOCOL.md` | AA | Document exact commitment exchange, capabilities, cancellation and mixed-version rules from implementation. |
| `docs/config.example.toml` | UU | Update to the explicit combined migration schema, retaining intentional clipboard and port settings. |

## Appendix: master changes excluded from stable

All 144 commits below are excluded from the stable candidate and from this
documentation-only branch. Flow-specific changes include explicit pairing stages
(`64cdf4d7`), save ownership/config revision (`e70647fc`, `45408032`), GUI presence
and controls (`23ac38b9`, `1daafe77`, `72e979c3`), and generated-protocol Clippy
fixes (`d5750ad4`). Menu-bar Flow (`882f0563`), Flow deep links (`455cb2b0`) and
Easy-Switch actions (`9ca7ef0c`) are relevant indirect changes. The unmerged
`feat/flow-pointer-unavailable-notice` remote branch is not part of this master.

| Commit (full SHA) | Commit time (CST) | Subject |
|---|---|---|
| [9ca7ef0cbd1f4577ffdc338f8288f8c3a410f013](https://github.com/AprilNEA/OpenLogi/commit/9ca7ef0cbd1f4577ffdc338f8288f8c3a410f013) | 2026-11-12 20:19:26 | feat(agent): bind easy-switch channels to buttons and ring slots (#2068) |
| [f3b5797473c936c3be6aa9431e9e1238ceec46c4](https://github.com/AprilNEA/OpenLogi/commit/f3b5797473c936c3be6aa9431e9e1238ceec46c4) | 2026-11-12 01:04:08 | ci: run the release workflows on namespace runners (#2510) |
| [6884dea8619c85ef72ec7daeec381c7c450bab2d](https://github.com/AprilNEA/OpenLogi/commit/6884dea8619c85ef72ec7daeec381c7c450bab2d) | 2026-11-12 00:19:57 | test(agent-core): bound the replaced-device scenarios with a timeout |
| [2c6b23772f517fd4283a8f2070bd6362e09cc55f](https://github.com/AprilNEA/OpenLogi/commit/2c6b23772f517fd4283a8f2070bd6362e09cc55f) | 2026-11-12 00:19:57 | fix(agent-core): count a Disable Keys write's device check against its deadline |
| [88fd8d36f06e79868b448751ddedd88d2906dfc6](https://github.com/AprilNEA/OpenLogi/commit/88fd8d36f06e79868b448751ddedd88d2906dfc6) | 2026-11-12 00:19:57 | docs(tray): describe the macOS menu-bar menu and how its changes are saved |
| [dad18742e8d0f4845c623b316dc5724b82cbbce9](https://github.com/AprilNEA/OpenLogi/commit/dad18742e8d0f4845c623b316dc5724b82cbbce9) | 2026-11-12 00:19:57 | refactor(tray): track whether a device read is under way as one phase |
| [82de2cef9529d8ed41f31adcaa958ad6508754db](https://github.com/AprilNEA/OpenLogi/commit/82de2cef9529d8ed41f31adcaa958ad6508754db) | 2026-11-12 00:19:57 | fix(tray): write a menu change only to the device the menu listed |
| [1e0307a75e342e24483be2483c487cef91f35ccd](https://github.com/AprilNEA/OpenLogi/commit/1e0307a75e342e24483be2483c487cef91f35ccd) | 2026-11-12 00:19:57 | refactor(device): read a device's 0x0003 unit ID in one place |
| [a0ce8d64ca3592475ae9b82a77b532c537777efe](https://github.com/AprilNEA/OpenLogi/commit/a0ce8d64ca3592475ae9b82a77b532c537777efe) | 2026-11-12 00:19:57 | fix(agent-core): ask a keyboard to disable only the keys this version knows |
| [1b0ecce3178e806373b909369e4ccc07b9a9365d](https://github.com/AprilNEA/OpenLogi/commit/1b0ecce3178e806373b909369e4ccc07b9a9365d) | 2026-11-12 00:19:57 | fix(agent-core): report a superseded Fn-lock write instead of reading the keyboard |
| [e9ef83380e0b3e1d269b551bd31b0f47bd5e0266](https://github.com/AprilNEA/OpenLogi/commit/e9ef83380e0b3e1d269b551bd31b0f47bd5e0266) | 2026-11-12 00:19:57 | fix(tray): remember readings by device, not by receiver slot alone |
| [119b26ddaa2685d0599053e4c1b747d10aab63e7](https://github.com/AprilNEA/OpenLogi/commit/119b26ddaa2685d0599053e4c1b747d10aab63e7) | 2026-11-12 00:19:57 | fix(core): record a device's route when saving its settings under its identity |
| [124501549b142e5d7e4c45060b2f3bdafa63c7ee](https://github.com/AprilNEA/OpenLogi/commit/124501549b142e5d7e4c45060b2f3bdafa63c7ee) | 2026-11-12 00:19:57 | feat(i18n): translate the menu-bar menu's newest strings in every locale |
| [d2e11e4db168a43851ec81551d4847254f5842dc](https://github.com/AprilNEA/OpenLogi/commit/d2e11e4db168a43851ec81551d4847254f5842dc) | 2026-11-12 00:19:57 | fix(agent-core): save no Fn lock a newer write superseded |
| [b6aa2e6040ac2b2d7dd9777359d2f36baaf929e8](https://github.com/AprilNEA/OpenLogi/commit/b6aa2e6040ac2b2d7dd9777359d2f36baaf929e8) | 2026-11-12 00:19:57 | fix(gui): look again at a config revision whose file could not be read |
| [280a3fca96310e100e3b582783c6f85107aa9611](https://github.com/AprilNEA/OpenLogi/commit/280a3fca96310e100e3b582783c6f85107aa9611) | 2026-11-12 00:19:57 | fix(tray): keep a menu change over a read that began before it |
| [f9b31aafa38de9853c013b3c53e257396ec5b403](https://github.com/AprilNEA/OpenLogi/commit/f9b31aafa38de9853c013b3c53e257396ec5b403) | 2026-11-12 00:19:57 | fix(agent-core): report a DPI write a newer one superseded |
| [42d3fe2183e6261c5d764e0d087fcd1c354474af](https://github.com/AprilNEA/OpenLogi/commit/42d3fe2183e6261c5d764e0d087fcd1c354474af) | 2026-11-12 00:19:57 | feat(tray): change device settings and list webcams from the menu-bar item |
| [c4e63c4c9a069ad0bdd1cc66f81ec9a55a432a46](https://github.com/AprilNEA/OpenLogi/commit/c4e63c4c9a069ad0bdd1cc66f81ec9a55a432a46) | 2026-11-12 00:19:57 | feat(camera): report which cameras another process captures from |
| [f9b9e0c082f98acbe1b493a340b303053b8b5f90](https://github.com/AprilNEA/OpenLogi/commit/f9b9e0c082f98acbe1b493a340b303053b8b5f90) | 2026-11-12 00:19:57 | feat(gui): open a camera's preview or its settings from an openlogi:// link |
| [2879efd3bef39adcbab335695766091357a76f8a](https://github.com/AprilNEA/OpenLogi/commit/2879efd3bef39adcbab335695766091357a76f8a) | 2026-11-12 00:19:57 | feat(agent-core): change and save Fn lock, disabled keys and lights from inside the agent |
| [c44809f726b0911e0199af518cc8dc1249516342](https://github.com/AprilNEA/OpenLogi/commit/c44809f726b0911e0199af518cc8dc1249516342) | 2026-11-12 00:19:57 | refactor(core): own the disabled-key set and a light command's effect on saved settings |
| [d95335d87fd1fb0d09bb8e66b34e3590afb57054](https://github.com/AprilNEA/OpenLogi/commit/d95335d87fd1fb0d09bb8e66b34e3590afb57054) | 2026-11-12 00:19:57 | refactor(agent-core): read Fn lock, backlight, sidetone, DPI and SmartShift through SharedHandles |
| [882f05639b09631c819a0fa61ef614df7b63fcad](https://github.com/AprilNEA/OpenLogi/commit/882f05639b09631c819a0fa61ef614df7b63fcad) | 2026-11-12 00:19:57 | feat(agent): show issues, devices, the current app and Flow in the menu-bar menu |
| [119c90507709cc878c3bf9448ed89275a9e29bb1](https://github.com/AprilNEA/OpenLogi/commit/119c90507709cc878c3bf9448ed89275a9e29bb1) | 2026-11-12 00:19:57 | refactor(ipc): ask AgentStatus whether Secure Event Input pauses key bindings |
| [aa8ce1137418348af4a1d75f9eabb9fa8631cc47](https://github.com/AprilNEA/OpenLogi/commit/aa8ce1137418348af4a1d75f9eabb9fa8631cc47) | 2026-11-12 00:19:57 | refactor(core): decide how a device reaches the host in ConnectionKind::of |
| [00585b993820626c39b68497dbb1df16f7525a02](https://github.com/AprilNEA/OpenLogi/commit/00585b993820626c39b68497dbb1df16f7525a02) | 2026-11-12 00:19:57 | refactor(core): rank a low battery as low or critical in one place |
| [45408032a3104708ed7abc113adf2ab6bd9cd062](https://github.com/AprilNEA/OpenLogi/commit/45408032a3104708ed7abc113adf2ab6bd9cd062) | 2026-11-12 00:19:57 | feat(ipc): tell the settings app which config revision the agent loaded |
| [454615bb1eb5e78db5d6cea8f039ed6e379eb3ac](https://github.com/AprilNEA/OpenLogi/commit/454615bb1eb5e78db5d6cea8f039ed6e379eb3ac) | 2026-11-12 00:19:57 | feat(agent): change and save device settings from inside the agent |
| [e70647fcb984bea27de6da4edf42312122469b2e](https://github.com/AprilNEA/OpenLogi/commit/e70647fcb984bea27de6da4edf42312122469b2e) | 2026-11-12 00:19:57 | refactor(core): save config edits outside the settings app through one owner |
| [4491bcb493baaed201ed4b4ae27204819ab40eb4](https://github.com/AprilNEA/OpenLogi/commit/4491bcb493baaed201ed4b4ae27204819ab40eb4) | 2026-11-12 00:19:57 | refactor(agent): rebuild the menu-bar menu each time it opens |
| [455cb2b0dc8d4dbeb6f60b4e4f0b8a8278367843](https://github.com/AprilNEA/OpenLogi/commit/455cb2b0dc8d4dbeb6f60b4e4f0b8a8278367843) | 2026-11-12 00:19:57 | feat(gui): open a device, Add Device, an app profile or Flow from openlogi:// links |
| [0fdcab5551eb11cf9506a17989cfcfa5cb8a657b](https://github.com/AprilNEA/OpenLogi/commit/0fdcab5551eb11cf9506a17989cfcfa5cb8a657b) | 2026-11-12 00:19:57 | refactor(gui): name the detail tabs that edit app profiles |
| [98d60ca7b34b7e9b3fe7975ae11dff223b634c8e](https://github.com/AprilNEA/OpenLogi/commit/98d60ca7b34b7e9b3fe7975ae11dff223b634c8e) | 2026-11-10 17:56:51 | ci: build the installers on namespace runners (#2504) |
| [1bd2954ad277c3db65a3f45f0e612c5d3ea25abf](https://github.com/AprilNEA/OpenLogi/commit/1bd2954ad277c3db65a3f45f0e612c5d3ea25abf) | 2026-11-10 13:00:33 | test(gui): keep the Buttons inspector inside a window with a long profile strip (#2507) |
| [16d8cbaffb6368ede4aa7ed45250b98a188f9e34](https://github.com/AprilNEA/OpenLogi/commit/16d8cbaffb6368ede4aa7ed45250b98a188f9e34) | 2026-11-09 23:47:38 | test(hidpp): wait for the message listener before asserting on it (#2503) |
| [5a4c174cb1a3c20be1eddce18479525296d83e9b](https://github.com/AprilNEA/OpenLogi/commit/5a4c174cb1a3c20be1eddce18479525296d83e9b) | 2026-11-09 21:24:00 | docs(macos): point the permission guidance at the drag guide (#2493) |
| [214c9cf173d8572d0fb2b1fffccb6e14adffe54b](https://github.com/AprilNEA/OpenLogi/commit/214c9cf173d8572d0fb2b1fffccb6e14adffe54b) | 2026-11-09 21:16:43 | feat(core): accept keypad keys in custom shortcuts (#1963) |
| [74142fbafa52e789a268f541d0bac342ef0d7a0c](https://github.com/AprilNEA/OpenLogi/commit/74142fbafa52e789a268f541d0bac342ef0d7a0c) | 2026-11-09 21:16:06 | feat(binding): add HoldModifier for bare-modifier holds (#1363) |
| [5c970003b3fd9f2e20d5e802da43858a8dc44079](https://github.com/AprilNEA/OpenLogi/commit/5c970003b3fd9f2e20d5e802da43858a8dc44079) | 2026-11-09 17:59:13 | fix(gui): forget a dropped device's disable-keys snapshot with its card (#2491) |
| [8be1836ddfd3a89fe5f8eb238a5560ccd20d370d](https://github.com/AprilNEA/OpenLogi/commit/8be1836ddfd3a89fe5f8eb238a5560ccd20d370d) | 2026-11-09 17:31:04 | feat(gui): guide the agent's macOS grants with a drag panel (#2492) |
| [59ac734aee31912c1299c595b9f0f8290c1ce38c](https://github.com/AprilNEA/OpenLogi/commit/59ac734aee31912c1299c595b9f0f8290c1ce38c) | 2026-11-09 06:47:44 | fix(linux): press kwin's ctrl+meta chord when the desktop-switch call fails (#2488) |
| [36db8cbab6e94760ebe818cf99f3f927fc0938c8](https://github.com/AprilNEA/OpenLogi/commit/36db8cbab6e94760ebe818cf99f3f927fc0938c8) | 2026-11-09 06:28:12 | fix(linux): switch workspaces with cosmic's super+ctrl chord (#2486) |
| [a6a7803e2b0c1f6bb1820b90da1505dd0a3588ed](https://github.com/AprilNEA/OpenLogi/commit/a6a7803e2b0c1f6bb1820b90da1505dd0a3588ed) | 2026-11-09 03:57:21 | fix(hid): recognise the g613's lightspeed receiver 046d:c53d (#2485) |
| [23ac38b9402c55b3d8e030319f2d660cccfe4750](https://github.com/AprilNEA/OpenLogi/commit/23ac38b9402c55b3d8e030319f2d660cccfe4750) | 2026-11-09 02:19:01 | refactor(gui): type device liveness and the miss grace as one presence (#2482) |
| [db507f8ba36d658f44fb649e9e3d90b635cfcd16](https://github.com/AprilNEA/OpenLogi/commit/db507f8ba36d658f44fb649e9e3d90b635cfcd16) | 2026-11-09 02:07:43 | refactor(hook): type the linux frontmost observer lifecycle as explicit state (#2481) |
| [9299812f8cf3cdb01daa0e7199adc85dfe564da6](https://github.com/AprilNEA/OpenLogi/commit/9299812f8cf3cdb01daa0e7199adc85dfe564da6) | 2026-11-09 01:50:07 | refactor(device): type the lock-key read state as one enum (#2480) |
| [18819e6b3130a0fdcde09751d9bae10f83ad2d3e](https://github.com/AprilNEA/OpenLogi/commit/18819e6b3130a0fdcde09751d9bae10f83ad2d3e) | 2026-11-09 01:32:15 | feat(device): divert the Gestures2 thumb wheel without 0x2150 (#2038) |
| [8e4f65ddbf27e54c0499b1ccc4001eff4c7456b0](https://github.com/AprilNEA/OpenLogi/commit/8e4f65ddbf27e54c0499b1ccc4001eff4c7456b0) | 2026-11-09 01:08:30 | refactor(gui): type the disable keys write lifecycle (#2479) |
| [64cdf4d75310a8d3835d7830088719bc7fa4dfc1](https://github.com/AprilNEA/OpenLogi/commit/64cdf4d75310a8d3835d7830088719bc7fa4dfc1) | 2026-11-09 01:08:11 | refactor(flow): type the pairing attempt as an explicit stage (#2478) |
| [c0fbc76f1a5241def1c3a470d5554e485e5db290](https://github.com/AprilNEA/OpenLogi/commit/c0fbc76f1a5241def1c3a470d5554e485e5db290) | 2026-11-09 01:07:55 | refactor(gui): type the mouse binding editor's mode as one enum (#2477) |
| [df912a8277c3c794862947884ce86382d635e874](https://github.com/AprilNEA/OpenLogi/commit/df912a8277c3c794862947884ce86382d635e874) | 2026-11-09 01:07:38 | refactor(gui): type the standalone light write lifecycle as one enum (#2474) |
| [3001a987c7bcb0c2ff5303dbf1f18ec5fc401b01](https://github.com/AprilNEA/OpenLogi/commit/3001a987c7bcb0c2ff5303dbf1f18ec5fc401b01) | 2026-11-09 01:07:22 | refactor(hidpp): give each correlation key one lifecycle owner (#2473) |
| [edf982c8dcbf97cad61dc92b2e2390900c8b8d54](https://github.com/AprilNEA/OpenLogi/commit/edf982c8dcbf97cad61dc92b2e2390900c8b8d54) | 2026-11-09 01:07:04 | refactor(agent): track each hook button's press as one explicit phase (#2471) |
| [ad4ae7564da91ba397ab49f1403a1a032cc3ad8f](https://github.com/AprilNEA/OpenLogi/commit/ad4ae7564da91ba397ab49f1403a1a032cc3ad8f) | 2026-11-09 01:06:47 | refactor(agent): re-type the forced re-apply latch as one enum (#2470) |
| [dcef7a2b7fa30fca47138ccd8c7d7541797015d8](https://github.com/AprilNEA/OpenLogi/commit/dcef7a2b7fa30fca47138ccd8c7d7541797015d8) | 2026-11-09 01:06:28 | refactor(device): type the G-key row's ownership as one state (#2469) |
| [ca57e0c4de1a7f7f54a7a9ba1c0887b854a8de89](https://github.com/AprilNEA/OpenLogi/commit/ca57e0c4de1a7f7f54a7a9ba1c0887b854a8de89) | 2026-11-09 01:06:10 | refactor(hid): type the native recorder lifecycle as one state enum (#2468) |
| [5fdbd75a23df6127c9129a43290f0146fd2678cb](https://github.com/AprilNEA/OpenLogi/commit/5fdbd75a23df6127c9129a43290f0146fd2678cb) | 2026-11-09 00:56:13 | refactor(hook): give the macos tap lifecycle one owner (#2476) |
| [cdf69fd4781a63f34685fb4a5ad10b030fc47e20](https://github.com/AprilNEA/OpenLogi/commit/cdf69fd4781a63f34685fb4a5ad10b030fc47e20) | 2026-11-09 00:56:08 | refactor(agent): derive the published pairing phase from the session owner (#2475) |
| [b3354af6a08382235ababe9f5a018bc585a7aa43](https://github.com/AprilNEA/OpenLogi/commit/b3354af6a08382235ababe9f5a018bc585a7aa43) | 2026-11-09 00:56:02 | refactor(device): fold channel eviction and replacement into one node state (#2472) |
| [aec0dee95e26d13427f61c719cc001c9ba9e8e9d](https://github.com/AprilNEA/OpenLogi/commit/aec0dee95e26d13427f61c719cc001c9ba9e8e9d) | 2026-11-08 21:40:12 | ci: build the aarch64 nix package on apple silicon (#2458) |
| [dacda0cd6673883ab09a82ad0f639f672cce7cf0](https://github.com/AprilNEA/OpenLogi/commit/dacda0cd6673883ab09a82ad0f639f672cce7cf0) | 2026-11-08 21:36:53 | fix(gui): decode a keyboard render by its bytes for the computed glow (#2467) |
| [71b802fbbd0904d8a3068a651b42b1c9b9ee2e6a](https://github.com/AprilNEA/OpenLogi/commit/71b802fbbd0904d8a3068a651b42b1c9b9ee2e6a) | 2026-11-08 21:28:45 | ci: keep the linux compile jobs' cargo state on namespace cache volumes (#2428) |
| [110aadf420a7bcd401734943c8c42eb89279e091](https://github.com/AprilNEA/OpenLogi/commit/110aadf420a7bcd401734943c8c42eb89279e091) | 2026-11-08 21:28:00 | fix(linux): run the nix package tests in the dev profile (#2462) |
| [b50c24e994b22fd0b9ad8ae1972c9dca26f0dc43](https://github.com/AprilNEA/OpenLogi/commit/b50c24e994b22fd0b9ad8ae1972c9dca26f0dc43) | 2026-11-08 21:14:27 | fix(gui): read webp render sizes for the side and main views (#2463) |
| [8bf29cb704f74b0a3b0b7dc7ab74d1570f20db19](https://github.com/AprilNEA/OpenLogi/commit/8bf29cb704f74b0a3b0b7dc7ab74d1570f20db19) | 2026-11-08 01:23:41 | test(overlay): draw a low-battery card with a name wider than itself |
| [769aa9052c1a36ab05ddc3f1476b8075b1290534](https://github.com/AprilNEA/OpenLogi/commit/769aa9052c1a36ab05ddc3f1476b8075b1290534) | 2026-11-08 01:23:41 | fix(overlay): edge the notice card with a hairline |
| [ea932fa74fc31c5a05494c23d19c973117e0a260](https://github.com/AprilNEA/OpenLogi/commit/ea932fa74fc31c5a05494c23d19c973117e0a260) | 2026-11-08 01:23:41 | fix(overlay): keep the charge visible on a low-battery notice |
| [49009dc8dc0d40130593ae961581cbb093e7e25d](https://github.com/AprilNEA/OpenLogi/commit/49009dc8dc0d40130593ae961581cbb093e7e25d) | 2026-11-08 01:23:41 | refactor(ui): own the overlay's grey and accent in openlogi-ui |
| [a03a5551aa4de04d1aa79f8916e576e182febd25](https://github.com/AprilNEA/OpenLogi/commit/a03a5551aa4de04d1aa79f8916e576e182febd25) | 2026-11-08 01:23:41 | fix(gui): ring the selected lighting swatch outside its colour |
| [ae7d0e31cfb7a21812604d0b0790ce9820e6becf](https://github.com/AprilNEA/OpenLogi/commit/ae7d0e31cfb7a21812604d0b0790ce9820e6becf) | 2026-11-08 01:23:41 | fix(gui): mark the active device in the home gallery and list |
| [4d7de7de32f86abce2b8ae57c7c4c7aca5bf2ca6](https://github.com/AprilNEA/OpenLogi/commit/4d7de7de32f86abce2b8ae57c7c4c7aca5bf2ca6) | 2026-11-08 01:23:41 | fix(gui): truncate detail rail labels with a tooltip |
| [7f890d9da34652fea7b691d023bfdae7218aca66](https://github.com/AprilNEA/OpenLogi/commit/7f890d9da34652fea7b691d023bfdae7218aca66) | 2026-11-08 01:23:41 | fix(gui): drop the on/off word from toggles |
| [72fd5007b0dfbc8bb34c7a8ad4d57b7908b26e34](https://github.com/AprilNEA/OpenLogi/commit/72fd5007b0dfbc8bb34c7a8ad4d57b7908b26e34) | 2026-11-08 01:23:41 | fix(gui): mark the chosen segment in every button group |
| [1daafe77047398ca595c94f1ea61f5f43445662d](https://github.com/AprilNEA/OpenLogi/commit/1daafe77047398ca595c94f1ea61f5f43445662d) | 2026-11-08 01:23:41 | feat(gui): give hand-rolled controls press feedback |
| [bfda9253c5bb934c10852ec989ff88d2f54c5bd0](https://github.com/AprilNEA/OpenLogi/commit/bfda9253c5bb934c10852ec989ff88d2f54c5bd0) | 2026-11-07 23:57:30 | fix(device): look up litra route locks under a std mutex (#2447) |
| [f4b2f864a6a262de1d4455e1da584d217910a9f3](https://github.com/AprilNEA/OpenLogi/commit/f4b2f864a6a262de1d4455e1da584d217910a9f3) | 2026-11-07 20:20:46 | fix(device): give a slow unifying device's first-sight walk time to finish (#2445) |
| [cff9a04a9c3c88e2e59ef0e45a2bcf8d2d82db6c](https://github.com/AprilNEA/OpenLogi/commit/cff9a04a9c3c88e2e59ef0e45a2bcf8d2d82db6c) | 2026-11-07 16:45:35 | docs: restructure README acknowledgments and add Namespace CI badge (#2441) |
| [5c5d15d86044013b578b1c3ecb9e1874d07855f2](https://github.com/AprilNEA/OpenLogi/commit/5c5d15d86044013b578b1c3ecb9e1874d07855f2) | 2026-11-07 11:48:50 | fix(inject): post the phased thumb-wheel gesture as pixels on macos (#2440) |
| [119fc6fb2c6dcb220eaed337ada39c0986ce444f](https://github.com/AprilNEA/OpenLogi/commit/119fc6fb2c6dcb220eaed337ada39c0986ce444f) | 2026-11-07 08:20:39 | fix(agent): scroll a push right after a momentum catch instead of swallowing it (#2437) |
| [a0549188c05e648d220f85fe66a60215f9da886d](https://github.com/AprilNEA/OpenLogi/commit/a0549188c05e648d220f85fe66a60215f9da886d) | 2026-11-07 07:32:58 | fix(device): settle a direct hid++ 1.0 answer instead of retiring its channel (#2433) |
| [7c5b21c66411574723a2f76c4ae0009e28d2f87d](https://github.com/AprilNEA/OpenLogi/commit/7c5b21c66411574723a2f76c4ae0009e28d2f87d) | 2026-11-07 07:07:36 | fix(hid): recognise the mx revolution's nano receiver 046d:c51a (#2431) |
| [a4a71ba69e9183e9fc315052a6f08cb8eb268e8a](https://github.com/AprilNEA/OpenLogi/commit/a4a71ba69e9183e9fc315052a6f08cb8eb268e8a) | 2026-11-06 23:41:37 | fix(agent): announce dpi button writes so the gui re-reads the dpi (#2427) |
| [b689e88a8c0784ad549e0fd00c29ec7eaf1543e1](https://github.com/AprilNEA/OpenLogi/commit/b689e88a8c0784ad549e0fd00c29ec7eaf1543e1) | 2026-11-06 23:40:31 | feat(cli): add diag hidpp to call a hid++ 2.0 feature with raw parameters (#2426) |
| [cf64cd04ec181b80ed1a4869fe8a5a4384cef771](https://github.com/AprilNEA/OpenLogi/commit/cf64cd04ec181b80ed1a4869fe8a5a4384cef771) | 2026-11-06 23:30:03 | ci: move pull request workflows to namespace runners (#2419) |
| [d5750ad4e502510fefadc78e23edd93fcf06d97d](https://github.com/AprilNEA/OpenLogi/commit/d5750ad4e502510fefadc78e23edd93fcf06d97d) | 2026-11-06 23:29:28 | fix(flow): name the clippy lints the generated proto code needs (#2424) |
| [c7ed07c021de2b36a6a89f1b2bf43fdab3182983](https://github.com/AprilNEA/OpenLogi/commit/c7ed07c021de2b36a6a89f1b2bf43fdab3182983) | 2026-11-06 20:52:17 | fix(hidpp): decode chunked device names as a whole (#2184) |
| [548b843b0607bcb7f9050764ce94b514590f3c02](https://github.com/AprilNEA/OpenLogi/commit/548b843b0607bcb7f9050764ce94b514590f3c02) | 2026-11-06 17:51:47 | fix(inject): leave modifiers already down out of windows held chords (#2418) |
| [1b2f279434832a5d214787a462c8990fd0515c80](https://github.com/AprilNEA/OpenLogi/commit/1b2f279434832a5d214787a462c8990fd0515c80) | 2026-11-06 17:11:14 | fix(inject): leave modifiers already down out of tapped chords (#2416) |
| [2e4c6b76f101267665c2b2b1e1654442eedadb59](https://github.com/AprilNEA/OpenLogi/commit/2e4c6b76f101267665c2b2b1e1654442eedadb59) | 2026-11-06 16:38:31 | test(device): widen the receiver budget in the bolt codename tests (#2415) |
| [10c42c8cdecdaf5ca9fbe601416f37009090776b](https://github.com/AprilNEA/OpenLogi/commit/10c42c8cdecdaf5ca9fbe601416f37009090776b) | 2026-11-06 06:27:51 | fix(gui): select the g512 render and key metadata in the g513 depot (#2405) |
| [83fa1d7e699e588b8de5a78d794a69d0b9a9e651](https://github.com/AprilNEA/OpenLogi/commit/83fa1d7e699e588b8de5a78d794a69d0b9a9e651) | 2026-11-06 06:17:29 | fix(cli): say the input monitoring note only on macos (#2406) |
| [60c1abefa12dbbc7153a3c060a0f8dda02059e8d](https://github.com/AprilNEA/OpenLogi/commit/60c1abefa12dbbc7153a3c060a0f8dda02059e8d) | 2026-11-06 06:02:08 | feat(gui): edit linked Easy-Switch devices from the Device tab (#2043) |
| [10c10c1f8e280c1fe0facc12962b8e73f3bcc213](https://github.com/AprilNEA/OpenLogi/commit/10c10c1f8e280c1fe0facc12962b8e73f3bcc213) | 2026-11-06 05:56:49 | test(cli): add g512 wired usb fixture (#2404) |
| [ff0a6b25e4f7cfb0dedcc938c7c14c58d75d5486](https://github.com/AprilNEA/OpenLogi/commit/ff0a6b25e4f7cfb0dedcc938c7c14c58d75d5486) | 2026-11-06 05:13:02 | fix(gui): name a g512 that shares the g513 asset depot (#2403) |
| [32fdafe362e87040ae72e82d2171c4633d5348b5](https://github.com/AprilNEA/OpenLogi/commit/32fdafe362e87040ae72e82d2171c4633d5348b5) | 2026-11-06 02:00:28 | fix(device): treat a dpi read rejected with invalid argument as unsupported (#2391) |
| [7f1f531d8ec0678ef9bc4aa387b5abbdf9978014](https://github.com/AprilNEA/OpenLogi/commit/7f1f531d8ec0678ef9bc4aa387b5abbdf9978014) | 2026-11-06 01:31:19 | fix(gui): keep scrollbars drawn when the platform asks for them (#2389) |
| [8d72def979e395497607a27e8bf65159eac0857b](https://github.com/AprilNEA/OpenLogi/commit/8d72def979e395497607a27e8bf65159eac0857b) | 2026-11-05 23:45:57 | fix(agent): keep another mouse's click native once the selected one diverts it (#2387) |
| [aff3896eb28848f65c337a6e203587bb807631ec](https://github.com/AprilNEA/OpenLogi/commit/aff3896eb28848f65c337a6e203587bb807631ec) | 2026-11-05 22:48:28 | fix(inject): post wheel events as zooms while the macOS zoom modifier is held (#2385) |
| [3a2b08c0f05e5d03d011821f01f0bdfbfd049cc7](https://github.com/AprilNEA/OpenLogi/commit/3a2b08c0f05e5d03d011821f01f0bdfbfd049cc7) | 2026-11-05 22:43:38 | feat(cli): add diag zones to map a keyboard's per-key zones (#2384) |
| [f748ffeb982f8dd963efbaa40dda2c93d430d822](https://github.com/AprilNEA/OpenLogi/commit/f748ffeb982f8dd963efbaa40dda2c93d430d822) | 2026-11-05 21:06:04 | fix(device): resend 0x8081 requests a keyboard answers busy (#2382) |
| [9e5f3fd31c744c5a8739eb60d3bf4cbc8ac89a59](https://github.com/AprilNEA/OpenLogi/commit/9e5f3fd31c744c5a8739eb60d3bf4cbc8ac89a59) | 2026-11-05 20:03:07 | fix(hid): keep the linux kernel's hid++ software id out of the lease pool (#2380) |
| [cf0e86bb24ead1449daf2d8a04bdccffa14e13c9](https://github.com/AprilNEA/OpenLogi/commit/cf0e86bb24ead1449daf2d8a04bdccffa14e13c9) | 2026-11-05 19:56:08 | fix(gui): draw the base model for a colour variant whose renders are not images (#2379) |
| [913fc20e3b3ecc5b002dd2667ad1d5d67cace4d6](https://github.com/AprilNEA/OpenLogi/commit/913fc20e3b3ecc5b002dd2667ad1d5d67cace4d6) | 2026-11-05 19:54:07 | fix(core): match the pink g502 lightspeed to its gaming layout (#2378) |
| [27242519076fd3564446936b804434d9a64c64d0](https://github.com/AprilNEA/OpenLogi/commit/27242519076fd3564446936b804434d9a64c64d0) | 2026-11-05 19:37:45 | fix(fixture,hid): drop unsolicited hid++ input from cassette captures (#2377) |
| [9cdcda6b68534a230df3d0eb3ed9239feec17197](https://github.com/AprilNEA/OpenLogi/commit/9cdcda6b68534a230df3d0eb3ed9239feec17197) | 2026-11-05 18:30:54 | fix(core): match the purple g502 lightspeed to its gaming layout (#2373) |
| [8f55ed03b1bd6a99def2958e10cec7215257f41f](https://github.com/AprilNEA/OpenLogi/commit/8f55ed03b1bd6a99def2958e10cec7215257f41f) | 2026-11-05 15:05:06 | feat(gui): name G-key profiles from the M-key cards (#1240) |
| [1d4bf5bf3d29c7a9d1f15f1f57993a57274d49cb](https://github.com/AprilNEA/OpenLogi/commit/1d4bf5bf3d29c7a9d1f15f1f57993a57274d49cb) | 2026-11-05 14:47:10 | feat(keyboard): bind G-series G-keys and M profiles over 0x8010 (#1239) |
| [4ea5b600e36d20c10d66f1d066df5484e7e7bcac](https://github.com/AprilNEA/OpenLogi/commit/4ea5b600e36d20c10d66f1d066df5484e7e7bcac) | 2026-11-05 13:55:37 | feat(core): add the G903 LIGHTSPEED gaming layout (#2186) |
| [3a68eb7ca1e5788c4d6559bccfd38f750ebd2d7e](https://github.com/AprilNEA/OpenLogi/commit/3a68eb7ca1e5788c4d6559bccfd38f750ebd2d7e) | 2026-11-05 08:53:20 | docs(core): document schema v11 and the flow section (#2370) |
| [b645d94021ae0c139b1365e127595d0d1f387ce5](https://github.com/AprilNEA/OpenLogi/commit/b645d94021ae0c139b1365e127595d0d1f387ce5) | 2026-11-05 08:31:43 | fix(permissions): skip event nodes udev does not classify as a mouse (#2368) |
| [675c05b795da06c58091d7de04789f7deb5bbcd9](https://github.com/AprilNEA/OpenLogi/commit/675c05b795da06c58091d7de04789f7deb5bbcd9) | 2026-11-05 01:54:22 | fix(inject): post windows modifiers and fixed keys with their scan code (#2350) |
| [e6846bd8910d7efd1efa2289ab6cdbc2f8612743](https://github.com/AprilNEA/OpenLogi/commit/e6846bd8910d7efd1efa2289ab6cdbc2f8612743) | 2026-11-05 01:45:09 | fix(device): switch hosts when a diverted Easy-Switch key is released (#2355) |
| [e6154c265c921c907a4112c27e6922689d4e6aab](https://github.com/AprilNEA/OpenLogi/commit/e6154c265c921c907a4112c27e6922689d4e6aab) | 2026-11-05 01:04:29 | fix(gui): consume the settings view on the macOS permissions page (#2354) |
| [b6aa8d2361a2ab09aee720b204ea89026ff1d90a](https://github.com/AprilNEA/OpenLogi/commit/b6aa8d2361a2ab09aee720b204ea89026ff1d90a) | 2026-11-05 00:22:16 | fix(device): hear host keys from the moment they are armed (#2348) |
| [70aa1c07ad4db3583758de44f338339ee537daa6](https://github.com/AprilNEA/OpenLogi/commit/70aa1c07ad4db3583758de44f338339ee537daa6) | 2026-11-04 23:38:04 | fix(gui): stack the Ring size segment under its caption |
| [6e57b08ac3fafb282dc0e926f935ad4e8985941d](https://github.com/AprilNEA/OpenLogi/commit/6e57b08ac3fafb282dc0e926f935ad4e8985941d) | 2026-11-04 23:30:42 | fix(gui): match the mouse profile radios to their setting's text size |
| [0ca2b0550b6f8f144102eca61f131cb09a1f9c25](https://github.com/AprilNEA/OpenLogi/commit/0ca2b0550b6f8f144102eca61f131cb09a1f9c25) | 2026-11-04 23:30:41 | fix(gui): size theme cards to the Appearance page width |
| [3ce5a4623d4fe08da650588049b1fb763464431e](https://github.com/AprilNEA/OpenLogi/commit/3ce5a4623d4fe08da650588049b1fb763464431e) | 2026-11-04 23:30:41 | fix(gui): make Done the primary action after pairing |
| [65c917a28cd65cb2143ecb4131d36cc5fc7eb728](https://github.com/AprilNEA/OpenLogi/commit/65c917a28cd65cb2143ecb4131d36cc5fc7eb728) | 2026-11-04 23:30:41 | fix(gui): keep Tab working after a pairing step replaces the clicked control |
| [73229f10817492d55a686d0b4f562ca8b0b5d4e6](https://github.com/AprilNEA/OpenLogi/commit/73229f10817492d55a686d0b4f562ca8b0b5d4e6) | 2026-11-04 23:30:40 | fix(gui): fit the Actions Ring page at larger scales and narrow widths |
| [0a4665ace21a16318dfb5223a6ef002373df7fcc](https://github.com/AprilNEA/OpenLogi/commit/0a4665ace21a16318dfb5223a6ef002373df7fcc) | 2026-11-04 23:30:40 | fix(gui): give the device name the header's free width |
| [6e32d493dbdceacb24a1ec9504c3d36e17cb9366](https://github.com/AprilNEA/OpenLogi/commit/6e32d493dbdceacb24a1ec9504c3d36e17cb9366) | 2026-11-04 23:30:40 | fix(gui): drop the Studio Light card title that repeats the tab name |
| [5eecad40c9c6d432141f3fdb4c77d46dc31fcf39](https://github.com/AprilNEA/OpenLogi/commit/5eecad40c9c6d432141f3fdb4c77d46dc31fcf39) | 2026-11-04 23:30:39 | fix(gui): let device tabs shrink beside the rail at narrow widths |
| [bc6a2966b10a42a6c7bc5099fa49f2fa8b8ec72a](https://github.com/AprilNEA/OpenLogi/commit/bc6a2966b10a42a6c7bc5099fa49f2fa8b8ec72a) | 2026-11-04 23:30:39 | feat(gui): grant Linux input-device access from Settings |
| [60235e87c7e07ebadaa98de8270698cee4becf06](https://github.com/AprilNEA/OpenLogi/commit/60235e87c7e07ebadaa98de8270698cee4becf06) | 2026-11-04 23:27:16 | feat(linux): install the udev rules as root through pkexec |
| [d47b5b6246f144a7e9db33fb63528612402025cb](https://github.com/AprilNEA/OpenLogi/commit/d47b5b6246f144a7e9db33fb63528612402025cb) | 2026-11-04 23:27:15 | fix(gui): lay out the camera controls with SliderRow |
| [986561cc98068f3e45666a85cd8c8c84e8ed70ea](https://github.com/AprilNEA/OpenLogi/commit/986561cc98068f3e45666a85cd8c8c84e8ed70ea) | 2026-11-04 23:27:15 | fix(gui): set the Settings sensitivity rows in the kit items' type step |
| [007b4ae6b27d2d54948c7329cb8a31d0aa11e890](https://github.com/AprilNEA/OpenLogi/commit/007b4ae6b27d2d54948c7329cb8a31d0aa11e890) | 2026-11-04 23:27:15 | fix(gui): lay out the press-force row with SliderRow |
| [c7502425279c7ddacebbd632a5ac2144827b8f82](https://github.com/AprilNEA/OpenLogi/commit/c7502425279c7ddacebbd632a5ac2144827b8f82) | 2026-11-04 23:27:14 | fix(gui): let a mouse label value wrap to three lines |
| [52b0825690c06bc37016772cb35d6a8130c7e04d](https://github.com/AprilNEA/OpenLogi/commit/52b0825690c06bc37016772cb35d6a8130c7e04d) | 2026-11-04 23:27:14 | fix(gui): keep every key name whole in the keys inspector |
| [9178c6f0f82f3a57ea1e40bdfb3de694f1f382c7](https://github.com/AprilNEA/OpenLogi/commit/9178c6f0f82f3a57ea1e40bdfb3de694f1f382c7) | 2026-11-04 23:27:14 | fix(gui): close Add Device and mark devices reconnecting while the agent is lost |
| [be32512c3c5555e5f218d57989e6a9b4a4d23190](https://github.com/AprilNEA/OpenLogi/commit/be32512c3c5555e5f218d57989e6a9b4a4d23190) | 2026-11-04 23:27:13 | fix(gui): give low-contrast theme accents a visible fallback |
| [ef85071217daece1ad0f0182c5f75490345f06b4](https://github.com/AprilNEA/OpenLogi/commit/ef85071217daece1ad0f0182c5f75490345f06b4) | 2026-11-04 23:27:13 | chore(infra): flag amp's default git identity in orbs |
| [c86e14e4e25b81bce8e4121ac765f09f6598229f](https://github.com/AprilNEA/OpenLogi/commit/c86e14e4e25b81bce8e4121ac765f09f6598229f) | 2026-11-04 23:27:13 | chore(infra): render the desktop app on the amp orb desktop |
| [639a08cbd52def3fd7389bd944ec1e7a8dc60436](https://github.com/AprilNEA/OpenLogi/commit/639a08cbd52def3fd7389bd944ec1e7a8dc60436) | 2026-11-04 23:27:12 | ci(i18n): report English fill-in per locale in the Crowdin summary |
| [feb2cb722b5793204fee9213b6d9893e818365ae](https://github.com/AprilNEA/OpenLogi/commit/feb2cb722b5793204fee9213b6d9893e818365ae) | 2026-11-04 23:27:12 | docs(i18n): note that Crowdin upload skips English fill-in values |
| [b6d1e11d7a358b4420331ba20d15d2e4ef30cb08](https://github.com/AprilNEA/OpenLogi/commit/b6d1e11d7a358b4420331ba20d15d2e4ef30cb08) | 2026-11-04 23:17:54 | fix(gui): name every window before its first wayland commit (#2344) |
| [768501d620e8109f889c76d89c084b6805ff3a66](https://github.com/AprilNEA/OpenLogi/commit/768501d620e8109f889c76d89c084b6805ff3a66) | 2026-11-04 22:53:28 | fix(gui): name OpenLogi Agent in the Input Monitoring row while it is denied (#2113) |
| [5a33d8183fdab6b8f52b8ff9d205e632184d8fde](https://github.com/AprilNEA/OpenLogi/commit/5a33d8183fdab6b8f52b8ff9d205e632184d8fde) | 2026-11-04 21:52:07 | fix(inject): keep quotes in windows run command (#2337) |
| [b16cd8355d92523fcf68da38c7a47e11151cf356](https://github.com/AprilNEA/OpenLogi/commit/b16cd8355d92523fcf68da38c7a47e11151cf356) | 2026-11-04 21:07:40 | fix(overlay): let go of the display on windows while nothing shows (#2339) |
| [4b75971606ec6560e863f57dbe92a3820337c4be](https://github.com/AprilNEA/OpenLogi/commit/4b75971606ec6560e863f57dbe92a3820337c4be) | 2026-11-04 16:45:20 | fix(device): report a 0x1000 battery without mileage as a level (#2333) |
| [6466cd21f41fc2c78c5291e221ee85fb65a7a2ae](https://github.com/AprilNEA/OpenLogi/commit/6466cd21f41fc2c78c5291e221ee85fb65a7a2ae) | 2026-11-04 07:58:29 | ci(release): approve a release once, before it builds (#2329) |
| [72e979c3777ccb68ee395d071dccd70b420670c3](https://github.com/AprilNEA/OpenLogi/commit/72e979c3777ccb68ee395d071dccd70b420670c3) | 2026-11-04 06:05:13 | refactor(gui): adopt upstream gpui kit (#2229) |
