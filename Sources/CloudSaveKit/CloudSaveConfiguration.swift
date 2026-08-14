import CloudKit
import Foundation

/// Configures one private-database cloud-save engine.
public struct CloudSaveConfiguration: Sendable {
    /// The private CloudKit database used by the engine.
    public let database: CKDatabase

    /// CKSyncEngine state restored from the host's local store.
    public let stateSerialization: CKSyncEngine.State.Serialization?

    /// The custom record zone owned by this save domain.
    public let zone: CKRecordZone

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
        self.database = database
        self.stateSerialization = stateSerialization
        self.zone = zone
        self.automaticallySync = automaticallySync
        self.subscriptionID = subscriptionID
    }
}
