import CloudKit
import Foundation

/// Tracks active operations and independent attention-required recovery conditions.
struct CloudSaveStateMachine: Sendable {
    private var activeOperationCounts: [CloudSaveOperation: Int] = [:]
    private var failures: [CloudSaveFailureRequirement] = []
    private var operationGenerations: [CloudSaveOperation: Int] = [:]

    /// Whether a host callback failure currently blocks all synchronization work.
    var requiresHostRecovery: Bool {
        containsFailure(for: .hostPersistence)
    }

    /// Whether a zone failure still requires a later successful zone change.
    func requiresRecovery(for zoneID: CKRecordZone.ID) -> Bool {
        containsFailure(for: .zone(zoneID))
    }

    /// Begins a synchronization operation and advances its recovery generation.
    mutating func begin(_ operation: CloudSaveOperation) {
        activeOperationCounts[operation, default: 0] += 1
        operationGenerations[operation, default: 0] += 1
    }

    /// Completes one synchronization operation and clears only an eligible operation failure.
    mutating func complete(_ operation: CloudSaveOperation) {
        let activeCount = activeOperationCounts[operation, default: 0]
        if activeCount <= 1 {
            activeOperationCounts[operation] = nil
        } else {
            activeOperationCounts[operation] = activeCount - 1
        }

        let generation = operationGenerations[operation, default: 0]
        failures.removeAll { requirement in
            guard requirement.context == .operation(operation) else {
                return false
            }

            guard let minimumRecoveryGeneration = requirement.minimumRecoveryGeneration else {
                return false
            }

            return generation >= minimumRecoveryGeneration
        }
    }

    /// Discards operation activity belonging to an engine that has been stopped.
    mutating func resetActiveOperations() {
        activeOperationCounts.removeAll()
    }

    /// Records a failure for a host, record, or zone work item.
    mutating func fail(
        _ failure: CloudSaveFailure,
        context: CloudSaveFailureContext
    ) {
        record(
            CloudSaveFailureRequirement(
                context: context,
                failure: failure,
                minimumRecoveryGeneration: nil
            )
        )
    }

    /// Records an operation failure that only a later operation generation may clear.
    mutating func fail(
        _ failure: CloudSaveFailure,
        operation: CloudSaveOperation
    ) {
        let recoveryGeneration = operationGenerations[operation, default: 0] + 1
        record(
            CloudSaveFailureRequirement(
                context: .operation(operation),
                failure: failure,
                minimumRecoveryGeneration: recoveryGeneration
            )
        )
    }

    /// Resolves one exact failure context without affecting unrelated failures.
    mutating func resolve(_ context: CloudSaveFailureContext) {
        failures.removeAll { $0.context == context }
    }

    /// Resolves successful or terminally acknowledged record changes.
    mutating func resolve(recordIDs: [CKRecord.ID]) {
        for recordID in recordIDs {
            resolve(.record(recordID))
        }
    }

    /// Clears record failures whose work is no longer present in the host's durable ledger.
    mutating func reconcilePendingRecordIDs(
        _ pendingRecordIDs: Set<CKRecord.ID>,
        in zoneID: CKRecordZone.ID
    ) {
        failures.removeAll { requirement in
            guard case .record(let recordID) = requirement.context else {
                return false
            }

            return recordID.zoneID == zoneID && !pendingRecordIDs.contains(recordID)
        }
    }

    /// Resolves successful record-zone changes.
    mutating func resolve(zoneIDs: [CKRecordZone.ID]) {
        for zoneID in zoneIDs {
            resolve(.zone(zoneID))
        }
    }

    /// Projects the most important current state into the public status model.
    func status(hasPendingChanges: Bool) -> CloudSaveStatus {
        if let failure = failures.last?.failure {
            return .failed(failure)
        }

        if activeOperationCounts[.sending, default: 0] > 0 {
            return .sending
        }

        if activeOperationCounts[.fetching, default: 0] > 0 {
            return .fetching
        }

        return .ready(hasPendingChanges: hasPendingChanges)
    }
}

// MARK: - Private

extension CloudSaveStateMachine {
    /// Returns whether the exact failure context remains unresolved.
    private func containsFailure(for context: CloudSaveFailureContext) -> Bool {
        failures.contains { $0.context == context }
    }

    /// Inserts or replaces one context while preserving every independent requirement.
    private mutating func record(_ requirement: CloudSaveFailureRequirement) {
        failures.removeAll { $0.context == requirement.context }
        failures.append(requirement)
    }
}
