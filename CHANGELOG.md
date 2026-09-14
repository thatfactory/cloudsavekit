# Changelog

## Unreleased

- Preserve the first explicit fetch across the initial matching sign-in reconciliation of a nil-state engine while retaining lifecycle invalidation for every later account transition.

All notable changes to CloudSaveKit are documented here.

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
