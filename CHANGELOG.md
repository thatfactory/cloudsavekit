# Changelog

All notable changes to CloudSaveKit are documented here.

## 0.3.1 — 2026-10-29

### Documentation

- Documented a tvOS secondary-profile failure mode in which a correctly entitled app receives the default profile's CloudKit account, with privacy-safe account/store diagnosis and bounded owner-coordinated profile re-addition.
- Clarified that CloudSaveKit binds CloudKit's verified account and cannot infer a mismatch from the visible system profile; consumer two-account acceptance remains necessary.

This release contains no public API or runtime behavior changes.

## 0.3.0 — 2026-10-28

### Added

- Added `CloudSavePrivateCoordinator` with package-owned container creation, account notifications, verified account tokens, and coalesced exact-manifest provisioning.
- Added conditional manifest creation, canonical-winner rereads, trusted-identity validation, cancellable record/asset transport, and server retry timing without a second synchronization scheduler.
- Added immutable `CloudSavePrivateSession` handles over the existing engine, terminal suspension/invalidation, and normalized private-session errors.
- Added host-callback retirement barriers across account generations and recovery replacements, active manifest-identity validation, and preserved configured-zone transport failures for trusted offline use.
- Added deterministic neutral-schema tests for concurrent creators, interrupted provisioning, lost acknowledgements, stale identity/asset/ledger results, A → B → A isolation, and pending writes across temporary unavailability.
- Documented personal-store integration, cold-launch offline trust, checkpoint recovery ordering, and privacy-safe lifecycle diagnostics.

### Changed

- Personal sessions opt into fixed-account and trusted-manifest policies: a wrong account or lost private topology fences work before host rebinding, destructive deletion callbacks, or automatic zone recreation. Existing engine and sharing integrations retain their original policies.
- Adopted the exact Agent Guidelines `0.0.42` tree and synchronized the root code-review contract.

## 0.2.6 — 2026-09-19

### Changed

- Adopted Agent Guidelines `0.0.33` and the Swift package compiler-settings baseline.
- Declared Swift 6, warnings as errors, and the required upcoming language features for every package target.
- Made imports and existential types explicit where required by the stricter compiler policy without intentionally changing runtime behavior.


## 0.2.5 — 2026-09-14

### Documentation

- Added integration, explicit-synchronization, shared-zone, and troubleshooting guides to the public DocC catalog.
- Documented required CloudKit, Push Notifications, background-mode, signing, and provisioning configuration.
- Clarified host persistence responsibilities, checkpoint provenance, transfer-count attribution, shared-zone recovery, and two-device acceptance.
- Updated the package installation example to the current release.

This release contains no public API or runtime behavior changes.

## 0.2.4 — 2026-09-14

### Fixed

- Preserve the first explicit fetch across the initial matching sign-in reconciliation of a nil-state engine while retaining lifecycle invalidation for every later account transition.

## 0.2.3 — 2026-09-14

### Fixed

- Propagate configured-zone fetch failures through explicit freshness requests instead of treating only the outer fetch generation as success.
- Add privacy-safe fetch-stage diagnostics for database discovery, configured-zone delivery, and dirty-state transitions.

## 0.2.2 — 2026-09-14

### Fixed

- Made explicit fetch and sync requests wait for a post-request CKSyncEngine fetch generation and all related host applies instead of coalescing with stale pre-request work.
- Serialized explicit fetch, send, and sync operations per engine while preserving automatic CKSyncEngine scheduling.

## 0.2.1 — 2026-09-13

### Fixed

- Restored a share participant's durable record changes after initial sign-in without attempting to create the owner's shared zone.

## 0.2.0 — 2026-09-13

### Added

- Added explicit owned and shared zone configuration for `CKSyncEngine`.
- Added UI-independent zone-wide share creation, acceptance, and discovery.
- Added a reconfiguration boundary for unavailable shared zones so participants never create private replacements.

## 0.1.1 — 2026-08-18

### Maintenance

- Updated the synchronized `AgentGuidelines` subtree to 0.0.18.
- Added consumer integration validation and audit-skill wiring.
- Expanded strict Swift-format CI to cover `Package.swift`.
- Applied shared formatting to the package manifest.

This release contains no public API or runtime behavior changes.
