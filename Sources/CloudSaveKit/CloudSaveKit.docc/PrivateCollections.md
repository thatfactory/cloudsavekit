# Personal Private Collections

Open one canonical collection in the current system context's private iCloud database.

## Ownership

``CloudSavePrivateCoordinator`` owns container/database construction, account queries and notifications, conditional bootstrap, and cloud-session invalidation. ``CloudSavePrivateSession`` uses the existing ``CloudSaveEngine`` for synchronization and exposes exact record reads for assets. The host owns its schema, pure `CKRecord` mapping, local database, media files, pending ledger, opaque checkpoint persistence, and interface.

The configurable engine and sharing APIs remain supported. Personal sessions opt into immutable account binding and trusted-manifest recovery; their behavior does not change legacy host-rebinding or automatic owned-zone repair.

## Observe and verify the account

Create one coordinator for a container and consume its ``CloudSavePrivateCoordinator/accountEvents`` stream before opening local persistence. The coordinator registers `CKAccountChanged` observation during initialization. ``CloudSavePrivateCoordinator/startMonitoring()`` starts its consumer idempotently; ``CloudSavePrivateCoordinator/refreshAccount()`` also starts monitoring.

An `.invalidated` event means the host must immediately clear visible account content, navigation, drafts, game state, images, and operation status before awaiting teardown. The coordinator fences old cloud work before emitting the event. It then resolves availability and the current opaque account record name. Notifications are revalidation triggers, including notifications caused by another Apple TV profile; they are not proof of an account identity. Forward foreground activation by calling `refreshAccount()` rather than adding another raw CloudKit observer.

Only `.verified(account)` supplies a ``CloudSaveVerifiedAccount`` token. Its initializer is internal and it contains coordinator/generation provenance. A stored account string is useful as a local namespace key but cannot recreate verification. Refreshes coalesce while in flight; a later account notification supersedes a suspended query immediately. Every fresh reconciliation invalidates previous tokens and sessions, even if the resolved account is the same.

After immediately emitting invalidation, the coordinator drains admitted host callbacks before resolving the new identity. Retirement barriers remain ordered across overlapping A → B → A notifications, so a returning account cannot read its checkpoint while an earlier generation still writes it. Cancellation of CloudKit operations alone does not establish host-write completion.

## Bootstrap a neutral schema

This example uses a notebook schema and an integer collection identity. The host's decoder is pure and issues no CloudKit requests:

```swift
let coordinator = CloudSavePrivateCoordinator(
    containerIdentifier: "iCloud.com.example.notebook"
)
guard case .verified(let account) = try await coordinator.refreshAccount() else {
    // Show the appropriate account-availability state.
    return
}

let bootstrap = try await coordinator.bootstrapManifest(
    for: account,
    zoneName: "NotebookPrivate",
    recordType: "NotebookManifest",
    recordName: "settings",
    expectedIdentity: previouslyTrustedRevision,
    makeInitialRecord: { recordID in
        let record = CKRecord(recordType: "NotebookManifest", recordID: recordID)
        record["revision"] = NSNumber(value: 1)
        return record
    },
    decodeIdentity: { record in
        guard let revision = record["revision"] as? NSNumber else {
            throw NotebookError.invalidManifest
        }
        return revision.intValue
    }
)
```

`previouslyTrustedRevision` is the host's optional persisted identity for this exact account and namespace. Pass `nil` only when first provisioning is allowed. An existing trusted identity requires an existing, valid, matching server manifest; absence, malformed schema, or contradictory identity never creates a replacement. Local namespaces and checkpoint provenance must include the account, canonical identity, and exact zone.

Bootstrap reads only the exact private record. It provisions a zone only after positively classified first-use absence. Manifest creation uses `CKModifyRecordsOperation` with `.ifServerRecordUnchanged`, one atomic record, and per-item result inspection. The operation API provides explicit task cancellation. Both successful creation and a concurrent creation conflict are followed by a server reread; the locally proposed identity never wins merely because it was proposed. A lost acknowledgement or failed local binding write can be retried safely by rediscovering the canonical record.

Requests for the same account generation, record, schema type, and creation permission share their transport work. Each caller validates the canonical result using its own decoder and expected identity. No broad zone discovery, shared-database access, or application-specific field interpretation is involved.

## Open an immutable session

After persisting the trusted binding, open the matching local store and validate its checkpoint provenance:

```swift
let session = try await coordinator.makeSession(
    for: bootstrap,
    stateSerialization: restoredCheckpoint,
    client: localStore
)
try await session.start()
try await session.fetchNow()
// Now a newly initialized local projection may truthfully be reported as empty.
```

