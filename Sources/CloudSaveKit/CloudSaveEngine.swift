import CloudKit
import Foundation

/// Synchronizes an application's durable local records with a private CloudKit database.
public final actor CloudSaveEngine {
    /// A stream of privacy-safe synchronization status updates.
    public nonisolated let statusUpdates: AsyncStream<CloudSaveStatus>

    private let client: any CloudSaveClient
    private let configuration: CloudSaveConfiguration
    private let statusContinuation: AsyncStream<CloudSaveStatus>.Continuation
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
        } catch {
            let failure = CloudSaveFailure(error: error)
            statusContinuation.yield(.failed(failure))
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
        } catch {
            let failure = CloudSaveFailure(error: error)
            statusContinuation.yield(.failed(failure))
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
        do {
            switch event {
            case .stateUpdate(let event):
                try await client.persist(
                    stateSerialization: event.stateSerialization
                )
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
                    event.deletions.map(\.zoneID),
                    syncEngine: syncEngine
                )
            case .fetchedRecordZoneChanges(let event):
                try await client.applyFetchedChanges(
                    records: event.modifications.map(\.record),
                    deletedRecordIDs: event.deletions.map(\.recordID)
                )
            case .sentRecordZoneChanges(let event):
                try await handleSentRecordZoneChanges(
                    event,
                    syncEngine: syncEngine
                )
            case .sentDatabaseChanges(let event):
                handleSentDatabaseChanges(
                    event,
                    syncEngine: syncEngine
                )
            case .willFetchChanges:
                statusContinuation.yield(.fetching)
            case .willSendChanges:
                statusContinuation.yield(.sending)
            case .didFetchChanges, .didSendChanges:
                publishReadyStatus(syncEngine: syncEngine)
            case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
                break
            @unknown default:
                CloudSaveLogging.log(
                    level: .info,
                    "event | unknown"
                )
            }
        } catch {
            let failure = CloudSaveFailure(error: error)
            statusContinuation.yield(.failed(failure))
            await client.handle(
                failure: failure,
                recordID: nil
            )
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
        try await client.applyDeletedZones(zoneIDs)
        guard zoneIDs.contains(configuration.zone.zoneID) else {
            return
        }

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
            stateSerialization: configuration.stateSerialization,
            delegate: self
        )
        engineConfiguration.automaticallySync = configuration.automaticallySync
        engineConfiguration.subscriptionID = configuration.subscriptionID

        let engine = CKSyncEngine(engineConfiguration)
        storedSyncEngine = engine
        return engine
    }

    fileprivate func handleSentDatabaseChanges(
        _ event: CKSyncEngine.Event.SentDatabaseChanges,
        syncEngine: CKSyncEngine
    ) {
        var didFail = false
        for failedSave in event.failedZoneSaves {
            let failure = CloudSaveFailure(error: failedSave.error)
            statusContinuation.yield(.failed(failure))
            didFail = true
        }

        for (_, error) in event.failedZoneDeletes {
            let failure = CloudSaveFailure(error: error)
            statusContinuation.yield(.failed(failure))
            didFail = true
            CloudSaveLogging.log(
                level: .error,
                "zone delete | failure=\(failure)"
            )
        }

        if !didFail {
            publishReadyStatus(syncEngine: syncEngine)
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
                await client.handle(
                    failure: failure,
                    recordID: recordID
                )
                statusContinuation.yield(.failed(failure))
                didRequireAttention = true
            }
        }

        for (recordID, error) in event.failedRecordDeletes {
            let failure = CloudSaveFailure(error: error)
            await client.handle(
                failure: failure,
                recordID: recordID
            )
            statusContinuation.yield(.failed(failure))
            didRequireAttention = true
        }

        syncEngine.state.add(pendingDatabaseChanges: zonesToRetry)
        syncEngine.state.add(pendingRecordZoneChanges: changesToRetry)
        if !didRequireAttention {
            publishReadyStatus(syncEngine: syncEngine)
        }
    }

    fileprivate func handleConflict(
        _ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        changesToRetry: inout [CKSyncEngine.PendingRecordZoneChange]
    ) async throws -> Bool {
        guard let serverRecord = failedSave.error.serverRecord else {
            await client.handle(
                failure: .recordConflict,
                recordID: failedSave.record.recordID
            )
            statusContinuation.yield(.failed(.recordConflict))
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
            await client.handle(
                failure: .recordConflict,
                recordID: failedSave.record.recordID
            )
            statusContinuation.yield(.failed(.recordConflict))
            return true
        }
    }

    fileprivate func publishReadyStatus(syncEngine: CKSyncEngine) {
        statusContinuation.yield(
            .ready(
                hasPendingChanges: !syncEngine.state.pendingRecordZoneChanges.isEmpty
            )
        )
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
