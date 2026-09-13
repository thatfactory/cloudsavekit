import CloudKit

/// Describes whether the configured record zone is owned by the current account or shared with it.
public enum CloudSaveZoneAccess: Sendable {
    /// A private-database zone that CloudSaveKit may create and recover.
    case owned(CKRecordZone)

    /// A shared-database zone whose lifecycle remains under its owner's control.
    case shared(CKRecordZone.ID)

    /// The exact configured zone identifier.
    public var zoneID: CKRecordZone.ID {
        switch self {
        case .owned(let zone): zone.zoneID
        case .shared(let zoneID): zoneID
        }
    }

    /// Whether CloudSaveKit owns and may recreate the zone.
    public var isOwned: Bool {
        if case .owned = self {
            return true
        }
        return false
    }

    /// The owned zone value when CloudSaveKit may create it.
    var ownedZone: CKRecordZone? {
        if case .owned(let zone) = self {
            return zone
        }
        return nil
    }

    /// Database changes needed when CKSyncEngine clears state for an account transition.
    var accountTransitionDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] {
        guard let ownedZone else {
            return []
        }
        return [.saveZone(ownedZone)]
    }
}
