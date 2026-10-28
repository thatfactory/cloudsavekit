public import CloudKit
import Foundation

/// Synchronizes one permanently bound account, zone, and host store through CloudSaveEngine.
public final actor CloudSavePrivateSession {
    public nonisolated let statusUpdates: AsyncStream<CloudSaveStatus>
    private let context: CloudSavePrivateSessionContext
    private let engine: any CloudSaveSessionEngine
    private let transport: any CloudSavePrivateTransport
    private let requests: CloudSavePrivateRequestGate
    private var isRetired = false
    private var recordRequests: [UUID: Task<CKRecord?, any Error>] = [:]

    /// Creates the package-owned engine with fixed-account and trusted-manifest policies.
    init(
        account: CloudSaveVerifiedAccount, accountGate: CloudSaveAccessGate,
        zoneID: CKRecordZone.ID, manifestRecordID: CKRecord.ID,
        database: CKDatabase, stateSerialization: CKSyncEngine.State.Serialization?,
        client: any CloudSaveClient, automaticallySync: Bool,
        transport: any CloudSavePrivateTransport, requests: CloudSavePrivateRequestGate,
        onInvalidation: @escaping @Sendable (CloudSavePrivateError) async -> Void
    ) {
        let context = CloudSavePrivateSessionContext(
            account: account, accountGate: accountGate, zoneID: zoneID,
            manifestRecordID: manifestRecordID, onInvalidation: onInvalidation
        )
        var configuration = CloudSaveConfiguration(
            database: database, stateSerialization: stateSerialization,
            zone: CKRecordZone(zoneID: zoneID), automaticallySync: automaticallySync
        )
        configuration.privateSession = context
        let engine = CloudSaveEngine(
            configuration: configuration, client: CloudSavePrivateClient(client: client, context: context)
        )
        self.context = context
        self.engine = engine
        self.transport = transport
        self.requests = requests
        statusUpdates = engine.statusUpdates
    }

    /// Injects synchronization operations for credential-free session lifecycle tests.
    init(
        context: CloudSavePrivateSessionContext, engine: any CloudSaveSessionEngine,
        transport: any CloudSavePrivateTransport, requests: CloudSavePrivateRequestGate = CloudSavePrivateRequestGate()
    ) {
        self.context = context
        self.engine = engine
        self.transport = transport
        self.requests = requests
        statusUpdates = engine.statusUpdates
    }

    deinit {
        context.sessionGate.close()
        for task in recordRequests.values {
            task.cancel()
        }
        let engine = engine
        Task { await engine.retire() }
    }

    /// Restores the durable pending ledger; this is not an initial remote-fetch barrier.
    public func start() async throws { try await perform { try await self.engine.start() } }

    /// Waits for the existing engine's fresh fetch and host-apply barrier.
    public func fetchNow() async throws { try await perform { try await self.engine.fetchNow() } }

    /// Sends locally committed changes, preserving failed uploads in the host ledger.
    public func sendNow() async throws { try await perform { try await self.engine.sendNow() } }

    /// Fetches and sends through the same serialized engine operations.
    public func syncNow() async throws { try await perform { try await self.engine.syncNow() } }

    /// Enqueues only durable changes belonging to this active account and zone.
    public func enqueue(_ changes: [CloudSavePendingChange]) async throws {
        try context.validatePending(changes)
        try await perform { await self.engine.enqueue(changes) }
    }

    /// Fetches an exact record, including assets, and rejects late or wrong-zone results.
    public func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        try context.check()
        guard recordID.zoneID == context.zoneID else {
            throw CloudSavePrivateError.wrongZone
        }
        let identifier = UUID()
        let task = Task { [requests, transport, context] in
            try await requests.perform(validate: { try context.check() }) {
                try await transport.fetchRecord(recordID)
            }
        }
        recordRequests[identifier] = task
        defer { recordRequests[identifier] = nil }
        return try await withTaskCancellationHandler {
            try await perform { try await task.value }
        } onCancel: {
            task.cancel()
        }
    }

    /// Permanently pauses this handle; a fresh verified session resumes its host's durable ledger.
    public func suspend() async {
        await retire(reason: .suspended)
    }

    /// Permanently revokes this handle before awaiting engine cancellation.
    public func invalidate() async {
        await retire(reason: .sessionInvalidated)
    }

    // MARK: - Private

    /// Normalizes all failures and rejects asynchronous results after terminal lifecycle changes.
    private func perform<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        try context.check()
        do {
            let result = try await operation()
            try Task.checkCancellation()
            try context.check()
            return result
        } catch {
            do { try context.validateTransportError(error) } catch let reason as CloudSavePrivateError {
                context.sessionGate.close(reason)
                await context.onInvalidation(reason)
                await retire(reason: reason)
                throw reason
            }
            try context.check()
            throw CloudSavePrivateError.normalize(error)
        }
    }

    /// Closes gates first; cancellation never controls which account can publish a result.
    private func retire(reason: CloudSavePrivateError) async {
        guard !isRetired else {
            return
        }
        isRetired = true
        context.sessionGate.close(reason)
        for task in recordRequests.values {
            task.cancel()
        }
        recordRequests.removeAll()
        CloudSavePrivateLogging.emit(.session, CloudSavePrivateLogging.outcome(reason))
        await engine.retire()
    }
}
