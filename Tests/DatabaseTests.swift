// DatabaseTests.swift
//
// Tiny assertion-based test harness for Database.swift. Deliberately doesn't depend
// on XCTest because XCTest under Command-Line-Tools-only requires extra setup that
// would defeat the "no Xcode" promise. The harness is a flat list of test functions;
// each one prints OK / FAIL with a message and increments a counter. The runner
// exits non-zero if any test failed.
//
// Compiled by Tests/run_tests.sh as a separate binary that links Database.swift,
// then invoked against Tests/fixtures/tiny.db.

import Foundation
import SQLite3

// Re-declared so the test binary doesn't have to share types with the app target.
// In practice this file is built into a binary that ALSO compiles Database.swift,
// so the real types are already in scope; this is just for SourceKit linting.

// MARK: - Test runner

private var passed = 0
private var failed = 0
private var currentTest = ""

private func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
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
        let m = msg()
        throw AssertError(msg: "\(lhs) != \(rhs)\(m.isEmpty ? "" : " — \(m)")")
    }
}

// MARK: - Fixture path

private let fixturePath: URL = {
    // Tests are run from the project root via Tests/run_tests.sh.
    let cwd = FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: cwd).appendingPathComponent("Tests/fixtures/tiny.db")
}()

// MARK: - Tests

private func testFixtureExists() throws {
    try expect(
        FileManager.default.fileExists(atPath: fixturePath.path),
        "fixture not found at \(fixturePath.path) — run python3 Tests/build_fixture.py"
    )
}

private func testOpenReadOnly() throws {
    let db = try Database(path: fixturePath)
    // We don't expose write APIs, so the only way to verify the read-only-ness is to
    // confirm a SELECT works. The actual READONLY flag is enforced by SQLite itself.
    let row = try db.queryOne("SELECT COUNT(*) AS n FROM devices")
    try expect(row != nil, "expected at least one row from COUNT")
    try expect((row?.int("n") ?? 0) == 2, "expected 2 devices in fixture")
}

private func testSchemaVersionMatches() throws {
    // Database.init throws on schema mismatch, so a successful open is the test.
    _ = try Database(path: fixturePath)
}

/// garmin-dump bumping `user_version` must not lock the viewer out.
///
/// This is the bug that shipped once already: garmin-dump went to schema 3 for
/// the monitoring-rollup repair while the viewer still demanded an exact 2, so
/// the app refused to open a freshly reparsed archive. The viewer accepts a
/// range because every version in it is column-compatible.
private func testSchemaVersionRangeIsSane() throws {
    try expect(GARMIN_DUMP_MIN_SCHEMA_VERSION <= GARMIN_DUMP_SCHEMA_VERSION,
               "min schema \(GARMIN_DUMP_MIN_SCHEMA_VERSION) is above "
               + "max \(GARMIN_DUMP_SCHEMA_VERSION)")
}

/// Every version in the supported range must actually open.
///
/// Stamps a scratch copy of the fixture at each one. The viewer's own migration
/// is free to move a database *up* to what it implements, but the assertion
/// that matters is that nothing in the range is rejected.
private func testEverySupportedSchemaVersionOpens() throws {
    for version in GARMIN_DUMP_MIN_SCHEMA_VERSION...GARMIN_DUMP_SCHEMA_VERSION {
        let copy = try stampedFixtureCopy(version: version)
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            _ = try Database(path: copy)
        } catch {
            throw AssertError(msg: "schema v\(version) is in the supported range "
                                   + "but failed to open: \(error)")
        }
    }
}

/// A database newer than the viewer understands must be refused, not guessed at.
private func testSchemaVersionAboveTheRangeIsRejected() throws {
    let copy = try stampedFixtureCopy(version: GARMIN_DUMP_SCHEMA_VERSION + 1)
    defer { try? FileManager.default.removeItem(at: copy) }
    do {
        _ = try Database(path: copy)
        throw AssertError(msg: "opened a database newer than the supported range")
    } catch let err as DatabaseError {
        guard case .schemaMismatch = err else {
            throw AssertError(msg: "wrong error for a too-new schema: \(err)")
        }
    }
}