`start()` restores the durable ledger; it is not a remote fetch barrier. `fetchNow()` preserves the existing engine's freshness and host-apply guarantees. A failed initial fetch must remain a recovery state instead of reporting a new collection as empty.

The supplied client must permanently reference the original local store. Personal sessions never invoke the client's mutable-account rebinding callback. A matching sign-in may restore its ledger; a sign-out, switch, or mismatched sign-in invalidates the session first. Known-zone deletion and `zoneNotFound` are integrity failures: no automatic zone save, local zone-deletion callback, or speculative manifest replacement is permitted. The local mutation ledger must never contain the bootstrap manifest itself.

The session retains the bootstrap's pure decoder and canonical identity. Incoming manifest modifications must still decode to that identity; an unchanged initial delivery is valid. A malformed or contradictory manifest closes the session before any domain record in that fetched batch reaches the host or another pending batch can be sent. Keep the decoder independent of mutable UI or store state.

``CloudSavePrivateSession/fetchRecord(_:)`` accepts only the configured zone. It returns `nil` for a positively missing record and rejects stale results after suspension or invalidation. The host still validates schema and copies `CKAsset` temporary files into its own durable media transaction. Capture the original store and session across every asynchronous Save, delete, image, sync, and recovery operation. A callback already admitted to the old store may finish there, but must never publish into a replacement user's UI or enqueue on a replacement session.

## Offline trust and temporary availability

An ordinary network failure can leave an already verified same-account local collection usable. On cold launch, first establish the current identity through the coordinator; a matching trusted binding may then support an initialized offline cache if remote bootstrap fails with a transport outage. If current identity cannot be verified, hide caches and retain their bytes. A last-used account string, or tvOS's per-profile storage alone, is insufficient to prove that the Apple Account within that context has not changed.

Temporary account unavailability preserves local data and committed ledger entries, while fencing new CloudKit operations and enqueues. A private session retires its engine when that failure arrives through explicit operations or automatic engine events. `suspend()` and `invalidate()` are terminal for that handle. After account availability is verified again, bootstrap and create a new session from the latest durable checkpoint; there is no mutable resume or account-rebinding operation.

Both retirement methods wait for already-admitted host callbacks. Use one active session per durable account/zone store, and await retirement before reading the checkpoint for a replacement session. This ordering also applies to normal-to-recovery and recovery-to-normal replacement within the same account generation.

``CloudSavePrivateError`` distinguishes suspension, stale sessions, integrity failures, and transport failures. Task and CloudKit cancellation become `CancellationError`. Transport failures retain only ``CloudSaveFailure`` and optional retry timing, without exposing raw CloudKit user-info payloads. Direct bootstrap/asset requests retain server throttle deadlines across calls and recheck lifecycle after waiting. `CKSyncEngine` continues to own automatic synchronization scheduling and its retries.

Configured-zone fetch errors retain their transport classification through the private facade, including network failure and retry timing. `.hostRecoveryRequired` is reserved for host recovery; `.fetchIncomplete` means the required fresh fetch was not established and `.notStarted` means startup has not completed. An initialized, verified cache may remain usable after an incomplete fetch, but that outcome never establishes the initial-empty readiness barrier.

## Recovery and notifications

For host-owned checkpoint recovery, verify account and canonical manifest first, open the exact store, and create a session with `automaticallySync: false`. Start, fetch, verify the newly persisted checkpoint, durably mark recovery complete, and only then send pending mutations. Await invalidation of that recovery session before rereading its durable checkpoint and creating a normal session. Keep quarantine processing and local pending writes intact.

The package does not install a second database subscription or notification pipeline. `CKSyncEngine` retains that ownership. The application supplies platform entitlements and signing, including any tvOS current-user capability, and is responsible for real profile-switch acceptance. Credential-free package tests do not establish device account isolation or delivery of system notifications.

## Diagnostics and tests

Personal lifecycle events use the existing `com.thatfactory.cloudsavekit` subsystem, `sync` category, and ☁️ prefix. Account, bootstrap, session, engine, and exact-record outcomes use fixed privacy-safe tokens. Account names, record/zone identifiers, manifest values, images, and error payloads never enter messages. Pure tokens and value types remain silent.

The package's neutral notebook fixtures cover conditional creation races, interrupted provisioning, lost acknowledgements, known missing/malformed manifests, repeated account notifications during identity resolution, stale asset/ledger/materialization results, fixed-client A → B → A restoration, and pending local writes across suspension. Existing engine/sharing tests remain required regression coverage. Consumers additionally verify their own durable store, UI-generation guards, signing, initial-empty barrier, and real account transitions.
