# Changelog

All notable changes to CloudSaveKit are documented here.

## Unreleased

### Added

- Added explicit owned and shared zone configuration for `CKSyncEngine`.
- Added UI-independent zone-wide share creation, acceptance, and discovery.
- Added a reconfiguration boundary for unavailable shared zones so participants never create private replacements.

### Fixed

- Restored a share participant's durable record changes after initial sign-in without attempting to create the owner's shared zone.

## 0.1.1 — 2026-08-18

### Maintenance

- Updated the synchronized `AgentGuidelines` subtree to 0.0.18.
- Added consumer integration validation and audit-skill wiring.
- Expanded strict Swift-format CI to cover `Package.swift`.
- Applied shared formatting to the package manifest.

This release contains no public API or runtime behavior changes.
