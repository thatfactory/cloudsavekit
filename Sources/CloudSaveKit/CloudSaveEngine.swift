import CloudKit
import Foundation

/// Synchronizes an application's durable local records with a private CloudKit database.
public final actor CloudSaveEngine {
    /// A stream of privacy-safe synchronization status updates.
    public nonisolated let statusUpdates: AsyncStream<CloudSaveStatus>

    private let client: any CloudSaveClient
    private let configuration: CloudSaveConfiguration
    private let statusContinuation: AsyncStream<CloudSaveStatus>.Continuation
    private var lastPersistedStateSerialization: CKSyncEngine.State.Serialization?
    private var lifecycleGeneration = 0
    private var stateMachine = CloudSaveStateMachine()
    private var storedSyncEngine: CKSyncEngine?

    /// Creates an engine without starting synchronization.
    public init(
        configuration: CloudSaveConfiguration,
        client: any CloudSaveClient
    ) {
        let stream = AsyncStream.makeStream(of: CloudSaveStatus.self)
        statusUpdates = stream.stream
        statusContinuation = stream.continuation
        self.client = client
        self.configuration = configuration
        lastPersistedStateSerialization = configuration.stateSerialization
    }

    deinit {
        statusContinuation.finish()
    }

    /// Initializes CKSyncEngine and restores every locally durable pending change.
    public func start() async throws {
        let startingLifecycleGeneration = lifecycleGeneration
        let pendingChanges: [CloudSavePendingChange]
        do {
            pendingChanges = try await client.pendingChanges()
        } catch {
            await handleHostFailure(
                error,
                syncEngine: storedSyncEngine
            )
            throw error
        }

        guard lifecycleGeneration == startingLifecycleGeneration else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }

        let engine = storedSyncEngine ?? makeSyncEngine()
        storedSyncEngine = engine
        stateMachine.resolve(.hostPersistence)

        if lastPersistedStateSerialization == nil {
            engine.state.add(
                pendingDatabaseChanges: [.saveZone(configuration.zone)]
            )
        }

        restoreDurablePendingChanges(
            pendingChanges,
            syncEngine: engine
        )
        publishStatus(syncEngine: engine)
        CloudSaveLogging.log("start | pending=\(pendingChanges.count)")
    }

    /// Adds locally durable changes to CKSyncEngine's pending state.
    public func enqueue(_ changes: [CloudSavePendingChange]) {
        guard !stateMachine.requiresHostRecovery else {
            CloudSaveLogging.log(
                level: .error,
                "enqueue | ignored while host recovery is required"
            )
            return
        }

        guard let storedSyncEngine else {
            CloudSaveLogging.log(
                level: .error,
                "enqueue | ignored before start"
            )
            return
        }

        let configuredChanges = changes.filter {
            isInConfiguredZone($0.recordID)
        }
        storedSyncEngine.state.add(
            pendingRecordZoneChanges: configuredChanges.map(\.syncEngineChange)
        )
        publishStatus(syncEngine: storedSyncEngine)
        CloudSaveLogging.log("enqueue | count=\(configuredChanges.count)")
    }

    /// Immediately fetches changes for the configured save zone.
    public func fetchNow() async throws {
        let session = try operationalSyncEngine()

        do {
            let options = CKSyncEngine.FetchChangesOptions(
                scope: .zoneIDs([configuration.zone.zoneID])
            )
            try await session.syncEngine.fetchChanges(options)
            try validate(session)
        } catch is CancellationError {
            try throwRecoveryErrorIfNeeded(for: session)
            throw CancellationError()
        } catch let error as CKError where error.code == .operationCancelled {
            try throwRecoveryErrorIfNeeded(for: session)
            throw error
        } catch let error as CKError where !CloudSaveRetryPolicy.requiresApplicationAttention(for: error) {
            try throwRecoveryErrorIfNeeded(for: session)
            throw error
        } catch {
            try throwRecoveryErrorIfNeeded(for: session)
            await reportOperationFailure(
                CloudSaveFailure(error: error),
                operation: .fetching,
                syncEngine: session.syncEngine
            )
            throw error
        }
    }

    /// Immediately sends every locally durable pending change for the configured save zone.
    public func sendNow() async throws {
        let session = try operationalSyncEngine()
        let pendingChanges: [CloudSavePendingChange]

        do {
            pendingChanges = try await client.pendingChanges()
        } catch {
            try throwRecoveryErrorIfNeeded(for: session)
            await handleHostFailure(
                error,
                syncEngine: session.syncEngine
            )
            throw error
        }

        try validate(session)
        restoreDurablePendingChanges(
            pendingChanges,
            syncEngine: session.syncEngine
        )
        restoreFailedZoneChangeIfNeeded(syncEngine: session.syncEngine)

        do {
            let options = CKSyncEngine.SendChangesOptions(
                scope: .zoneIDs([configuration.zone.zoneID])
            )
            try await session.syncEngine.sendChanges(options)
            try validate(session)
        } catch is CancellationError {
            try throwRecoveryErrorIfNeeded(for: session)
            throw CancellationError()
        } catch let error as CKError where error.code == .operationCancelled {
            try throwRecoveryErrorIfNeeded(for: session)
            throw error
        } catch let error as CKError where !CloudSaveRetryPolicy.requiresApplicationAttention(for: error) {
            try throwRecoveryErrorIfNeeded(for: session)
            throw error
        } catch {
            try throwRecoveryErrorIfNeeded(for: session)
            await reportOperationFailure(
                CloudSaveFailure(error: error),
                operation: .sending,
                syncEngine: session.syncEngine
            )
            throw error
        }
    }

    /// Fetches, merges, and then sends pending changes for the configured save zone.
    public func syncNow() async throws {
        try await fetchNow()
        try await sendNow()
    }

    /// Cancels in-flight CKSyncEngine operations without starting or rebuilding an engine.
    public func cancel() async {
        guard let storedSyncEngine else {
            return
        }

        await storedSyncEngine.cancelOperations()
        guard self.storedSyncEngine === storedSyncEngine else {
            return
        }

        stateMachine.resetActiveOperations()
        publishStatus(syncEngine: storedSyncEngine)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSaveEngine: CKSyncEngineDelegate {
    public func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        guard storedSyncEngine === syncEngine else {
            CloudSaveLogging.log("event | ignored stale engine")
            return
        }

        do {
            switch event {
            case .stateUpdate(let event):
                try await persistStateUpdate(event)
            case .accountChange(let event):
                try await handleAccountChange(
                    event,
                    syncEngine: syncEngine
                )
            case .fetchedDatabaseChanges(let event):
                try await restoreDeletedZones(
                    event.deletions.map(\.zoneID).filter(isInConfiguredZone),
                    syncEngine: syncEngine
                )
            case .fetchedRecordZoneChanges(let event):
                try await client.applyFetchedChanges(
                    records: event.modifications.map(\.record).filter(isInConfiguredZone),
                    deletedRecordIDs: event.deletions.map(\.recordID).filter(isInConfiguredZone)
                )
            case .sentRecordZoneChanges(let event):
                try await handleSentRecordZoneChanges(
                    event,
                    syncEngine: syncEngine
                )
            case .sentDatabaseChanges(let event):
                await handleSentDatabaseChanges(
                    event,
                    syncEngine: syncEngine
                )
            case .willFetchChanges:
                begin(.fetching, syncEngine: syncEngine)
            case .willSendChanges:
                begin(.sending, syncEngine: syncEngine)
            case .didFetchChanges:
                complete(.fetching, syncEngine: syncEngine)
            case .didSendChanges:
                complete(.sending, syncEngine: syncEngine)
            case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
                break
            @unknown default:
                CloudSaveLogging.log(
                    level: .info,
                    "event | unknown"
                )
            }
        } catch {
            await handleHostFailure(
                error,
                syncEngine: syncEngine
            )
            CloudSaveLogging.log(
                level: .error,
                "event | failure=\(CloudSaveFailure(clientError: error))"
            )
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard storedSyncEngine === syncEngine,
            !stateMachine.requiresHostRecovery
        else {
            return nil
        }

        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            guard let recordID = $0.recordID else {
                return false
            }

            return context.options.scope.contains($0) && isInConfiguredZone(recordID)
        }

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges
        ) { [client] recordID in
            let record = await client.record(for: recordID)
            if record == nil {
                syncEngine.state.remove(
                    pendingRecordZoneChanges: [.saveRecord(recordID)]
                )
            }
            return record
        }
    }
}

