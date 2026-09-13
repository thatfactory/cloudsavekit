import CloudKit
import Testing

@testable import CloudSaveKit

@Suite("Cloud save zone access")
struct CloudSaveZoneAccessTests {
    @Test("Owned access exposes its exact zone and permits recreation")
    func ownedAccess() {
        let zone = CKRecordZone(zoneName: "Owned")
        let access = CloudSaveZoneAccess.owned(zone)

        #expect(access.zoneID == zone.zoneID)
        #expect(access.isOwned)
        #expect(access.ownedZone?.zoneID == zone.zoneID)
    }

    @Test("Shared access preserves the owner-qualified identifier and forbids recreation")
    func sharedAccess() {
        let zoneID = CKRecordZone.ID(zoneName: "Shared", ownerName: "Owner")
        let access = CloudSaveZoneAccess.shared(zoneID)

        #expect(access.zoneID == zoneID)
        #expect(!access.isOwned)
        #expect(access.ownedZone == nil)
    }

    @Test("Account transitions recreate owned zones but never participant-owned shared zones")
    func accountTransitionZoneChangesRespectOwnership() throws {
        let ownedZone = CKRecordZone(zoneName: "Owned")
        let sharedZoneID = CKRecordZone.ID(zoneName: "Shared", ownerName: "owner")

        let ownedChanges = CloudSaveZoneAccess.owned(ownedZone).accountTransitionDatabaseChanges
        let sharedChanges = CloudSaveZoneAccess.shared(sharedZoneID).accountTransitionDatabaseChanges

        let ownedChange = try #require(ownedChanges.first)
        guard case .saveZone(let restoredZone) = ownedChange else {
            Issue.record("Expected an owned-zone save")
            return
        }
        #expect(restoredZone.zoneID == ownedZone.zoneID)
        #expect(sharedChanges.isEmpty)
    }
}
