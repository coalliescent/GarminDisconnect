// DateUtilTests.swift
//
// Unit tests for the gap-handling helpers in DateUtil. Compiled into the
// same test binary as DatabaseTests via run_tests.sh.

import Foundation

// MARK: - Tiny test harness (mirrors DatabaseTests.swift)

private var passed = 0
private var failed = 0

private struct AssertError: Error, CustomStringConvertible {
    let msg: String
    var description: String { msg }
}

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

private func expectEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, _ msg: @autoclosure () -> String = ""
) throws {
    if lhs != rhs {
        throw AssertError(msg: "\(lhs) != \(rhs) — \(msg())")
    }
}

private func expect(_ cond: Bool, _ msg: @autoclosure () -> String = "") throws {
    if !cond { throw AssertError(msg: msg()) }
}

// MARK: - Helper for building Date values from yyyy-MM-dd

private func d(_ s: String) -> Date {
    return DateUtil.day(from: s)!
}

// MARK: - Tests

func testFillGapsKeepsExistingDays() throws {
    let rows: [(date: Date, value: Double?)] = [
        (d("2026-04-01"), 100),
        (d("2026-04-02"), 200),
        (d("2026-04-03"), 300),
    ]
    let dense = DateUtil.fillGaps(rows)
    try expectEqual(dense.count, 3)
    try expectEqual(dense[0].value, 100)
    try expectEqual(dense[1].value, 200)
    try expectEqual(dense[2].value, 300)
}

func testFillGapsInsertsNullsForMissingDays() throws {
    // April 1, 2, [3 missing], 4, [5 missing], [6 missing], 7
    let rows: [(date: Date, value: Double?)] = [
        (d("2026-04-01"), 1),
        (d("2026-04-02"), 2),
        (d("2026-04-04"), 4),
        (d("2026-04-07"), 7),
    ]
    let dense = DateUtil.fillGaps(rows)
    try expectEqual(dense.count, 7)
    try expectEqual(dense[0].value, 1)
    try expectEqual(dense[1].value, 2)
    try expect(dense[2].value == nil, "expected day 3 to be nil")
    try expectEqual(dense[3].value, 4)
    try expect(dense[4].value == nil, "expected day 5 to be nil")
    try expect(dense[5].value == nil, "expected day 6 to be nil")
    try expectEqual(dense[6].value, 7)
}

func testFillGapsDoesNotPadBeyondInputRange() throws {
    // Caller asks for a window much wider than the input. fillGaps should
    // CLAMP to the actual range of the input — we never invent days the
    // user wasn't around for.
    let rows: [(date: Date, value: Double?)] = [
        (d("2026-04-05"), 5),
        (d("2026-04-07"), 7),
    ]
    let start = d("2026-01-01")
    let end = d("2026-12-31")
    let dense = DateUtil.fillGaps(rows, start: start, end: end)
    // Range was clamped to 2026-04-05..2026-04-07, so 3 days.
    try expectEqual(dense.count, 3)
    try expectEqual(dense[0].value, 5)
    try expect(dense[1].value == nil, "middle day should be a gap")
    try expectEqual(dense[2].value, 7)
}

func testFillGapsHandlesEmptyInput() throws {
    let dense = DateUtil.fillGaps([])
    try expectEqual(dense.count, 0)
}

func testDayOfWeekMatchesCalendar() throws {
    // 2026-04-05 is a Sunday in the Gregorian calendar.
    let sun = d("2026-04-05")
    try expectEqual(DateUtil.dayOfWeek(sun), 0)
    let mon = d("2026-04-06")
    try expectEqual(DateUtil.dayOfWeek(mon), 1)
    let sat = d("2026-04-11")
    try expectEqual(DateUtil.dayOfWeek(sat), 6)
}

func testFirstSundayOnOrBeforeIsIdempotent() throws {
    let mid_week = d("2026-04-08")  // Wednesday
    let sun = DateUtil.firstSundayOnOrBefore(mid_week)
    try expectEqual(DateUtil.dayString(from: sun), "2026-04-05")
    // If we pass a Sunday, we should get the same Sunday back.
    let already = DateUtil.firstSundayOnOrBefore(d("2026-04-05"))
    try expectEqual(DateUtil.dayString(from: already), "2026-04-05")
}

// MARK: - Entry point (called by TestsMain)

func runDateUtilTests() -> (passed: Int, failed: Int) {
    print("DateUtilTests")
    test("fillGaps preserves existing days", testFillGapsKeepsExistingDays)
    test("fillGaps inserts nulls for missing days", testFillGapsInsertsNullsForMissingDays)
    test("fillGaps clamps to input range, doesn't pad", testFillGapsDoesNotPadBeyondInputRange)
    test("fillGaps handles empty input", testFillGapsHandlesEmptyInput)
    test("dayOfWeek matches Gregorian", testDayOfWeekMatchesCalendar)
    test("firstSundayOnOrBefore idempotent", testFirstSundayOnOrBeforeIsIdempotent)
    let result = (passed, failed)
    passed = 0; failed = 0
    return result
}
