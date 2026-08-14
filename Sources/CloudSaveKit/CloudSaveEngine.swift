import CloudKit
import Foundation

/// Synchronizes an application's durable local records with a private CloudKit database.
public final actor CloudSaveEngine {
    /// A stream that retains the latest unconsumed privacy-safe synchronization status.
    public nonisolated let statusUpdates: AsyncStream<CloudSaveStatus>

    private let client: any CloudSaveClient
    private let configuration: CloudSaveConfiguration
    private let eventHandlingLock = CloudSaveAsyncLock()
    private let ledgerPersistenceLock = CloudSaveAsyncLock()
    private let statePersistenceLock = CloudSaveAsyncLock()
    private let statusContinuation: AsyncStream<CloudSaveStatus>.Continuation
    private var isAccountTransitionPending = false
    private var isHostFailureInvalidationPending = false
    private var lastPersistedStateSerialization: CKSyncEngine.State.Serialization?
    private var ledgerSnapshotTracker = CloudSaveLedgerSnapshotTracker()
    private var lifecycleTransitionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var lifecycleGeneration = 0
    private var needsAccountTransitionLedgerRefresh = false
    private var stateMachine = CloudSaveStateMachine()
    private var storedSyncEngine: CKSyncEngine?

    /// Creates an engine without starting synchronization.
    public init(
        configuration: CloudSaveConfiguration,
        client: any CloudSaveClient
    ) {
        let statusChannel = CloudSaveStatusChannel()
        statusUpdates = statusChannel.stream
        statusContinuation = statusChannel.continuation
        self.client = client
        self.configuration = configuration
        lastPersistedStateSerialization = configuration.stateSerialization
    }

    deinit {
        statusContinuation.finish()
    }

    /// Initializes CKSyncEngine and restores every locally durable pending change.
    public func start() async throws {
        try await waitForPendingLifecycleTransition()

        let startingLifecycleGeneration = lifecycleGeneration
        let ledgerSnapshot: CloudSavePendingChangesSnapshot
        do {
            ledgerSnapshot = try await readPendingChangesSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CKError where error.code == .operationCancelled {
            throw error
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

        guard
            restoreDurablePendingChanges(
                ledgerSnapshot,
                syncEngine: engine
            )
        else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }
        publishStatus(syncEngine: engine)
        CloudSaveLogging.log(
            "start | pending=\(ledgerSnapshot.durableChanges.count)"
        )
    }

    /// Adds locally durable changes to CKSyncEngine's pending state.
    public func enqueue(_ changes: [CloudSavePendingChange]) {
        let configuredChanges = changes.filter {
            isInConfiguredZone($0.recordID)
        }
        guard !configuredChanges.isEmpty else {
            return
        }

        guard !isAccountTransitionPending else {
            needsAccountTransitionLedgerRefresh = true
            CloudSaveLogging.log(
                level: .error,
                "enqueue | ignored during account transition"
            )
            return
        }

        ledgerSnapshotTracker.recordEnqueues(configuredChanges)

        guard !isLifecycleTransitionPending,
            !stateMachine.requiresHostRecovery
        else {
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

        storedSyncEngine.state.add(
            pendingRecordZoneChanges: configuredChanges.map(\.syncEngineChange)
        )
        publishStatus(syncEngine: storedSyncEngine)
        CloudSaveLogging.log("enqueue | count=\(configuredChanges.count)")
    }

    /// Immediately fetches changes for the configured save zone.
    public func fetchNow() async throws {
        try await waitForPendingLifecycleTransition()

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
        try await waitForPendingLifecycleTransition()

        let session = try operationalSyncEngine()
        let ledgerSnapshot: CloudSavePendingChangesSnapshot

        do {
            ledgerSnapshot = try await readPendingChangesSnapshot()
        } catch is CancellationError {
            try throwRecoveryErrorIfNeeded(for: session)
            throw CancellationError()
        } catch let error as CKError where error.code == .operationCancelled {
            try throwRecoveryErrorIfNeeded(for: session)
            throw error
        } catch {
            try throwRecoveryErrorIfNeeded(for: session)
            await handleHostFailure(
                error,
                syncEngine: session.syncEngine
            )
            throw error
        }

        try validate(session)
        guard
            restoreDurablePendingChanges(
                ledgerSnapshot,
                syncEngine: session.syncEngine
            )
        else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }
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
        await eventHandlingLock.withLock { [self] in
            await handleEventInOrder(
                event,
                syncEngine: syncEngine
            )
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !isLifecycleTransitionPending,
            storedSyncEngine === syncEngine,
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
        let batchLifecycleGeneration = lifecycleGeneration

        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges
        ) { [client, weak self] recordID in
            do {
                let record = try await client.record(for: recordID)
                guard
                    await self?.isActive(
                        syncEngine: syncEngine,
                        lifecycleGeneration: batchLifecycleGeneration
                    ) == true
                else {
                    return nil
                }

                if record == nil {
                    await self?.reconcileUnavailablePendingSave(
                        recordID,
                        syncEngine: syncEngine
                    )
                }
                return record
            } catch {
                await self?.handleRecordMaterializationFailure(
                    error,
                    syncEngine: syncEngine,
                    lifecycleGeneration: batchLifecycleGeneration
                )
                return nil
            }
        }
        guard
            isActive(
                syncEngine: syncEngine,
                lifecycleGeneration: batchLifecycleGeneration
            )
        else {
            return nil
        }

        return batch
    }
}

// MARK: - Private Ordered Events

extension CloudSaveEngine {
    /// Processes one CKSyncEngine event without allowing later events to overtake its host writes.
    fileprivate func handleEventInOrder(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        guard !isLifecycleTransitionPending,
            storedSyncEngine === syncEngine
        else {
            CloudSaveLogging.log("event | ignored stale engine")
            return
        }

        do {
            switch event {
            case .stateUpdate(let event):
                try await persistStateUpdate(
                    event,
                    syncEngine: syncEngine
                )
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
                let fetchedRecords = event.modifications.map(\.record).filter(isInConfiguredZone)
                let deletedRecordIDs = event.deletions.map(\.recordID).filter(isInConfiguredZone)
                try await commitPendingChangesMutation { [client] in
                    try await client.applyFetchedChanges(
                        records: fetchedRecords,
                        deletedRecordIDs: deletedRecordIDs
                    )
                }
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
}

// MARK: - Private Lifecycle

extension CloudSaveEngine {
    /// Whether account-scoped persistence or failed-engine shutdown blocks new work.
    fileprivate var isLifecycleTransitionPending: Bool {
        isAccountTransitionPending || isHostFailureInvalidationPending
    }

    /// Returns whether asynchronous work still belongs to the active engine lifecycle.
    fileprivate func isActive(
        syncEngine: CKSyncEngine,
        lifecycleGeneration: Int
    ) -> Bool {
        !isLifecycleTransitionPending
            && self.lifecycleGeneration == lifecycleGeneration
            && storedSyncEngine === syncEngine
            && !stateMachine.requiresHostRecovery
    }

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
        guard !isLifecycleTransitionPending,
            !stateMachine.requiresHostRecovery
        else {
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
        guard !isLifecycleTransitionPending,
            session.lifecycleGeneration == lifecycleGeneration,
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
            isLifecycleTransitionPending
                || session.lifecycleGeneration != lifecycleGeneration
                || storedSyncEngine !== session.syncEngine
                || stateMachine.requiresHostRecovery
        else {
            return
        }

        throw CloudSaveEngineError.hostRecoveryRequired
    }

    /// Blocks new work as soon as a host failure is observed.
    fileprivate func beginHostFailureInvalidation(
        _ failure: CloudSaveFailure,
        syncEngine: CKSyncEngine?
    ) -> (
        lifecycleGeneration: Int,
        engineToCancel: CKSyncEngine?
    )? {
        guard syncEngine == nil || storedSyncEngine === syncEngine else {
            return nil
        }

        guard !isHostFailureInvalidationPending else {
            return nil
        }

        let engineToCancel = syncEngine ?? storedSyncEngine
        isHostFailureInvalidationPending = true
        isAccountTransitionPending = false
        needsAccountTransitionLedgerRefresh = false
        lifecycleGeneration &+= 1
        stateMachine.fail(
            failure,
            context: .hostPersistence
        )
        stateMachine.resetActiveOperations()
        publishStatus(syncEngine: engineToCancel)
        return (
            lifecycleGeneration: lifecycleGeneration,
            engineToCancel: engineToCancel
        )
    }

    /// Detaches the failed engine after every earlier checkpoint write completes.
    fileprivate func finishHostFailureInvalidation(
        _ failure: CloudSaveFailure,
        lifecycleGeneration: Int,
        syncEngine: CKSyncEngine?
    ) -> Bool {
        guard isHostFailureInvalidationPending else {
            return false
        }

        guard self.lifecycleGeneration == lifecycleGeneration,
            storedSyncEngine === syncEngine
        else {
            CloudSaveLogging.log("host failure | ignored superseded invalidation")
            endHostFailureInvalidation()
            return false
        }

        stateMachine.fail(
            failure,
            context: .hostPersistence
        )
        storedSyncEngine = nil
        publishStatus(syncEngine: syncEngine)
        return true
    }

    /// Prevents explicit recovery from overtaking account changes or failed-engine shutdown.
    fileprivate func waitForPendingLifecycleTransition() async throws {
        try Task.checkCancellation()
        guard isLifecycleTransitionPending else {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard isLifecycleTransitionPending else {
                    continuation.resume()
                    return
                }

                lifecycleTransitionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelLifecycleTransitionWaiter(waiterID)
            }
        }
    }

    /// Removes and cancels one operation waiting for a lifecycle transition.
    fileprivate func cancelLifecycleTransitionWaiter(_ waiterID: UUID) {
        lifecycleTransitionWaiters.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError()
        )
    }

    /// Releases explicit recovery only after the failed engine has stopped.
    fileprivate func endHostFailureInvalidation() {
        isHostFailureInvalidationPending = false
        resumeLifecycleTransitionWaitersIfReady()
    }

    /// Releases blocked work after the new account's durable ledger has been restored.
    fileprivate func endAccountTransition() {
        isAccountTransitionPending = false
        resumeLifecycleTransitionWaitersIfReady()
    }

    /// Resumes lifecycle waiters only when no transition can expose scoped data.
    fileprivate func resumeLifecycleTransitionWaitersIfReady() {
        guard !isLifecycleTransitionPending else {
            return
        }

        let waiters = Array(lifecycleTransitionWaiters.values)
        lifecycleTransitionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - Private Host Persistence

extension CloudSaveEngine {
    /// Reads the host ledger while retaining every mutation that can race with its snapshot.
    fileprivate func readPendingChangesSnapshot() async throws -> CloudSavePendingChangesSnapshot {
        while true {
            try Task.checkCancellation()
            let snapshot = ledgerSnapshotTracker.beginSnapshot()
            let snapshotLifecycleGeneration = lifecycleGeneration

            do {
                let durableChanges = try await ledgerPersistenceLock.withLock { [client] in
                    try await client.pendingChanges()
                }
                guard
                    let subsequentMutations = ledgerSnapshotTracker.completeSnapshot(snapshot)
                else {
                    continue
                }

                return CloudSavePendingChangesSnapshot(
                    lifecycleGeneration: snapshotLifecycleGeneration,
                    ledgerGeneration: ledgerSnapshotTracker.currentGeneration,
                    durableChanges: durableChanges,
                    subsequentMutations: subsequentMutations
                )
            } catch {
                ledgerSnapshotTracker.cancelSnapshot(snapshot)
                throw error
            }
        }
    }

    /// Serializes a host ledger mutation and invalidates snapshots from before its commit.
    fileprivate func commitPendingChangesMutation<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        ledgerSnapshotTracker.invalidateSnapshotsForHostMutation()
        return try await ledgerPersistenceLock.withLock(operation)
    }

    /// Persists an opaque state update before accepting it as the next recovery checkpoint.
    fileprivate func persistStateUpdate(
        _ event: CKSyncEngine.Event.StateUpdate,
        syncEngine: CKSyncEngine
    ) async throws {
        try await statePersistenceLock.withLock { [self] in
            try await persistStateUpdateInOrder(
                event,
                syncEngine: syncEngine
            )
        }
    }

    /// Writes a checkpoint only while its originating engine remains active.
    fileprivate func persistStateUpdateInOrder(
        _ event: CKSyncEngine.Event.StateUpdate,
        syncEngine: CKSyncEngine
    ) async throws {
        guard storedSyncEngine === syncEngine else {
            return
        }

        try await client.persist(
            stateSerialization: event.stateSerialization
        )

        guard storedSyncEngine === syncEngine else {
            return
        }

        lastPersistedStateSerialization = event.stateSerialization
    }

    /// Reconciles CKSyncEngine's tracked changes with the host's authoritative durable ledger.
    fileprivate func restoreDurablePendingChanges(
        _ snapshot: CloudSavePendingChangesSnapshot,
        syncEngine: CKSyncEngine,
        allowsAccountTransition: Bool = false
    ) -> Bool {
        guard
            isCurrent(
                snapshot,
                syncEngine: syncEngine,
                allowsAccountTransition: allowsAccountTransition
            )
        else {
            CloudSaveLogging.log("ledger snapshot | ignored stale lifecycle")
            return false
        }

        let configuredDurableChanges = snapshot.durableChanges.filter {
            isInConfiguredZone($0.recordID)
        }
        let configuredSubsequentMutations = snapshot.subsequentMutations.filter(
            isInConfiguredZone
        )
        let durableChanges = configuredDurableChanges.map(\.syncEngineChange)
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
        var effectiveChanges: [CKRecord.ID: CloudSavePendingChange] = [:]
        for change in configuredDurableChanges {
            effectiveChanges[change.recordID] = change
        }
        for mutation in configuredSubsequentMutations {
            switch mutation {
            case .enqueue(let change):
                syncEngine.state.add(
                    pendingRecordZoneChanges: [change.syncEngineChange]
                )
                effectiveChanges[change.recordID] = change
            case .remove(let change):
                syncEngine.state.remove(
                    pendingRecordZoneChanges: [change.syncEngineChange]
                )
                if effectiveChanges[change.recordID] == change {
                    effectiveChanges[change.recordID] = nil
                }
            }
        }
        stateMachine.reconcilePendingRecordIDs(
            Set(effectiveChanges.keys),
            in: configuration.zone.zoneID
        )
        return true
    }

    /// Reconciles successful work against the host ledger without discarding a newer mutation.
    fileprivate func reconcileAcknowledgedPendingChanges(
        _ acknowledgedChanges: [CloudSavePendingChange],
        syncEngine: CKSyncEngine
    ) async throws {
        guard
            try await reconcilePendingChangesAgainstHostLedger(
                acknowledgedChanges,
                syncEngine: syncEngine
            ) != nil
        else {
            return
        }

        stateMachine.resolve(recordIDs: acknowledgedChanges.map(\.recordID))
        publishStatus(syncEngine: syncEngine)
    }

    /// Reconciles candidate removals against the current durable ledger and lifecycle.
    fileprivate func reconcilePendingChangesAgainstHostLedger(
        _ candidateChanges: [CloudSavePendingChange],
        syncEngine: CKSyncEngine
    ) async throws -> [CloudSavePendingChange]? {
        let snapshot = try await readPendingChangesSnapshot()
        guard isCurrent(snapshot, syncEngine: syncEngine) else {
            CloudSaveLogging.log("ledger reconciliation | ignored stale lifecycle")
            return nil
        }

        let completedChanges = candidateChanges.filter {
            !snapshot.containsEffectiveChange($0)
        }

        ledgerSnapshotTracker.recordRemovals(completedChanges)
        guard restoreDurablePendingChanges(snapshot, syncEngine: syncEngine) else {
            return nil
        }

        return completedChanges
    }

    /// Reconciles a nil record-provider result without discarding a newer durable save.
    fileprivate func reconcileUnavailablePendingSave(
        _ recordID: CKRecord.ID,
        syncEngine: CKSyncEngine
    ) async {
        do {
            guard
                let completedChanges = try await reconcilePendingChangesAgainstHostLedger(
                    [.save(recordID)],
                    syncEngine: syncEngine
                )
            else {
                return
            }

            stateMachine.resolve(recordIDs: completedChanges.map(\.recordID))
            publishStatus(syncEngine: syncEngine)
        } catch {
            await handleHostFailure(
                error,
                syncEngine: syncEngine
            )
        }
    }

    /// Stops the active engine when its host cannot materialize a pending record.
    fileprivate func handleRecordMaterializationFailure(
        _ error: any Error,
        syncEngine: CKSyncEngine,
        lifecycleGeneration: Int
    ) {
        guard
            isActive(
                syncEngine: syncEngine,
                lifecycleGeneration: lifecycleGeneration
            )
        else {
            return
        }

        let failure = CloudSaveFailure(clientError: error)
        guard
            let invalidation = beginHostFailureInvalidation(
                failure,
                syncEngine: syncEngine
            )
        else {
            return
        }

        Task { [weak self] in
            await self?.completeHostFailureInvalidation(
                failure,
                lifecycleGeneration: invalidation.lifecycleGeneration,
                engineToCancel: invalidation.engineToCancel
            )
        }
    }

    /// Returns whether a host-ledger snapshot still belongs to the active engine lifecycle.
    fileprivate func isCurrent(
        _ snapshot: CloudSavePendingChangesSnapshot,
        syncEngine: CKSyncEngine,
        allowsAccountTransition: Bool = false
    ) -> Bool {
        !isHostFailureInvalidationPending
            && (allowsAccountTransition || !isAccountTransitionPending)
            && snapshot.belongs(
                to: lifecycleGeneration,
                ledgerGeneration: ledgerSnapshotTracker.currentGeneration
            )
            && storedSyncEngine === syncEngine
            && !stateMachine.requiresHostRecovery
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
        stateMachine.resetForAccountChange()

        guard case .signedOut = accountChange else {
            let ledgerSnapshot = try await readPendingChangesSnapshot()
            syncEngine.state.add(
                pendingDatabaseChanges: [.saveZone(configuration.zone)]
            )
            guard
                restoreDurablePendingChanges(
                    ledgerSnapshot,
                    syncEngine: syncEngine,
                    allowsAccountTransition: true
                )
            else {
                throw CloudSaveEngineError.hostRecoveryRequired
            }
            publishStatus(syncEngine: syncEngine)
            return
        }

        publishStatus(syncEngine: nil)
    }

    /// Reloads the new account's durable ledger when enqueues were blocked during its transition.
    fileprivate func refreshPendingChangesAfterAccountTransitionIfNeeded(
        _ accountChange: CloudSaveAccountChange,
        syncEngine: CKSyncEngine
    ) async throws {
        if case .signedOut = accountChange {
            needsAccountTransitionLedgerRefresh = false
            return
        }

        while needsAccountTransitionLedgerRefresh {
            needsAccountTransitionLedgerRefresh = false
            let ledgerSnapshot = try await readPendingChangesSnapshot()
            guard
                restoreDurablePendingChanges(
                    ledgerSnapshot,
                    syncEngine: syncEngine,
                    allowsAccountTransition: true
                )
            else {
                throw CloudSaveEngineError.hostRecoveryRequired
            }
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

        try await commitPendingChangesMutation { [client] in
            try await client.applyDeletedZones(configuredZoneIDs)
        }
        let ledgerSnapshot = try await readPendingChangesSnapshot()
        syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(configuration.zone)]
        )
        guard
            restoreDurablePendingChanges(
                ledgerSnapshot,
                syncEngine: syncEngine
            )
        else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }
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

        isAccountTransitionPending = true
        needsAccountTransitionLedgerRefresh = false
        lifecycleGeneration &+= 1
        let accountLifecycleGeneration = lifecycleGeneration
        try await commitPendingChangesMutation { [client] in
            try await client.handle(accountChange: accountChange)
        }
        guard lifecycleGeneration == accountLifecycleGeneration,
            isAccountTransitionPending,
            !isHostFailureInvalidationPending,
            !stateMachine.requiresHostRecovery,
            storedSyncEngine === syncEngine
        else {
            throw CloudSaveEngineError.hostRecoveryRequired
        }
        try await restorePendingChangesAfterAccountChange(
            accountChange,
            syncEngine: syncEngine
        )
        try await refreshPendingChangesAfterAccountTransitionIfNeeded(
            accountChange,
            syncEngine: syncEngine
        )
        endAccountTransition()
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

        try await commitPendingChangesMutation { [client] in
            try await client.didSave(records: savedRecords)
        }
        try await reconcileAcknowledgedPendingChanges(
            savedRecords.map { .save($0.recordID) },
            syncEngine: syncEngine
        )
        try await commitPendingChangesMutation { [client] in
            try await client.didDelete(recordIDs: deletedRecordIDs)
        }
        try await reconcileAcknowledgedPendingChanges(
            deletedRecordIDs.map(CloudSavePendingChange.delete),
            syncEngine: syncEngine
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
                try await commitPendingChangesMutation { [client] in
                    try await client.didDelete(recordIDs: [recordID])
                }
                try await reconcileAcknowledgedPendingChanges(
                    [.delete(recordID)],
                    syncEngine: syncEngine
                )
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
            try await commitPendingChangesMutation { [client] in
                try await client.applyFetchedChanges(
                    records: [serverRecord],
                    deletedRecordIDs: []
                )
            }
            try await reconcileAcknowledgedPendingChanges(
                [.save(recordID)],
                syncEngine: syncEngine
            )
        case .retry(let mergedRecord):
            try await commitPendingChangesMutation { [client] in
                try await client.persistResolvedRecord(mergedRecord)
            }
            ledgerSnapshotTracker.recordEnqueues([.save(mergedRecord.recordID)])
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
        guard
            let invalidation = beginHostFailureInvalidation(
                failure,
                syncEngine: syncEngine
            )
        else {
            return
        }

        await completeHostFailureInvalidation(
            failure,
            lifecycleGeneration: invalidation.lifecycleGeneration,
            engineToCancel: invalidation.engineToCancel
        )
    }

    /// Completes failed-engine checkpoint ordering, cancellation, and host notification.
    fileprivate func completeHostFailureInvalidation(
        _ failure: CloudSaveFailure,
        lifecycleGeneration: Int,
        engineToCancel: CKSyncEngine?
    ) async {
        let didFinish = await statePersistenceLock.withLock { [self] in
            await finishHostFailureInvalidation(
                failure,
                lifecycleGeneration: lifecycleGeneration,
                syncEngine: engineToCancel
            )
        }
        guard didFinish else {
            return
        }

        await engineToCancel?.cancelOperations()
        endHostFailureInvalidation()
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

    /// Filters host-ledger mutations to the custom zone owned by this engine.
    fileprivate func isInConfiguredZone(_ mutation: CloudSaveLedgerMutation) -> Bool {
        switch mutation {
        case .enqueue(let change):
            isInConfiguredZone(change.recordID)
        case .remove(let change):
            isInConfiguredZone(change.recordID)
        }
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
