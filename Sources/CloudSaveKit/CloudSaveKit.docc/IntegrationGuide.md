# Integrating CloudSaveKit

Configure a host application for durable private or shared CloudKit synchronization.

## Overview

CloudSaveKit coordinates CKSyncEngine, but the host remains the source of truth for local data. A correct integration combines application capabilities and signing, a durable ``CloudSaveClient``, an owner-aware zone configuration, and lifecycle orchestration that starts synchronization only after account-scoped persistence is ready.

## Configure the application target

Enable iCloud with CloudKit, select the intended container, enable Push Notifications, and enable the Remote notifications background mode. Deploy the record schema to every CloudKit environment the application will use.

The target's Xcode settings are not proof that a distributed or locally installed binary has the required capabilities. For physical-device testing, inspect both the signed application entitlements and the embedded provisioning profile. They must contain the expected iCloud container and an APNs environment appropriate to the build. Reinstall after changing capabilities or profiles.

Push capability is operationally important even when the application exposes a manual refresh button. CKSyncEngine relies on CloudKit notifications to discover database changes efficiently. A build without a valid APNs entitlement may upload successfully while a receiving device repeatedly completes fetch calls without discovering a changed zone.

## Implement the durable client boundary

Implement ``CloudSaveClient`` in the actor that owns the local store. Its callbacks form a transactional durability boundary:

- ``CloudSaveClient/pendingChanges()`` returns every locally committed change not yet acknowledged by CloudKit.
- ``CloudSaveClient/record(for:)`` materializes the latest local representation for a pending save.
- ``CloudSaveClient/persist(stateSerialization:)`` stores every opaque CKSyncEngine checkpoint.
- ``CloudSaveClient/applyFetchedChanges(records:deletedRecordIDs:)`` applies one fetched batch atomically.
- ``CloudSaveClient/didSave(records:)`` persists returned system fields before acknowledging uploads.
- ``CloudSaveClient/didDelete(recordIDs:)`` acknowledges remote deletions in the durable ledger.
- Account, conflict, deleted-zone, and failure callbacks update host-owned state and policy.

Commit application data and its pending ledger entry in one local transaction before calling ``CloudSaveEngine/enqueue(_:)``. Treat the durable ledger, not CKSyncEngine's in-memory queue, as the source of truth across termination and recovery.

Store server system fields with local records so later updates retain CloudKit change tags. Resolve conflicts using application semantics and base retries on the supplied server record.

## Preserve checkpoint provenance

`CKSyncEngine.State.Serialization` is opaque. Store it durably after every callback and restore it through ``CloudSaveConfiguration/stateSerialization``. A host that supports multiple accounts, inventories, database scopes, or zones should bind each serialization to that exact context and reject mismatches before creating an engine. CloudSaveKit cannot infer whether an otherwise valid opaque checkpoint belongs to the host's current domain identity.

If the host intentionally performs a nil-state recovery, keep it bounded and recoverable. Do not erase user records or pending mutations merely to reset CloudKit state, and do not send pending changes until the recovered checkpoint and topology have been validated.

## Configure one exact zone

For an owned zone, use the private database and a ``CloudSaveConfiguration`` initialized with the zone. For a shared zone, use the shared database and the exact owner-qualified zone identifier:

```swift
let configuration = CloudSaveConfiguration(
    database: container.sharedCloudDatabase,
    stateSerialization: restoredState,
    sharedZoneID: acceptedZoneID
)
```

The initializers enforce the database-scope pairing. Preserve the complete `CKRecordZone.ID`, including its owner name. A zone name alone is not sufficient for a shared zone.

## Start and recover

Construct the engine only after restoring the matching checkpoint and durable pending ledger, then call ``CloudSaveEngine/start()``. Do not call explicit operations before startup succeeds.

If a host persistence callback fails, CloudSaveKit invalidates current work and raises ``CloudSaveEngineError/hostRecoveryRequired`` for new explicit operations. Repair the local-store problem and call ``CloudSaveEngine/start()`` again; the engine rebuilds from the last checkpoint that the host successfully persisted and reloads the durable ledger.

Account transitions invalidate old operations before the host switches account-scoped persistence. The host must restore the new account's ledger and checkpoint in ``CloudSaveClient/handle(accountChange:)``. Never allow one account's pending records or checkpoint to enter another account's engine.

## Verify the integration

Test local-first offline creation, relaunch with pending work, conflict resolution, deletion, account transitions, host callback failure and restart, shared-zone revocation, concurrent enqueue and send, and fetched changes applied before user-visible completion. For sharing, perform a two-device test with separate iCloud accounts and verify both upload directions.