// MARK: - Private Lifecycle

extension CloudSaveEngine {
    /// Creates a CKSyncEngine from the last state successfully persisted by the host.
    fileprivate func makeSyncEngine() -> CKSyncEngine {
        var engineConfiguration = CKSyncEngine.Configuration(
            database: configuration.database,
            stateSerialization: lastPersistedStateSerialization,
            delegate: self
        )
        engineConfiguration.automaticallySync = configuration.automaticallySync
        engineConfiguration.subscriptionID = configuration.subscriptionID
        return CKSyncEngine(engineConfiguration)
    }

    /// Returns the active engine or rejects work until its lifecycle is recovered.
    fileprivate func operationalSyncEngine() throws -> (
        syncEngine: CKSyncEngine,
        lifecycleGeneration: Int
    ) {
        guard !stateMachine.requiresHostRecovery else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }

        guard let storedSyncEngine else {
            throw CloudSaveEngineError.notStarted
        }

        return (
            syncEngine: storedSyncEngine,
            lifecycleGeneration: lifecycleGeneration
        )
    }

    /// Verifies that an actor-reentrant operation still belongs to the active engine.
    fileprivate func validate(
        _ session: (
            syncEngine: CKSyncEngine,
            lifecycleGeneration: Int
        )
    ) throws {
        guard session.lifecycleGeneration == lifecycleGeneration,
            storedSyncEngine === session.syncEngine,
            !stateMachine.requiresHostRecovery
        else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }
    }

    /// Converts cancellation from a stopped engine into the host-recovery lifecycle error.
    fileprivate func throwRecoveryErrorIfNeeded(
        for session: (
            syncEngine: CKSyncEngine,
            lifecycleGeneration: Int
        )
    ) throws {
        guard
            session.lifecycleGeneration != lifecycleGeneration
                || storedSyncEngine !== session.syncEngine
                || stateMachine.requiresHostRecovery
        else {
            return
        }

        throw CloudSaveEngineError.hostRecoveryRequired
    }

    /// Stops all work after a host persistence failure and preserves the last good checkpoint.
    fileprivate func stopAfterHostFailure(syncEngine: CKSyncEngine?) async {
        guard syncEngine == nil || storedSyncEngine === syncEngine else {
            return
        }

        let engineToCancel = syncEngine ?? storedSyncEngine
        storedSyncEngine = nil
        stateMachine.resetActiveOperations()
        await engineToCancel?.cancelOperations()
    }
}

