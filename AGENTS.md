# CloudSaveKit

## Context

CloudSaveKit is a pure Swift package that coordinates a host application's durable local store with a private CloudKit database through `CKSyncEngine`. Read [README.md](README.md) and the DocC catalog before changing public behavior.

The package is persistence-, UI-, and application-architecture agnostic. Host applications own their local database, record schemas, merge semantics, and user-facing recovery policy.

## Shared guidelines

Read only the guides relevant to the task:

- [Swift](AgentGuidelines/Guidelines/Swift/Swift.md)
- [Swift style](AgentGuidelines/Guidelines/Swift/SwiftStyle.md)
- [Swift format](AgentGuidelines/Guidelines/Swift/SwiftFormat.md)
- [Unit and integration testing](AgentGuidelines/Guidelines/Testing/UnitTesting.md)
- [Documentation](AgentGuidelines/Guidelines/Documentation.md)
- [Logging](AgentGuidelines/Guidelines/Logging.md)
- [Packages](AgentGuidelines/Guidelines/Packages.md)
- [CI/CD](AgentGuidelines/Guidelines/CICD.md)
- [Git repositories and SSH-first cloning](AgentGuidelines/Guidelines/Git/Repositories.md)
- [GitHub pull requests](AgentGuidelines/Guidelines/GitHub/PullRequests.md)
- [Xcode MCP](AgentGuidelines/Guidelines/Xcode/MCP.md)
- [Xcode security audits](AgentGuidelines/Guidelines/Xcode/Security.md)

Redux, SwiftData, SwiftUI, and application-localization guidance do not apply to the package target.

## Physical folder map

| Role | Physical folder |
|---|---|
| Package sources | `Sources/CloudSaveKit/` |
| DocC catalog | `Sources/CloudSaveKit/CloudSaveKit.docc/` |
| Unit tests | `Tests/CloudSaveKitTests/` |

## Package specialization

- Use `CKSyncEngine` rather than duplicating its scheduling, batching, state tracking, or transient retry behavior.
- Do not add a local database, Redux, UI, product record schema, or game-specific conflict policy.
- Persist every engine state update through the host-provided client boundary.
- Keep status and errors privacy-safe; never log record contents or identifiers.
- Update tests, DocC, README examples, and release notes when public behavior changes.
- Use logging subsystem `com.thatfactory.cloudsavekit`, category `sync`, and canonical package emoji `☁️`.

## Codex review scope

For consumer pull requests, do not substantively review `AgentGuidelines/**` after exact tagged-tree provenance has been verified. Verify its `VERSION`, compare its tree with the matching central tag, and verify the required `.gitattributes` rule. If provenance does not match exactly, review the subtree contents and stop the merge. Report substantive guideline feedback against the central `agent-guidelines` pull request.