/// Copy the fixture to a temp path and stamp `PRAGMA user_version`.
private func stampedFixtureCopy(version: Int32) throws -> URL {
    let dst = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tiny-v\(version)-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: fixturePath, to: dst)
    var handle: OpaquePointer?
    guard sqlite3_open_v2(dst.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
          let raw = handle
    else {
        throw AssertError(msg: "could not open the fixture copy read-write")
    }
    defer { sqlite3_close_v2(raw) }
    guard sqlite3_exec(raw, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK
    else {
        throw AssertError(msg: "could not stamp user_version = \(version)")
    }
    return dst
}

private func testQueryWithBindings() throws {
    let db = try Database(path: fixturePath)
    let rows = try db.query(
        "SELECT serial, model FROM devices WHERE serial = ?",
        bind: [.text("3509067685")]
    )
    try expectEqual(rows.count, 1)
    try expectEqual(rows[0].string("serial") ?? "", "3509067685")
    try expect(rows[0].string("model")?.contains("Instinct 3") == true,
               "model should mention Instinct 3, got \(String(describing: rows[0].string("model")))")
}

private func testActivityRowCount() throws {
    let db = try Database(path: fixturePath)
    let n = try db.scalarInt("SELECT COUNT(*) FROM activities") ?? -1
    try expectEqual(n, 3)
}

private func testActivityRecordsForRun() throws {
    let db = try Database(path: fixturePath)
    // The run is the activity with sport='running'.
    guard let runActivityId = try db.queryOne(
        "SELECT activity_id FROM activities WHERE sport = ?", bind: [.text("running")]
    )?.int("activity_id") else {
        throw AssertError(msg: "expected a running activity in the fixture")
    }
    let count = try db.scalarInt(
        "SELECT COUNT(*) FROM activity_records WHERE activity_id = ?",
        bind: [.int(Int64(runActivityId))]
    ) ?? -1
    try expectEqual(count, 30, "expected 30 records on the run")
}

private func testWellnessDailyHasGaps() throws {
    let db = try Database(path: fixturePath)
    // The fixture inserts 11 calendar days minus 2 gap days = 9 rows.
    // The test confirms the row count, leaving the gap-filling logic itself for the
    // unit tests in DateUtil (Phase 4).
    let n = try db.scalarInt("SELECT COUNT(*) FROM wellness_daily") ?? -1
    try expectEqual(n, 9, "expected 9 wellness rows (11 days minus 2 gap days)")
}

private func testWellnessSamplesByMetric() throws {
    let db = try Database(path: fixturePath)
    let rows = try db.query(
        "SELECT metric, COUNT(*) AS n FROM wellness_samples GROUP BY metric ORDER BY metric"
    )
    try expectEqual(rows.count, 2)
    let names = rows.compactMap { $0.string("metric") }
    try expect(names.contains("heart_rate"), "expected heart_rate metric")
    try expect(names.contains("stress_level"), "expected stress_level metric")
}

private func testStatementCacheReuse() throws {
    let db = try Database(path: fixturePath)
    // Run the same parameterized query 5 times. The cache should reuse the prepared
    // statement; we don't have direct visibility into the cache from outside the
    // class, but if reset/clear_bindings was broken, the second run would fail.
    for _ in 0..<5 {
        let row = try db.queryOne(
            "SELECT * FROM activities WHERE sport = ?",
            bind: [.text("running")]
        )
        try expect(row != nil, "expected the running activity")
    }
}

private func testFileMissingError() throws {
    let bogus = URL(fileURLWithPath: "/tmp/garmin-disconnect-does-not-exist.db")
    do {
        _ = try Database(path: bogus)
        throw AssertError(msg: "expected DatabaseError.fileMissing")
    } catch let err as DatabaseError {
        switch err {
        case .fileMissing: return
        default: throw AssertError(msg: "wrong error: \(err)")
        }
    }
}

// MARK: - Entry point (called by TestsMain)

func runDatabaseTests() -> (passed: Int, failed: Int) {
    print("DatabaseTests — fixture at \(fixturePath.path)")
    test("fixture exists",                     testFixtureExists)
    test("open read-only",                     testOpenReadOnly)
    test("schema version matches",             testSchemaVersionMatches)
    test("schema version range is sane",       testSchemaVersionRangeIsSane)
    test("every supported schema opens",       testEverySupportedSchemaVersionOpens)
    test("too-new schema is rejected",         testSchemaVersionAboveTheRangeIsRejected)
    test("query with bindings",                testQueryWithBindings)
    test("activity row count",                 testActivityRowCount)
    test("activity records for run",           testActivityRecordsForRun)
    test("wellness_daily has expected gaps",   testWellnessDailyHasGaps)
    test("wellness_samples by metric",         testWellnessSamplesByMetric)
    test("statement cache reuse",              testStatementCacheReuse)
    test("file-missing throws DatabaseError",  testFileMissingError)
    let result = (passed, failed)
    passed = 0; failed = 0
    return result
}