// MARK: - Private Host Persistence

extension CloudSaveEngine {
    /// Persists an opaque state update before accepting it as the next recovery checkpoint.
    fileprivate func persistStateUpdate(
        _ event: CKSyncEngine.Event.StateUpdate
    ) async throws {
        try await client.persist(
            stateSerialization: event.stateSerialization
        )
        lastPersistedStateSerialization = event.stateSerialization
    }

    /// Reconciles CKSyncEngine's tracked changes with the host's authoritative durable ledger.
    fileprivate func restoreDurablePendingChanges(
        _ pendingChanges: [CloudSavePendingChange],
        syncEngine: CKSyncEngine
    ) {
        let configuredPendingChanges = pendingChanges.filter {
            isInConfiguredZone($0.recordID)
        }
        let durableChanges = configuredPendingChanges.map(\.syncEngineChange)
        let durableChangeSet = Set(durableChanges)
        let staleChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            guard let recordID = $0.recordID else {
                return false
            }

            return isInConfiguredZone(recordID) && !durableChangeSet.contains($0)
        }

        syncEngine.state.remove(
            pendingRecordZoneChanges: staleChanges
        )
        syncEngine.state.add(
            pendingRecordZoneChanges: durableChanges
        )
        stateMachine.reconcilePendingRecordIDs(
            Set(configuredPendingChanges.map(\.recordID)),
            in: configuration.zone.zoneID
        )
    }

    /// Restores a failed configured-zone save only for a host-requested explicit send.
    fileprivate func restoreFailedZoneChangeIfNeeded(syncEngine: CKSyncEngine) {
        guard stateMachine.requiresRecovery(for: configuration.zone.zoneID) else {
            return
        }

        syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(configuration.zone)]
        )
    }

    /// Restores durable host changes after CKSyncEngine clears state for an account transition.
    fileprivate func restorePendingChangesAfterAccountChange(
        _ accountChange: CloudSaveAccountChange,
        syncEngine: CKSyncEngine
    ) async throws {
        guard case .signedOut = accountChange else {
            let pendingChanges = try await client.pendingChanges()
            syncEngine.state.add(
                pendingDatabaseChanges: [.saveZone(configuration.zone)]
            )
            restoreDurablePendingChanges(
                pendingChanges,
                syncEngine: syncEngine
            )
            publishStatus(syncEngine: syncEngine)
            return
        }
    }

    /// Recreates the configured zone and restores the host's durable changes after deletion.
    fileprivate func restoreDeletedZones(
        _ zoneIDs: [CKRecordZone.ID],
        syncEngine: CKSyncEngine
    ) async throws {
        let configuredZoneIDs = zoneIDs.filter(isInConfiguredZone)
        guard !configuredZoneIDs.isEmpty else {
            return
        }

        try await client.applyDeletedZones(configuredZoneIDs)
        let pendingChanges = try await client.pendingChanges()
        syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(configuration.zone)]
        )
        restoreDurablePendingChanges(
            pendingChanges,
            syncEngine: syncEngine
        )
    }
}

