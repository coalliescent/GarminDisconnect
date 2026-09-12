// ActivitySelection.swift
//
// Which activities the user has picked in the Activities sidebar, and which
// device they belong to.

import Foundation

/// The Activities sidebar selection, scoped to the device that produced it.
///
/// An `activity_id` is only meaningful next to the device whose sidebar
/// listed it, so this type keeps the ids and their owning device together and
/// will not let them drift apart: pointing it at a different device drops the
/// selection instead of carrying it over. Without that, switching devices in
/// the toolbar left the detail pane rendering an activity that wasn't in the
/// list above it, and a cmd+clicked group could straddle two devices and be
/// summed as if it were one outing (#257).
struct ActivitySelection {
    /// The picked activities, in the order the user clicked them.
    private(set) var ids: [Int] = []

    /// The device those ids belong to. `nil` whenever `ids` is empty.
    private(set) var deviceID: Int?

    var isEmpty: Bool { ids.isEmpty }

    /// Replace the selection with `newIDs`, picked on `deviceID`.
    ///
    /// Duplicates are dropped while click order is kept, so the group stays
    /// stable across repeated cmd+clicks on the same row.
    mutating func select(_ newIDs: [Int], on deviceID: Int?) {
        var seen = Set<Int>()
        ids = newIDs.filter { seen.insert($0).inserted }
        self.deviceID = ids.isEmpty ? nil : deviceID
    }

    /// Select `id` only if nothing is picked yet — the "show the most recent
    /// activity on first visit" fallback. A `nil` id (a device with no
    /// activities at all) leaves the selection empty.
    mutating func selectIfEmpty(_ id: Int?, on deviceID: Int?) {
        guard ids.isEmpty, let id else { return }
        select([id], on: deviceID)
    }

    /// Point the selection at `deviceID`, discarding anything picked on a
    /// different one.
    ///
    /// Idempotent for the device already selected: `AppState.selectDevice`
    /// posts its notification unconditionally, so re-picking the current
    /// device from the toolbar popup must not throw away the user's group.
    mutating func retarget(to deviceID: Int?) {
        guard self.deviceID != deviceID else { return }
        clear()
    }

    mutating func clear() {
        ids = []
        deviceID = nil
    }
}
