# Sharing Custom Zones

Use one owner-created private zone from both private and shared database views.

## Overview

CloudKit zone sharing has two roles:

- The owner creates a custom zone in the private database and shares that zone.
- A participant accepts the share and accesses the owner's exact zone through the shared database.

CloudSaveKit keeps those lifecycles distinct. An owned configuration may create or recover its zone. A shared configuration never creates the owner's zone.

## Create and present a share

Use ``CloudSaveSharingCoordinator/ensureZoneWideShare(for:)`` with an owned zone identifier. The returned `CKShare` is UI-independent; the host decides how to present the system sharing interface and which permissions to offer.

Sharing an individual root record is not supported. CloudSaveKit expects a zone-wide share so every synchronized record in the configured zone has one consistent topology.

## Accept and retain the invitation

Pass system-provided `CKShare.Metadata` to ``CloudSaveSharingCoordinator/accept(metadata:)``. CloudSaveKit validates that the invitation belongs to the coordinator's container and represents a zone-wide share, then returns the owner-qualified `CKRecordZone.ID`.

Persist that complete identifier with the host's inventory or account binding. Configure ``CloudSaveConfiguration`` with the shared database and `sharedZoneID`. Never reduce the identity to the zone name: two owners can use the same zone name.

The host application must receive share metadata through its platform lifecycle and decide which accepted shared zone belongs to its product. ``CloudSaveSharingCoordinator/sharedRecordZones()`` can discover accessible shared zones, but CloudSaveKit does not choose among them.

## Handle lost access

If the participant loses access or the shared zone disappears, CloudSaveKit raises ``CloudSaveEngineError/reconfigurationRequired``. Return the application to its sharing or inventory-selection flow. Do not silently create a private zone with the same name; that would fork the data into a different inventory.

## Test both views

Use two physical devices signed into separate iCloud accounts:

1. Create and share the owner's zone.
2. Accept the invitation on the participant account.
3. Upload one unique record from the owner and verify it appears on the participant after automatic or one explicit synchronization.
4. Upload a different record from the participant and verify it appears on the owner.
5. Confirm the participant remains configured with the shared database and the owner's full zone identifier throughout relaunch.

Simulator share-link handoff and push behavior can differ from physical devices. Use simulators for deterministic application tests, but treat a two-device signed-build run as the significant end-to-end acceptance.
