import AppLogger
import Foundation

/// Formats bounded private-session events without account, record, manifest, or host content.
enum CloudSavePrivateLogging {
    /// Package-owned boundaries whose outcome diagnoses personal synchronization.
    enum Operation: String, CaseIterable {
        case account
        case bootstrap
        case engine
        case recordFetch = "record-fetch"
        case session
    }

    /// Fixed diagnostic tokens that never contain user or CloudKit identifiers.
    enum Outcome: String, CaseIterable {
        case cancelled
        case drained
        case failed
        case indeterminate
        case integrityFailure = "integrity-failure"
        case invalidated
        case missing
        case noAccount = "no-account"
        case restricted
        case stale
        case succeeded
        case suspended
        case verified

        /// Expected cancellation and stale rejection do not become operational faults.
        var level: AppLogLevel {
            switch self {
            case .failed, .integrityFailure: .error
            case .invalidated, .noAccount, .restricted, .suspended, .verified: .info
            default: .debug
            }
        }
    }

    /// Routes each event through the package's existing canonical logging gateway.
    static func emit(_ operation: Operation, _ outcome: Outcome) {
        CloudSaveLogging.log(level: outcome.level, message(operation, outcome))
    }

    /// Renders one independently testable single-line event body.
    static func message(_ operation: Operation, _ outcome: Outcome) -> String {
        "private \(operation.rawValue) | result=\(outcome.rawValue)"
    }

    /// Classifies failures without interpolating error descriptions or metadata.
    static func outcome(_ error: any Error) -> Outcome {
        if error is CancellationError {
            return .cancelled
        }
        switch error as? CloudSavePrivateError {
        case .sessionInvalidated: return .stale
        case .accountTemporarilyUnavailable, .suspended: return .suspended
        case .malformedManifest, .manifestIdentityMismatch, .missingTrustedManifest: return .integrityFailure
        default: return .failed
        }
    }

    /// Records availability separately from opaque verified identity.
    static func outcome(_ snapshot: CloudSaveAccountSnapshot) -> Outcome {
        switch snapshot {
        case .indeterminate: .indeterminate
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .suspended
        case .verified: .verified
        }
    }
}
