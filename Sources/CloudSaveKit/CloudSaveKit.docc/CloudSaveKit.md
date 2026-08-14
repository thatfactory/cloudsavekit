# ``CloudSaveKit``

Coordinate an application-owned local store with a private CloudKit database.

## Overview

CloudSaveKit wraps Apple's `CKSyncEngine` lifecycle and delegate surface without choosing a local database or record schema. A host provides a ``CloudSaveClient`` that can materialize pending `CKRecord` values, apply fetched changes transactionally, preserve CKSyncEngine state, and resolve conflicts using application semantics.

Create the engine early in application launch, call ``CloudSaveEngine/start()``, and enqueue changes only after their corresponding local transactions succeed. Observe ``CloudSaveEngine/statusUpdates`` to project synchronization state into the host architecture.

Automatic synchronization remains enabled by default. Use ``CloudSaveEngine/fetchNow()``, ``CloudSaveEngine/sendNow()``, or ``CloudSaveEngine/syncNow()`` only at user-visible checkpoints where immediate work is useful.

## Topics

### Engine

- ``CloudSaveEngine``
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
