import Testing

@testable import CloudSaveKit

struct CloudSaveAccountChangeTests {
    @Test func onlySignedInTransitionEstablishesAccount() {
        #expect(CloudSaveAccountChange.signedIn(currentAccountID: "current").isSignedIn)
        #expect(!CloudSaveAccountChange.signedOut(previousAccountID: "previous").isSignedIn)
        #expect(
            !CloudSaveAccountChange.switched(
                previousAccountID: "previous",
                currentAccountID: "current"
            ).isSignedIn
        )
    }

    @Test func nilStateInitialSignInPreservesOnlyItsCurrentLifecycle() {
        var classifier = CloudSaveAccountTransitionClassifier(wasInitializedWithState: false)

        let initial = classifier.shouldInvalidate(for: .signedIn(currentAccountID: "current"))
        let repeated = classifier.shouldInvalidate(for: .signedIn(currentAccountID: "current"))
        let switched = classifier.shouldInvalidate(
            for: .switched(previousAccountID: "current", currentAccountID: "next")
        )

        #expect(!initial)
        #expect(repeated)
        #expect(switched)
    }

    @Test func nilStateUnexpectedFirstEventAndRestoredEnginesAlwaysInvalidate() {
        var signedOutFirst = CloudSaveAccountTransitionClassifier(wasInitializedWithState: false)
        var switchedFirst = CloudSaveAccountTransitionClassifier(wasInitializedWithState: false)
        var restored = CloudSaveAccountTransitionClassifier(wasInitializedWithState: true)

        let signedOut = signedOutFirst.shouldInvalidate(for: .signedOut(previousAccountID: "previous"))
        let switched = switchedFirst.shouldInvalidate(
            for: .switched(previousAccountID: "previous", currentAccountID: "current")
        )
        let restoredSignIn = restored.shouldInvalidate(for: .signedIn(currentAccountID: "current"))

        #expect(signedOut)
        #expect(switched)
        #expect(restoredSignIn)
    }
}
