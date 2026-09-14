# Explicit Synchronization

Understand the guarantees and limits of fetch, send, and combined synchronization.

## Overview

Automatic synchronization is the normal production mode. Use ``CloudSaveEngine/fetchNow()``, ``CloudSaveEngine/sendNow()``, or ``CloudSaveEngine/syncNow()`` at user-visible checkpoints where immediate progress matters. These methods complement CKSyncEngine's scheduler; they do not replace durable local commits, guarantee network availability, or disable system-scheduled work.

Call ``CloudSaveEngine/start()`` successfully first. Explicit operations throw ``CloudSaveEngineError/notStarted`` before startup and ``CloudSaveEngineError/hostRecoveryRequired`` after a host persistence failure.

## Fetch freshness and apply

An explicit fetch is both a freshness barrier and an apply barrier for the configured zone. It waits for fetch work already active when the request arrives, then requires a fetch generation that began after the request. CKSyncEngine finishes its API call only after the related delegate events and host apply callbacks complete.

A post-request automatic generation may satisfy the barrier; a pre-request generation cannot. This preserves CKSyncEngine's scheduler while preventing a manual refresh from reporting success merely because older work completed. If no qualifying generation is observed, the operation raises ``CloudSaveEngineError/freshFetchNotObserved``. If the configured zone fails during the qualifying generation, it raises ``CloudSaveEngineError/configuredZoneFetchFailed``.

Explicit operations are serialized per engine. Repeated taps do not create overlapping explicit engine work.

## Send reconciliation

``CloudSaveEngine/sendNow()`` reloads the host's durable pending ledger before sending. It materializes current records through ``CloudSaveClient/record(for:)`` and revalidates asynchronous results against the current engine lifecycle.

A `nil` materialization means the record no longer exists and is reconciled with the current ledger. A thrown materialization error is a host failure and stops synchronization. After CloudKit acknowledges a save or deletion, CloudSaveKit rereads the durable ledger before removing completed work so a newer mutation of the same record is not erased by an older acknowledgement.

## Interpreting transfer counts

An application's operation summary should be interpreted as a snapshot of work attributed to that explicit operation, not as an engine-lifetime counter. CKSyncEngine can run a push-driven scheduled generation immediately before or during a user action. That scheduled generation may apply the remote record before the explicit generation completes, leaving the final manual snapshot with zero downloads even though the visible data is fresh.

When diagnosing a manual refresh, correlate the complete ordered timeline:

```text
scheduled or manual generation starts
database reports configured zone changed
configured zone delivers records or deletions
host applies the batch
qualifying generation completes
user-visible operation completes
```

Do not infer that no download occurred from the final count alone.

## Lifecycle invalidation

Account changes, host failures, cancellation, and engine replacement invalidate stale explicit operations and asynchronous materialization. A newly initialized nil-state engine has one narrow exception: its first matching sign-in event establishes the initial account and may finish reconciliation without invalidating the bootstrap fetch. Every later sign-in, sign-out, or account switch retains full lifecycle invalidation.