// MARK: - Private Events

extension CloudSaveEngine {
    /// Forwards a known account transition without inventing destructive future cases.
    fileprivate func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange,
        syncEngine: CKSyncEngine
    ) async throws {
        guard let accountChange = event.cloudSaveAccountChange else {
            CloudSaveLogging.log(
                level: .info,
                "account change | ignored unknown type"
            )
            return
        }

        try await client.handle(accountChange: accountChange)
        try await restorePendingChangesAfterAccountChange(
            accountChange,
            syncEngine: syncEngine
        )
    }

    /// Handles successful and failed configured-zone changes independently.
    fileprivate func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges,
        syncEngine: CKSyncEngine
    ) async {
        let successfulZoneIDs =
            event.savedZones.map(\.zoneID).filter(isInConfiguredZone)
            + event.deletedZoneIDs.filter(isInConfiguredZone)
        stateMachine.resolve(zoneIDs: successfulZoneIDs)

        for failedSave in event.failedZoneSaves where isInConfiguredZone(failedSave.zone.zoneID) {
            await handleFailedZoneChange(
                failedSave.error,
                zoneID: failedSave.zone.zoneID,
                syncEngine: syncEngine
            )
        }

        for (zoneID, error) in event.failedZoneDeletes where isInConfiguredZone(zoneID) {
            await handleFailedZoneChange(
                error,
                zoneID: zoneID,
                syncEngine: syncEngine
            )
        }

        publishStatus(syncEngine: syncEngine)
    }

    /// Applies acknowledgements and resolves every record failure according to its error.
    fileprivate func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        let savedRecords = event.savedRecords.filter(isInConfiguredZone)
        let deletedRecordIDs = event.deletedRecordIDs.filter(isInConfiguredZone)

        try await client.didSave(records: savedRecords)
        try await client.didDelete(recordIDs: deletedRecordIDs)
        stateMachine.resolve(
            recordIDs: savedRecords.map(\.recordID) + deletedRecordIDs
        )

        var changesToRetry: [CKSyncEngine.PendingRecordZoneChange] = []
        var zonesToRetry: [CKSyncEngine.PendingDatabaseChange] = []

        for failedSave in event.failedRecordSaves where isInConfiguredZone(failedSave.record) {
            let recordID = failedSave.record.recordID
            switch failedSave.error.code {
            case .serverRecordChanged:
                try await handleConflict(
                    failedSave,
                    changesToRetry: &changesToRetry,
                    syncEngine: syncEngine
                )
            case .zoneNotFound:
                try await client.clearServerRecord(for: recordID)
                zonesToRetry.append(.saveZone(configuration.zone))
                changesToRetry.append(.saveRecord(recordID))
            case .unknownItem:
                try await client.clearServerRecord(for: recordID)
                changesToRetry.append(.saveRecord(recordID))
            default:
                guard CloudSaveRetryPolicy.requiresApplicationAttention(for: failedSave.error) else {
                    continue
                }

                await reportFailure(
                    CloudSaveFailure(error: failedSave.error),
                    context: .record(recordID),
                    syncEngine: syncEngine
                )
            }
        }

        for (recordID, error) in event.failedRecordDeletes where isInConfiguredZone(recordID) {
            switch error.code {
            case .unknownItem, .zoneNotFound:
                try await client.didDelete(recordIDs: [recordID])
                syncEngine.state.remove(
                    pendingRecordZoneChanges: [.deleteRecord(recordID)]
                )
                stateMachine.resolve(.record(recordID))
                if error.code == .zoneNotFound {
                    zonesToRetry.append(.saveZone(configuration.zone))
                }
            default:
                guard CloudSaveRetryPolicy.requiresApplicationAttention(for: error) else {
                    continue
                }

                await reportFailure(
                    CloudSaveFailure(error: error),
                    context: .record(recordID),
                    syncEngine: syncEngine
                )
            }
        }

        syncEngine.state.add(pendingDatabaseChanges: zonesToRetry)
        syncEngine.state.add(pendingRecordZoneChanges: changesToRetry)
        publishStatus(syncEngine: syncEngine)
    }

    /// Resolves one semantic record conflict without retaining an unwanted pending save.
    fileprivate func handleConflict(
        _ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        changesToRetry: inout [CKSyncEngine.PendingRecordZoneChange],
        syncEngine: CKSyncEngine
    ) async throws {
        let recordID = failedSave.record.recordID
        guard let serverRecord = failedSave.error.serverRecord else {
            await reportFailure(
                .recordConflict,
                context: .record(recordID),
                syncEngine: syncEngine
            )
            return
        }

        let conflict = CloudSaveConflict(
            clientRecord: failedSave.record,
            serverRecord: serverRecord,
            ancestorRecord: failedSave.error.ancestorRecord
        )

        switch try await client.resolve(conflict: conflict) {
        case .acceptServer:
            try await client.applyFetchedChanges(
                records: [serverRecord],
                deletedRecordIDs: []
            )
            syncEngine.state.remove(
                pendingRecordZoneChanges: [.saveRecord(recordID)]
            )
            stateMachine.resolve(.record(recordID))
        case .retry(let mergedRecord):
            try await client.persistResolvedRecord(mergedRecord)
            changesToRetry.append(.saveRecord(mergedRecord.recordID))
        case .requiresUserDecision:
            await reportFailure(
                .recordConflict,
                context: .record(recordID),
                syncEngine: syncEngine
            )
        }
    }
}

