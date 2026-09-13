import Foundation

/// Describes invalid sharing metadata supplied to CloudSaveKit.
public enum CloudSaveSharingError: Error, Equatable, Sendable {
    /// The invitation belongs to another CloudKit container.
    case unexpectedContainer

    /// The invitation does not represent a zone-wide share.
    case unsupportedShare
}
