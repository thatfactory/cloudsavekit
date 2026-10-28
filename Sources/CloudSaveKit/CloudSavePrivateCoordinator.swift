public import CloudKit
import Foundation

/// Owns account verification and conditional private-manifest provisioning for one container.
public actor CloudSavePrivateCoordinator {
    /// One consumer observes invalidation before clearing its visible account-scoped state.
    public nonisolated let accountEvents: AsyncStream<CloudSaveAccountEvent>
    private let continuation: AsyncStream<CloudSaveAccountEvent>.Continuation
    private let coordinatorID = UUID()
    private let transport: any CloudSavePrivateTransport
    private let database: CKDatabase?
    private let changes: AsyncStream<Void>
    private let notifications: CloudSaveAccountNotifications?
    private let requests: CloudSavePrivateRequestGate
    private var monitor: Task<Void, Never>?
    private var accountGate = CloudSaveAccessGate()
    private var generation = UUID()
    private var verifiedAccount: CloudSaveVerifiedAccount?
    private var refresh: (id: UUID, task: Task<CloudSaveAccountSnapshot, any Error>)?
    private var bootstraps: [BootstrapKey: Task<CKRecord, any Error>] = [:]
    private var sessions: [WeakSession] = []

    /// Creates the container and registers account observation before any cloud work can start.
    public init(containerIdentifier: String) {
        let transport = CloudSaveCloudKitTransport(containerIdentifier: containerIdentifier)
        let notifications = CloudSaveAccountNotifications()
        self.transport = transport
        database = transport.database
        self.notifications = notifications
        changes = notifications.changes
        requests = CloudSavePrivateRequestGate()
        let channel = AsyncStream<CloudSaveAccountEvent>.makeStream()
        accountEvents = channel.stream
        continuation = channel.continuation
    }

    /// Injects account events and exact transport operations without requiring CloudKit entitlements.
    init(
        transport: any CloudSavePrivateTransport,
        changes: AsyncStream<Void> = AsyncStream { $0.finish() },
        requests: CloudSavePrivateRequestGate = CloudSavePrivateRequestGate()
    ) {
        self.transport = transport
        self.changes = changes
        self.requests = requests
        database = nil
        notifications = nil
        let channel = AsyncStream<CloudSaveAccountEvent>.makeStream()
        accountEvents = channel.stream
        continuation = channel.continuation
    }

    deinit {
        accountGate.close()
        monitor?.cancel()
        refresh?.task.cancel()
        for task in bootstraps.values {
            task.cancel()
        }
        continuation.finish()
    }

    /// Starts the account-event consumer idempotently; notification registration already exists.
    public func startMonitoring() {
        guard monitor == nil else {
            return
        }
        monitor = Task { [weak self, changes] in
            for await _ in changes {
                guard !Task.isCancelled else {
                    break
                }
                await self?.accountDidChange()
            }
        }
    }

    /// Revalidates the foreground system context, coalescing overlapping callers.
    /// Every new reconciliation invalidates previous account tokens before its first suspension.
    public func refreshAccount() async throws -> CloudSaveAccountSnapshot {
        startMonitoring()
        let work = refresh ?? startRefresh()
        defer { if refresh?.id == work.id { refresh = nil } }
        let snapshot = try await work.task.value
        guard generation == work.id else {
            throw CloudSavePrivateError.sessionInvalidated
        }
        try Task.checkCancellation()
        return snapshot
    }

    /// Reads or conditionally creates an exact manifest and returns only the canonical server identity.
    public func bootstrapManifest<Value: Sendable & Equatable>(
        for account: CloudSaveVerifiedAccount,
        zoneName: String,
        recordType: String,
        recordName: String,
        expectedIdentity: Value?,
        makeInitialRecord: @escaping @Sendable (CKRecord.ID) throws -> CKRecord,
        decodeIdentity: @Sendable (CKRecord) throws -> Value
    ) async throws -> CloudSavePrivateBootstrap<Value> {
        try validate(account)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: CKRecordZone.ID(zoneName: zoneName))
        let key = BootstrapKey(
            generation: account.generation, recordID: recordID,
            recordType: recordType, permitsCreation: expectedIdentity == nil
        )
        let ownsWork = bootstraps[key] == nil
        let task: Task<CKRecord, any Error>
        if let existing = bootstraps[key] {
            task = existing
        } else {
            let gate = accountGate
            task = Task {
                try await self.canonicalManifest(
                    key: key, gate: gate, makeInitialRecord: makeInitialRecord
                )
            }
            bootstraps[key] = task
        }
        defer { if ownsWork { bootstraps[key] = nil } }
        do {
            let record = try await task.value
            try Task.checkCancellation()
            try validate(account)
            guard record.recordType == recordType, record.recordID == recordID else {
                throw CloudSavePrivateError.malformedManifest
            }
            let identity: Value
            do { identity = try decodeIdentity(record) } catch { throw CloudSavePrivateError.malformedManifest }
            if let expectedIdentity, expectedIdentity != identity {
                throw CloudSavePrivateError.manifestIdentityMismatch
            }
            CloudSavePrivateLogging.emit(.bootstrap, .verified)
            return CloudSavePrivateBootstrap(
                account: account, zoneID: recordID.zoneID, value: identity, manifestRecordID: recordID
            )
        } catch {
            let failure = CloudSavePrivateError.normalize(error)
            if failure as? CloudSavePrivateError == .accountTemporarilyUnavailable {
                suspendAccount()
            }
            CloudSavePrivateLogging.emit(.bootstrap, CloudSavePrivateLogging.outcome(failure))
            throw failure
        }
    }

    /// Creates an immutable account/zone/client session; no live CloudKit service escapes to the host.
    public func makeSession<Value: Sendable>(
        for bootstrap: CloudSavePrivateBootstrap<Value>,
        stateSerialization: CKSyncEngine.State.Serialization?,
        client: any CloudSaveClient,
        automaticallySync: Bool = true
    ) throws -> CloudSavePrivateSession {
        try validate(bootstrap.account)
        guard let database else {
            throw CloudSavePrivateError.transport(.configuration, retryAfterSeconds: nil)
        }
        let session = CloudSavePrivateSession(
            account: bootstrap.account, accountGate: accountGate,
            zoneID: bootstrap.zoneID, manifestRecordID: bootstrap.manifestRecordID,
            database: database, stateSerialization: stateSerialization, client: client,
            automaticallySync: automaticallySync, transport: transport, requests: requests,
            onInvalidation: { [weak self] reason in
                await self?.sessionInvalidated(reason, generation: bootstrap.account.generation)
            }
        )
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(value: session))
        return session
    }

    // MARK: - Private

    /// Rejects tokens from other coordinators or an invalidated account generation.
    private func validate(_ account: CloudSaveVerifiedAccount) throws {
        try accountGate.check()
        guard account.coordinatorID == coordinatorID, account.generation == generation,
            account == verifiedAccount
        else { throw CloudSavePrivateError.sessionInvalidated }
    }

    /// Fences every old session synchronously and publishes invalidation before cancellation awaits.
    private func beginRevalidation() {
        accountGate.close()
        generation = UUID()
        accountGate = CloudSaveAccessGate()
        verifiedAccount = nil
        for task in bootstraps.values {
            task.cancel()
        }
        bootstraps.removeAll()
        let oldSessions = sessions.compactMap(\.value)
        sessions.removeAll()
        continuation.yield(.invalidated)
        CloudSavePrivateLogging.emit(.account, .invalidated)
        Task { for session in oldSessions { await session.invalidate() } }
    }

    /// Resolves availability and identity only in the generation that initiated the request.
    private func resolveAccount(generation identifier: UUID) async throws -> CloudSaveAccountSnapshot {
        guard generation == identifier else {
            throw CloudSavePrivateError.sessionInvalidated
        }
        let gate = accountGate
        do {
            let status = try await requests.perform(
                validate: { try gate.check() },
                operation: {
                    try await self.transport.accountStatus()
                })
            let snapshot: CloudSaveAccountSnapshot
            switch status {
            case .available:
                let recordID = try await requests.perform(
                    validate: { try gate.check() },
                    operation: {
                        try await self.transport.userRecordID()
                    })
                guard !recordID.recordName.isEmpty else {
                    throw CloudSavePrivateError.sessionInvalidated
                }
                let account = CloudSaveVerifiedAccount(
                    recordName: recordID.recordName, coordinatorID: coordinatorID, generation: identifier
                )
                try gate.check()
                guard generation == identifier else {
                    throw CloudSavePrivateError.sessionInvalidated
                }
                verifiedAccount = account
                snapshot = .verified(account)
            case .noAccount: snapshot = .noAccount
            case .restricted: snapshot = .restricted
            case .temporarilyUnavailable: snapshot = .temporarilyUnavailable
            case .couldNotDetermine: snapshot = .indeterminate
            @unknown default: snapshot = .indeterminate
            }
            try gate.check()
            guard generation == identifier else {
                throw CloudSavePrivateError.sessionInvalidated
            }
            continuation.yield(.resolved(snapshot))
            CloudSavePrivateLogging.emit(.account, CloudSavePrivateLogging.outcome(snapshot))
            return snapshot
        } catch {
            guard generation == identifier else {
                throw CloudSavePrivateError.sessionInvalidated
            }
            let failure = CloudSavePrivateError.normalize(error)
            let snapshot: CloudSaveAccountSnapshot =
                failure as? CloudSavePrivateError == .accountTemporarilyUnavailable
                ? .temporarilyUnavailable : .indeterminate
            continuation.yield(.resolved(snapshot))
            CloudSavePrivateLogging.emit(.account, CloudSavePrivateLogging.outcome(failure))
            throw failure
        }
    }

    /// Supersedes an in-flight verification when the system reports identity uncertainty.
    private func accountDidChange() {
        refresh?.task.cancel()
        refresh = nil
        let work = startRefresh()
        Task { [weak self] in
            _ = try? await work.task.value
            await self?.finishRefresh(work.id)
        }
    }

    /// Starts verification without blocking consumption of later account notifications.
    private func startRefresh() -> (id: UUID, task: Task<CloudSaveAccountSnapshot, any Error>) {
        beginRevalidation()
        let identifier = generation
        let task = Task { try await self.resolveAccount(generation: identifier) }
        let work = (id: identifier, task: task)
        refresh = work
        return work
    }

    /// Clears only the completed verification, preserving any newer notification-triggered work.
    private func finishRefresh(_ identifier: UUID) {
        if refresh?.id == identifier {
            refresh = nil
        }
    }

    /// Reconciles engine account events through the same pre-bootstrap monitoring owner.
    private func sessionInvalidated(_ reason: CloudSavePrivateError, generation identifier: UUID) async {
        guard generation == identifier else {
            return
        }
        if reason == .accountTemporarilyUnavailable {
            suspendAccount()
        } else if reason == .sessionInvalidated {
            accountDidChange()
        }
    }

    /// Retains local trust while forbidding further CloudKit work until fresh account verification.
    private func suspendAccount() {
        guard accountGate.close(.accountTemporarilyUnavailable) else {
            return
        }
        continuation.yield(.resolved(.temporarilyUnavailable))
        let currentSessions = sessions.compactMap(\.value)
        Task { for session in currentSessions { await session.suspend() } }
        CloudSavePrivateLogging.emit(.account, .suspended)
    }

    /// Performs only exact reads and checked first provisioning, then rereads the server winner.
    private func canonicalManifest(
        key: BootstrapKey, gate: CloudSaveAccessGate,
        makeInitialRecord: @Sendable (CKRecord.ID) throws -> CKRecord
    ) async throws -> CKRecord {
        let recordID = key.recordID
        do {
            if let existing = try await read(recordID, gate: gate) {
                return existing
            }
        } catch {
            guard (error as? CKError)?.code == .zoneNotFound else {
                throw error
            }
            guard key.permitsCreation else {
                throw CloudSavePrivateError.missingTrustedManifest
            }
            try await requests.perform(
                validate: { try gate.check() },
                operation: {
                    try await self.transport.ensureZone(CKRecordZone(zoneID: recordID.zoneID))
                })
        }
        guard key.permitsCreation else {
            throw CloudSavePrivateError.missingTrustedManifest
        }
        try gate.check()
        let proposed: CKRecord
        do { proposed = try makeInitialRecord(recordID) } catch { throw CloudSavePrivateError.malformedManifest }
        guard proposed.recordID == recordID, proposed.recordType == key.recordType,
            proposed.recordChangeTag == nil
        else { throw CloudSavePrivateError.malformedManifest }
        do {
            try await requests.perform(
                validate: { try gate.check() },
                operation: {
                    do { try await self.transport.createIfAbsent(proposed) } catch {
                        throw CloudSavePrivateError.itemError(error, for: recordID)
                    }
                })
        } catch {
            let itemError = CloudSavePrivateError.itemError(error, for: recordID)
            guard (itemError as? CKError)?.code == .serverRecordChanged else {
                throw itemError
            }
        }
        guard let winner = try await read(recordID, gate: gate) else {
            throw CloudSavePrivateError.missingTrustedManifest
        }
        return winner
    }

    /// Fetches one exact manifest through the shared throttle and lifecycle gate.
    private func read(_ recordID: CKRecord.ID, gate: CloudSaveAccessGate) async throws -> CKRecord? {
        try await requests.perform(
            validate: { try gate.check() }, operation: { try await self.transport.fetchRecord(recordID) })
    }

    /// Separates creation permission so a trusted lookup cannot join an untrusted creator's repair.
    private struct BootstrapKey: Hashable {
        let generation: UUID
        let recordID: CKRecord.ID
        let recordType: String
        let permitsCreation: Bool
    }

    /// Avoids keeping retired sessions and their host stores alive through coordinator ownership.
    private struct WeakSession {
        weak var value: CloudSavePrivateSession?
    }
}
