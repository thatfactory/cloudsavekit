# Troubleshooting Synchronization

Diagnose configuration, server visibility, discovery, delivery, apply, and UI refresh as separate stages.

## Use an evidence ladder

For one unique disposable record, establish each boundary in order:

1. The host committed the local value and durable pending change.
2. CloudSaveKit requested or scheduled the change.
3. The sending device received a successful CloudKit acknowledgement.
4. An authorized reciprocal CloudKit view can observe the record.
5. The receiving engine discovered that its configured zone changed.
6. CKSyncEngine delivered the record or deletion.
7. The host applied the batch transactionally.
8. The user-visible store refreshed after apply.

Stopping at an earlier boundary can make a later component look broken. For example, successful upload and server visibility do not prove that the receiving build can receive push-driven change discovery.

## Fetch succeeds but no records arrive

If explicit fetch generations complete while the known server record remains absent locally:

- Verify that the engine uses the intended container, environment, database scope, and full owner-qualified zone identifier.
- Verify that the restored checkpoint belongs to that same account and topology.
- Inspect the signed application entitlements and embedded provisioning profile for the expected iCloud container and APNs environment.
- Confirm Push Notifications and the Remote notifications background mode are enabled.
- Confirm the receiving account still has access to the shared zone.
- Look for database-change and configured-zone delivery events, not only the outer fetch completion.

A successful fetch API call does not independently prove that a stale or mismatched checkpoint discovered the expected zone. Likewise, a configured-zone dirty flag of `false` is not proof that the server contains no newer records.

## Data appears but the manual result says zero

CKSyncEngine may perform a scheduled fetch immediately before the explicit generation. If logs show database discovery, zone delivery, and host apply before manual completion, the final explicit operation can correctly report zero transferred records because the scheduled generation already applied them. Treat operation counts as attribution snapshots and use the ordered timeline.

## Shared data forks into a private zone

Verify that participants use `sharedCloudDatabase` and the accepted owner-qualified zone identifier. Never recover a missing shared zone by creating a same-named zone in the private database. Lost shared access requires host reconfiguration.

## Startup or recovery fails

``CloudSaveEngineError/notStarted`` means no successful ``CloudSaveEngine/start()`` has completed. ``CloudSaveEngineError/hostRecoveryRequired`` means a client persistence callback failed; repair the local store and restart the engine. ``CloudSaveEngineError/reconfigurationRequired`` means the configured shared topology is no longer available.

Do not fix checkpoint problems by deleting user data, pending mutations, or server system fields. Bind opaque state to host-owned provenance and make any nil-state recovery explicit, bounded, and observable.

## Read CloudSaveKit logs

CloudSaveKit uses subsystem `com.thatfactory.cloudsavekit`, category `sync`, and prefix ☁️. It reports privacy-safe generations, database discovery, configured-zone delivery counts, dirty-state transitions, and failures without record or zone identifiers.

Useful acceptance evidence includes a changed configured zone, delivered modification or deletion counts, successful zone completion, and a host-side confirmation that the batch committed. Framework console noise unrelated to these boundaries should not be treated as a package failure without a corresponding CloudSaveKit or host error.

Never add record contents, identifiers, share URLs, account values, or credentials to logs merely to make correlation easier.

## Avoid fragile repairs

Do not add arbitrary sleeps, unbounded polling, repeated engine recreation, destructive token resets, or duplicate private zones. These approaches obscure which boundary failed and can create data divergence. Use deterministic lifecycle tests and one controlled physical-device reproduction instead.
