public import CloudKit
import Foundation

/// A canonical manifest identity obtained in one verified account generation.
public struct CloudSavePrivateBootstrap<Value: Sendable>: Sendable {
    public let account: CloudSaveVerifiedAccount
    public let zoneID: CKRecordZone.ID
    public let value: Value
    let manifestRecordID: CKRecord.ID
}
