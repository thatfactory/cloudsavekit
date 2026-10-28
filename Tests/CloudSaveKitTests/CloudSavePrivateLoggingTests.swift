import AppLogger
import Foundation
import Testing

@testable import CloudSaveKit

/// Verifies the private lifecycle's complete vocabulary without querying OS log storage.
struct CloudSavePrivateLoggingTests {
    @Test(arguments: CloudSavePrivateLogging.Operation.allCases, CloudSavePrivateLogging.Outcome.allCases)
    func eventMessagesRemainBoundedPrefixedAndSingleLine(
        operation: CloudSavePrivateLogging.Operation, outcome: CloudSavePrivateLogging.Outcome
    ) {
        let message = CloudSaveLogging.formatted(CloudSavePrivateLogging.message(operation, outcome))
        #expect(message == "☁️ private \(operation.rawValue) | result=\(outcome.rawValue)")
        #expect(!message.contains("\n"))
        #expect(CloudSaveLogging.subsystem == "com.thatfactory.cloudsavekit")
    }

    @Test func accountIdentityAndErrorPayloadNeverEnterEvents() {
        let account = CloudSaveVerifiedAccount(
            recordName: "private-account-must-not-appear", coordinatorID: UUID(), generation: UUID()
        )
        #expect(CloudSavePrivateLogging.outcome(.verified(account)) == .verified)
        let error = NSError(
            domain: "private-record-must-not-appear", code: 17, userInfo: [NSLocalizedDescriptionKey: "private"])
        #expect(CloudSavePrivateLogging.outcome(error) == .failed)
        #expect(CloudSavePrivateLogging.outcome(CancellationError()) == .cancelled)
        #expect(CloudSavePrivateLogging.outcome(CloudSavePrivateError.sessionInvalidated) == .stale)
        #expect(CloudSavePrivateLogging.outcome(CloudSavePrivateError.accountTemporarilyUnavailable) == .suspended)
        #expect(CloudSavePrivateLogging.outcome(CloudSavePrivateError.missingTrustedManifest) == .integrityFailure)
        #expect(CloudSavePrivateLogging.Outcome.failed.level == .error)
        #expect(CloudSavePrivateLogging.Outcome.cancelled.level == .debug)
        #expect(CloudSavePrivateLogging.Outcome.verified.level == .info)
    }
}
