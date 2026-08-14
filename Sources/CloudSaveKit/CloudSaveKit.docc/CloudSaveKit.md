# ``CloudSaveKit``

Coordinate an application-owned local store with a private CloudKit database.

## Overview

CloudSaveKit wraps Apple's `CKSyncEngine` lifecycle and delegate surface without choosing a local database or record schema. A host provides a ``CloudSaveClient`` that can materialize pending `CKRecord` values, apply fetched changes transactionally, preserve CKSyncEngine state, and resolve conflicts using application semantics.

Create the engine early in application launch, call ``CloudSaveEngine/start()``, and enqueue changes only after their corresponding local transactions succeed. Observe ``CloudSaveEngine/statusUpdates`` to project synchronization state into the host architecture. The current-state stream begins with ``CloudSaveStatus/idle`` and retains only its latest unconsumed value rather than preserving an event history.

Automatic synchronization remains enabled by default. Use ``CloudSaveEngine/fetchNow()``, ``CloudSaveEngine/sendNow()``, or ``CloudSaveEngine/syncNow()`` only at user-visible checkpoints where immediate work is useful. Explicit synchronization requires a successful ``CloudSaveEngine/start()`` and raises ``CloudSaveEngineError`` when the engine has not started or host recovery is required.

CloudSaveKit forwards only records, record deletions, and custom-zone deletions from its configured custom zone. If the host cannot persist a sync-engine checkpoint or apply a CloudKit result, the engine cancels the current work and waits for the host to call ``CloudSaveEngine/start()`` after local recovery. Host callback failures are reported as ``CloudSaveFailure/localPersistence``.

CKSyncEngine retains recoverable transport failures and schedules their retries; cancellation from an explicit operation, host-ledger preflight, or record materialization does not become a local-persistence failure. CloudSaveKit keeps permanent and semantic failures independently by record, zone, operation, and host-persistence context. A successful fetch cannot erase a record upload failure, one successful record cannot erase another conflict, and completion from the operation that failed cannot immediately clear its own error. A matching recovery operation also waits for every older overlapping operation of that kind to drain before clearing the failure. ``CloudSaveEngine/sendNow()`` reconciles CKSyncEngine state with the host's durable pending-change ledger before every explicit send. Host-ledger reads and mutations are serialized and versioned, and app enqueues that race with a suspended read are replayed afterward in their original order, so a stale snapshot cannot replace a newer change or resurrect completed work. Successful sends and absent record materializations reread the current host ledger before discarding pending state, preserving a newer same-record mutation that superseded suspended work. A thrown materialization error enters host recovery instead of silently retrying an unreadable record. Record batches are revalidated after asynchronous materialization and rejected as a whole when their engine lifecycle becomes stale. A host callback failure blocks new work and advances the lifecycle immediately. Checkpoint writes and explicit ``CloudSaveEngine/start()`` recovery remain ordered behind failed-engine cancellation so an older engine cannot regress the recovery state after its replacement starts. Known account transitions block synchronization from the moment the lifecycle advances until the host has switched account-scoped persistence and restored the new durable ledger. This prevents pre-transition work from entering the new account; transitions also clear previous-account recovery state, and sign-out immediately publishes the cleared status.

## Topics

### Engine

- ``CloudSaveEngine``
- ``CloudSaveEngineError``
- ``CloudSaveConfiguration``
- ``CloudSaveStatus``

### Local-store boundary

- ``CloudSaveClient``
- ``CloudSavePendingChange``

### Recovery

- ``CloudSaveFailure``
- ``CloudSaveAccountChange``
- ``CloudSaveConflict``
- ``CloudSaveConflictResolution``
