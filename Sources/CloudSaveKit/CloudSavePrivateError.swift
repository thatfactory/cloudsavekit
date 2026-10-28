import CloudKit
import Foundation

/// Normalized private-session failures; hosts never need to interpret CloudKit error codes.
public enum CloudSavePrivateError: Error, Equatable, Sendable {
    case accountTemporarilyUnavailable
    case fetchIncomplete
    case hostRecoveryRequired
    case malformedManifest
    case manifestIdentityMismatch
    case missingTrustedManifest
    case notStarted
    case sessionInvalidated
    case suspended
    case transport(CloudSaveFailure, retryAfterSeconds: Double?)
    case wrongZone

    /// Whether a verified same-account local cache may remain usable after this failure.
    public var permitsOfflineUse: Bool {
        switch self {
        case .accountTemporarilyUnavailable, .fetchIncomplete, .suspended, .transport(.networkUnavailable, _): true
        default: false
        }
    }

    /// Converts internal transport or engine failures without exposing their user-info payloads.
    static func normalize(_ error: any Error) -> any Error {
        if let error = error as? Self {
            return error
        }
        if CloudSaveRetryPolicy.isCancellation(error) {
            return CancellationError()
        }
        if let error = error as? CloudSaveEngineError {
            return switch error {
            case .hostRecoveryRequired: Self.hostRecoveryRequired
            case .reconfigurationRequired: Self.missingTrustedManifest
            case .freshFetchNotObserved, .configuredZoneFetchFailed: Self.fetchIncomplete
            case .notStarted: Self.notStarted
            }
        }
        let cloudError = error as? CKError
        if cloudError?.code == .accountTemporarilyUnavailable {
            return Self.accountTemporarilyUnavailable
        }
        return Self.transport(CloudSaveFailure(error: error), retryAfterSeconds: cloudError?.retryAfterSeconds)
    }

    /// Extracts the exact single-item failure, preserving nested account and permission errors.
    static func itemError(_ error: any Error, for item: AnyHashable) -> any Error {
        guard let cloudError = error as? CKError,
            cloudError.code == .partialFailure,
            let itemError = cloudError.partialErrorsByItemID?[item]
        else { return error }
        return Self.itemError(itemError, for: item)
    }
}