// MARK: - Private State

extension CloudSaveEngine {
    /// Begins one operation and publishes its in-progress state when no failure supersedes it.
    fileprivate func begin(
        _ operation: CloudSaveOperation,
        syncEngine: CKSyncEngine
    ) {
        stateMachine.begin(operation)
        publishStatus(syncEngine: syncEngine)
    }

    /// Completes one operation and clears only an eligible matching operation failure.
    fileprivate func complete(
        _ operation: CloudSaveOperation,
        syncEngine: CKSyncEngine
    ) {
        stateMachine.complete(operation)
        publishStatus(syncEngine: syncEngine)
    }

    /// Records an operation failure that requires a later matching generation to succeed.
    fileprivate func reportOperationFailure(
        _ failure: CloudSaveFailure,
        operation: CloudSaveOperation,
        syncEngine: CKSyncEngine
    ) async {
        stateMachine.fail(
            failure,
            operation: operation
        )
        publishStatus(syncEngine: syncEngine)
        await client.handle(
            failure: failure,
            recordID: nil
        )
    }

    /// Records a durable failure without replacing unrelated recovery requirements.
    fileprivate func reportFailure(
        _ failure: CloudSaveFailure,
        context: CloudSaveFailureContext,
        syncEngine: CKSyncEngine?
    ) async {
        stateMachine.fail(
            failure,
            context: context
        )
        publishStatus(syncEngine: syncEngine)
        await client.handle(
            failure: failure,
            recordID: context.recordID
        )
    }

