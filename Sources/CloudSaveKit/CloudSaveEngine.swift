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
    private var pendingRecoveryOperation: RecoveryOperation?
    private var storedSyncEngine: CKSyncEngine?
    private var unresolvedFailure: CloudSaveFailure?

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
        let engine = syncEngine

        if configuration.stateSerialization == nil {
            engine.state.add(
                pendingDatabaseChanges: [.saveZone(configuration.zone)]
            )
        }

        let pendingChanges = try await client.pendingChanges()
        engine.state.add(
            pendingRecordZoneChanges: pendingChanges.map(\.syncEngineChange)
        )

        publishReadyStatus(syncEngine: engine)
        CloudSaveLogging.log("start | pending=\(pendingChanges.count)")
    }

    /// Adds locally durable changes to CKSyncEngine's pending state.
    public func enqueue(_ changes: [CloudSavePendingChange]) {
        let engine = syncEngine
        engine.state.add(
            pendingRecordZoneChanges: changes.map(\.syncEngineChange)
        )
        publishReadyStatus(syncEngine: engine)
        CloudSaveLogging.log("enqueue | count=\(changes.count)")
    }

    /// Immediately fetches changes for the configured save zone.
    public func fetchNow() async throws {
        do {
            let options = CKSyncEngine.FetchChangesOptions(
                scope: .zoneIDs([configuration.zone.zoneID])
            )
            try await syncEngine.fetchChanges(options)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CKError where error.code == .operationCancelled {
            throw error
        } catch {
            let failure = CloudSaveFailure(error: error)
            await reportAttentionRequiredFailure(failure)
            throw error
        }
    }

    /// Immediately sends pending changes for the configured save zone.
    public func sendNow() async throws {
        do {
            let options = CKSyncEngine.SendChangesOptions(
                scope: .zoneIDs([configuration.zone.zoneID])
            )
            try await syncEngine.sendChanges(options)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CKError where error.code == .operationCancelled {
            throw error
        } catch {
            let failure = CloudSaveFailure(error: error)
            await reportAttentionRequiredFailure(failure)
            throw error
        }
    }

    /// Fetches, merges, and then sends pending changes for the configured save zone.
    public func syncNow() async throws {
        try await fetchNow()
        try await sendNow()
    }

    /// Cancels in-flight CKSyncEngine operations.
    public func cancel() async {
        await syncEngine.cancelOperations()
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
                try await client.persist(
                    stateSerialization: event.stateSerialization
                )
                lastPersistedStateSerialization = event.stateSerialization
            case .accountChange(let event):
                try await client.handle(
                    accountChange: event.cloudSaveAccountChange
                )
                try await restorePendingChangesAfterAccountChange(
                    event.cloudSaveAccountChange,
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
                await handleSentDatabaseChanges(event)
            case .willFetchChanges:
                beginRecoveryOperation(.fetching)
            case .willSendChanges:
                beginRecoveryOperation(.sending)
            case .didFetchChanges:
                completeRecoveryOperation(.fetching, syncEngine: syncEngine)
            case .didSendChanges:
                completeRecoveryOperation(.sending, syncEngine: syncEngine)
            case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
                break
            @unknown default:
                CloudSaveLogging.log(
                    level: .info,
                    "event | unknown"
                )
            }
        } catch {
            let failure = CloudSaveFailure(clientError: error)
            await reportAttentionRequiredFailure(failure)
            await rebuildAfterClientFailure(syncEngine: syncEngine)
            CloudSaveLogging.log(
                level: .error,
                "event | failure=\(failure)"
            )
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
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

// MARK: - Private

extension CloudSaveEngine {
    fileprivate func restorePendingChangesAfterAccountChange(
        _ accountChange: CloudSaveAccountChange,
        syncEngine: CKSyncEngine
    ) async throws {
        guard case .signedOut = accountChange else {
            let pendingChanges = try await client.pendingChanges()
            syncEngine.state.add(
                pendingDatabaseChanges: [.saveZone(configuration.zone)]
            )
            syncEngine.state.add(
                pendingRecordZoneChanges: pendingChanges.map(\.syncEngineChange)
            )
            publishReadyStatus(syncEngine: syncEngine)
            return
        }
    }

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
        syncEngine.state.add(
            pendingRecordZoneChanges: pendingChanges.map(\.syncEngineChange)
        )
    }

    fileprivate var syncEngine: CKSyncEngine {
        if let storedSyncEngine {
            return storedSyncEngine
        }

        var engineConfiguration = CKSyncEngine.Configuration(
            database: configuration.database,
            stateSerialization: lastPersistedStateSerialization,
            delegate: self
        )
        engineConfiguration.automaticallySync = configuration.automaticallySync
        engineConfiguration.subscriptionID = configuration.subscriptionID

        let engine = CKSyncEngine(engineConfiguration)
        storedSyncEngine = engine
        return engine
    }

    fileprivate func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges
    ) async {
        for failedSave in event.failedZoneSaves {
            await handleFailedZoneChange(failedSave.error)
        }

        for (_, error) in event.failedZoneDeletes {
            await handleFailedZoneChange(error)
        }
    }

    fileprivate func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async throws {
        try await client.didSave(records: event.savedRecords)
        try await client.didDelete(recordIDs: event.deletedRecordIDs)

        var changesToRetry: [CKSyncEngine.PendingRecordZoneChange] = []
        var zonesToRetry: [CKSyncEngine.PendingDatabaseChange] = []
        var didRequireAttention = false

        for failedSave in event.failedRecordSaves {
            let recordID = failedSave.record.recordID
            switch failedSave.error.code {
            case .serverRecordChanged:
                didRequireAttention =
                    try await handleConflict(
                        failedSave,
                        changesToRetry: &changesToRetry
                    ) || didRequireAttention
            case .zoneNotFound:
                try await client.clearServerRecord(for: recordID)
                zonesToRetry.append(.saveZone(configuration.zone))
                changesToRetry.append(.saveRecord(recordID))
            case .unknownItem:
                try await client.clearServerRecord(for: recordID)
                changesToRetry.append(.saveRecord(recordID))
            case .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable, .notAuthenticated,
                .operationCancelled, .requestRateLimited, .serviceUnavailable, .zoneBusy:
                break
            default:
                let failure = CloudSaveFailure(error: failedSave.error)
                await reportAttentionRequiredFailure(
                    failure,
                    recordID: recordID
                )
                didRequireAttention = true
            }
        }

        for (recordID, error) in event.failedRecordDeletes {
            switch error.code {
            case .unknownItem:
                try await client.didDelete(recordIDs: [recordID])
                syncEngine.state.remove(
                    pendingRecordZoneChanges: [.deleteRecord(recordID)]
                )
            default:
                if error.isTransientCloudSaveError {
                    continue
                }

                let failure = CloudSaveFailure(error: error)
                await reportAttentionRequiredFailure(
                    failure,
                    recordID: recordID
                )
                didRequireAttention = true
            }
        }

        syncEngine.state.add(pendingDatabaseChanges: zonesToRetry)
        syncEngine.state.add(pendingRecordZoneChanges: changesToRetry)
        if !didRequireAttention, unresolvedFailure == nil {
            publishReadyStatus(syncEngine: syncEngine)
        }
    }

    fileprivate func handleConflict(
        _ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        changesToRetry: inout [CKSyncEngine.PendingRecordZoneChange]
    ) async throws -> Bool {
        guard let serverRecord = failedSave.error.serverRecord else {
            await reportAttentionRequiredFailure(
                .recordConflict,
                recordID: failedSave.record.recordID
            )
            return true
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
            return false
        case .retry(let mergedRecord):
            try await client.persistResolvedRecord(mergedRecord)
            changesToRetry.append(.saveRecord(mergedRecord.recordID))
            return false
        case .requiresUserDecision:
            await reportAttentionRequiredFailure(
                .recordConflict,
                recordID: failedSave.record.recordID
            )
            return true
        }
    }

    /// Filters CloudKit fetches to the custom zone owned by this engine.
    fileprivate func isInConfiguredZone(_ record: CKRecord) -> Bool {
        isInConfiguredZone(record.recordID)
    }

    /// Filters CloudKit fetches to the custom zone owned by this engine.
    fileprivate func isInConfiguredZone(_ recordID: CKRecord.ID) -> Bool {
        recordID.zoneID == configuration.zone.zoneID
    }

    /// Filters custom-zone events to the zone owned by this engine.
    fileprivate func isInConfiguredZone(_ zoneID: CKRecordZone.ID) -> Bool {
        zoneID == configuration.zone.zoneID
    }

    /// Starts a fetch or send that can clear an earlier attention-required failure.
    fileprivate func beginRecoveryOperation(_ operation: RecoveryOperation) {
        if unresolvedFailure != nil {
            pendingRecoveryOperation = operation
            return
        }
        statusContinuation.yield(operation.status)
    }

    /// Clears an earlier failure only after its replacement operation completes successfully.
    fileprivate func completeRecoveryOperation(
        _ operation: RecoveryOperation,
        syncEngine: CKSyncEngine
    ) {
        guard pendingRecoveryOperation == operation else {
            if unresolvedFailure == nil {
                publishReadyStatus(syncEngine: syncEngine)
            }
            return
        }

        pendingRecoveryOperation = nil
        unresolvedFailure = nil
        publishReadyStatus(syncEngine: syncEngine)
    }

    /// Reports a durable failure while preserving it across completion events.
    fileprivate func reportAttentionRequiredFailure(
        _ failure: CloudSaveFailure,
        recordID: CKRecord.ID? = nil
    ) async {
        pendingRecoveryOperation = nil
        unresolvedFailure = failure
        statusContinuation.yield(.failed(failure))
        await client.handle(failure: failure, recordID: recordID)
    }

    /// Rebuilds the engine from its last durable checkpoint after a host write fails.
    fileprivate func rebuildAfterClientFailure(syncEngine: CKSyncEngine) async {
        await syncEngine.cancelOperations()
        storedSyncEngine = nil

        do {
            try await start()
        } catch {
            CloudSaveLogging.log(
                level: .error,
                "rebuild | failure=\(CloudSaveFailure(error: error))"
            )
        }
    }

    /// Handles a zone change failure according to CKSyncEngine's retry policy.
    fileprivate func handleFailedZoneChange(_ error: CKError) async {
        guard !error.isTransientCloudSaveError else {
            return
        }

        let failure = CloudSaveFailure(error: error)
        await reportAttentionRequiredFailure(failure)
        CloudSaveLogging.log(
            level: .error,
            "zone change | failure=\(failure)"
        )
    }

    fileprivate func publishReadyStatus(syncEngine: CKSyncEngine) {
        guard unresolvedFailure == nil else {
            return
        }

        statusContinuation.yield(
            .ready(
                hasPendingChanges: !syncEngine.state.pendingRecordZoneChanges.isEmpty
            )
        )
    }
}

/// Identifies the synchronization operation that may resolve a previous failure.
private enum RecoveryOperation: Equatable {
    /// Fetches remote CloudKit changes.
    case fetching

    /// Sends locally durable CloudKit changes.
    case sending

    /// The public status reported while this operation is in progress.
    var status: CloudSaveStatus {
        switch self {
        case .fetching:
            .fetching
        case .sending:
            .sending
        }
    }
}

extension CloudSavePendingChange {
    fileprivate var syncEngineChange: CKSyncEngine.PendingRecordZoneChange {
        switch self {
        case .save(let recordID):
            .saveRecord(recordID)
        case .delete(let recordID):
            .deleteRecord(recordID)
        }
    }
}

extension CKSyncEngine.Event.AccountChange {
    fileprivate var cloudSaveAccountChange: CloudSaveAccountChange {
        switch changeType {
        case .signIn(let currentUser):
            .signedIn(
                currentAccountID: currentUser.recordName
            )
        case .signOut(let previousUser):
            .signedOut(
                previousAccountID: previousUser.recordName
            )
        case .switchAccounts(let previousUser, let currentUser):
            .switched(
                previousAccountID: previousUser.recordName,
                currentAccountID: currentUser.recordName
            )
        @unknown default:
            .signedOut(previousAccountID: "unknown")
        }
    }
}

extension CKError {
    /// Whether CKSyncEngine can retry this CloudKit error without application attention.
    fileprivate var isTransientCloudSaveError: Bool {
        switch code {
        case .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable,
            .notAuthenticated, .operationCancelled, .requestRateLimited,
            .serviceUnavailable, .zoneBusy:
            true
        default:
            false
        }
    }
}
