import CloudKit
import Foundation

/// Configures one private or shared database cloud-save engine.
public struct CloudSaveConfiguration: Sendable {
    /// The CloudKit database used by the engine.
    public let database: CKDatabase

    /// CKSyncEngine state restored from the host's local store.
    public let stateSerialization: CKSyncEngine.State.Serialization?

    /// The configured zone and its lifecycle ownership.
    public let zoneAccess: CloudSaveZoneAccess

    /// The configured custom record zone.
    ///
    /// New code should use ``zoneAccess`` or ``zoneID`` to retain ownership semantics.
    public let zone: CKRecordZone

    /// The exact configured zone identifier.
    public var zoneID: CKRecordZone.ID {
        zoneAccess.zoneID
    }

    /// Whether CKSyncEngine schedules background synchronization automatically.
    public let automaticallySync: Bool

    /// An optional stable subscription identifier.
    public let subscriptionID: CKSubscription.ID?

    /// Creates a cloud-save configuration.
    public init(
        database: CKDatabase,
        stateSerialization: CKSyncEngine.State.Serialization? = nil,
        zone: CKRecordZone,
        automaticallySync: Bool = true,
        subscriptionID: CKSubscription.ID? = nil
    ) {
        precondition(database.databaseScope == .private, "Owned zones require a private database.")
        self.database = database
        self.stateSerialization = stateSerialization
        self.zone = zone
        zoneAccess = .owned(zone)
        self.automaticallySync = automaticallySync
        self.subscriptionID = subscriptionID
    }
    /// Creates a configuration for a zone shared with the current account.
    public init(
        database: CKDatabase,
        stateSerialization: CKSyncEngine.State.Serialization? = nil,
        sharedZoneID: CKRecordZone.ID,
        automaticallySync: Bool = true,
        subscriptionID: CKSubscription.ID? = nil
    ) {
        precondition(database.databaseScope == .shared, "Shared zones require a shared database.")
        self.database = database
        self.stateSerialization = stateSerialization
        zone = CKRecordZone(zoneID: sharedZoneID)
        zoneAccess = .shared(sharedZoneID)
        self.automaticallySync = automaticallySync
        self.subscriptionID = subscriptionID
    }
}
