import CloudKit
import Testing

@testable import CloudSaveKit

@Suite("Cloud save failures")
struct CloudSaveFailureTests {
    @Test(
        "Classifies failures safe for application state",
        arguments: [
            (CKError.Code.notAuthenticated, CloudSaveFailure.accountUnavailable),
            (.badContainer, .configuration),
            (.networkUnavailable, .networkUnavailable),
            (.quotaExceeded, .quotaExceeded),
            (.serverRecordChanged, .recordConflict),
            (.permissionFailure, .restricted),
            (.zoneNotFound, .zoneUnavailable),
        ])
    func classifies(
        code: CKError.Code,
        expectedFailure: CloudSaveFailure
    ) {
        let error = CKError(code)

        #expect(CloudSaveFailure(error: error) == expectedFailure)
    }
}
