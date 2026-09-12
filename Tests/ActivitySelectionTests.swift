// ActivitySelectionTests.swift
//
// Covers ActivitySelection, the device-scoped activity picking state behind
// the Activities sidebar (bug #257).
//
// The bug: MainWindowController held a bare [Int] of activity ids with no
// record of which device they came from, so switching devices in the toolbar
// reloaded the sidebar but kept the old selection. The detail pane then
// rendered activities that weren't in the list above it, and — once #252 made
// selection plural — could sum one device's outing with another's.
//
// So the property under test is: ids and deviceID move together, always.

import Foundation

// MARK: - Test runner (file-local; mirrors DatabaseTests.swift)

private var passed = 0
private var failed = 0

private func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("  ok    \(name)")
    } catch {
        failed += 1
        print("  FAIL  \(name): \(error)")
    }
}

private struct AssertError: Error, CustomStringConvertible {
    let msg: String
    var description: String { msg }
}

private func expect(_ cond: Bool, _ msg: @autoclosure () -> String = "") throws {
    if !cond {
        let m = msg()
        throw AssertError(msg: m.isEmpty ? "expectation failed" : m)
    }
}

private func expectEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, _ msg: @autoclosure () -> String = ""
) throws {
    if lhs != rhs {
        throw AssertError(msg: "\(lhs) != \(rhs)\(msg().isEmpty ? "" : " — \(msg())")")
    }
}

// MARK: - Suite

func runActivitySelectionTests() -> (passed: Int, failed: Int) {
    passed = 0
    failed = 0

    test("starts empty and unowned") {
        let sel = ActivitySelection()
        try expect(sel.isEmpty)
        try expectEqual(sel.ids, [])
        try expectEqual(sel.deviceID, nil)
    }

    test("select records the owning device") {
        var sel = ActivitySelection()
        sel.select([7, 9], on: 1)
        try expectEqual(sel.ids, [7, 9])
        try expectEqual(sel.deviceID, 1)
        try expect(!sel.isEmpty)
    }

    test("select drops duplicates but keeps click order") {
        var sel = ActivitySelection()
        sel.select([9, 7, 9, 3, 7], on: 1)
        try expectEqual(sel.ids, [9, 7, 3])
    }

    // The bug itself. Device 2's sidebar must not be paired with device 1's
    // activity ids.
    test("switching devices clears the selection") {
        var sel = ActivitySelection()
        sel.select([1, 2], on: 1)
        sel.retarget(to: 2)
        try expect(sel.isEmpty, "selection survived a device change: \(sel.ids)")
        try expectEqual(sel.deviceID, nil)
    }

    // AppState.selectDevice posts .selectedDeviceChanged unconditionally, so
    // re-picking the device that is already current must not throw away a
    // cmd+clicked group the user just built.
    test("re-picking the same device keeps the selection") {
        var sel = ActivitySelection()
        sel.select([1, 2], on: 1)
        sel.retarget(to: 1)
        try expectEqual(sel.ids, [1, 2])
        try expectEqual(sel.deviceID, 1)
    }

    test("retarget to no device clears the selection") {
        var sel = ActivitySelection()
        sel.select([1], on: 1)
        sel.retarget(to: nil)
        try expect(sel.isEmpty)
        try expectEqual(sel.deviceID, nil)
    }

    // An empty selection is unowned, so the next device change is a no-op
    // rather than something that has to be reasoned about.
    test("selecting nothing leaves the selection unowned") {
        var sel = ActivitySelection()
        sel.select([], on: 1)
        try expect(sel.isEmpty)
        try expectEqual(sel.deviceID, nil)
    }

    test("clear empties both ids and owner") {
        var sel = ActivitySelection()
        sel.select([4, 5], on: 2)
        sel.clear()
        try expect(sel.isEmpty)
        try expectEqual(sel.deviceID, nil)
    }

    // loadCurrentTab() falls back to the newest activity when nothing is
    // picked; that fallback belongs to the device it was queried for.
    test("default fallback is owned by the device it came from") {
        var sel = ActivitySelection()
        sel.selectIfEmpty(3, on: 2)
        try expectEqual(sel.ids, [3])
        try expectEqual(sel.deviceID, 2)
    }

    test("default fallback does not override a real selection") {
        var sel = ActivitySelection()
        sel.select([1, 2], on: 1)
        sel.selectIfEmpty(3, on: 1)
        try expectEqual(sel.ids, [1, 2])
    }

    // A device with no activities at all (fixture device 2) must end up with
    // an empty pane, not the other device's leftovers.
    test("a device with no activities ends up showing nothing") {
        var sel = ActivitySelection()
        sel.select([1, 2], on: 1)
        sel.retarget(to: 2)
        sel.selectIfEmpty(nil, on: 2)   // mostRecentActivityID returned nil
        try expect(sel.isEmpty, "stale ids left for an activity-less device: \(sel.ids)")
    }

    return (passed, failed)
}