    /// Reports and stops after a host callback failure.
    fileprivate func handleHostFailure(
        _ error: any Error,
        syncEngine: CKSyncEngine?
    ) async {
        let failure = CloudSaveFailure(clientError: error)
        lifecycleGeneration &+= 1
        stateMachine.fail(
            failure,
            context: .hostPersistence
        )
        publishStatus(syncEngine: syncEngine)
        await stopAfterHostFailure(syncEngine: syncEngine)
        await client.handle(
            failure: failure,
            recordID: nil
        )
    }

    /// Handles a zone failure according to CKSyncEngine's retry ownership.
    fileprivate func handleFailedZoneChange(
        _ error: CKError,
        zoneID: CKRecordZone.ID,
        syncEngine: CKSyncEngine
    ) async {
        guard CloudSaveRetryPolicy.requiresApplicationAttention(for: error) else {
            return
        }

        let failure = CloudSaveFailure(error: error)
        await reportFailure(
            failure,
            context: .zone(zoneID),
            syncEngine: syncEngine
        )
        CloudSaveLogging.log(
            level: .error,
            "zone change | failure=\(failure)"
        )
    }

    /// Publishes the state-machine projection without exposing record identifiers.
    fileprivate func publishStatus(syncEngine: CKSyncEngine?) {
        let hasPendingChanges =
            syncEngine?.state.pendingRecordZoneChanges.contains {
                guard let recordID = $0.recordID else {
                    return false
                }

                return isInConfiguredZone(recordID)
            } ?? false
        statusContinuation.yield(
            stateMachine.status(hasPendingChanges: hasPendingChanges)
        )
    }
}

// MARK: - Private Zone Filtering

extension CloudSaveEngine {
    /// Filters CloudKit fetches to the custom zone owned by this engine.
    fileprivate func isInConfiguredZone(_ record: CKRecord) -> Bool {
        isInConfiguredZone(record.recordID)
    }

    /// Filters CloudKit changes to the custom zone owned by this engine.
    fileprivate func isInConfiguredZone(_ recordID: CKRecord.ID) -> Bool {
        recordID.zoneID == configuration.zone.zoneID
    }

    /// Filters custom-zone events to the zone owned by this engine.
    fileprivate func isInConfiguredZone(_ zoneID: CKRecordZone.ID) -> Bool {
        zoneID == configuration.zone.zoneID
    }
}
