// Database.swift
//
// Thin Swift wrapper around the system SQLite3 module. Read-only by design — the app
// must never write to the user's archive at ~/garmin-archive/garmin.db, because that
// file is owned by garmin-dump (the Python sync tool). Anything that wants to mutate
// state goes through the SQLite-via-subprocess path of running garmin-dump.
//
// Why no third-party SQLite library: GRDB and SQLite.swift are both excellent but
// neither plays nicely with the Command-Line-Tools-only build constraint (no SwiftPM,
// no Xcode). The system `import SQLite3` is awkward but works with zero deps.
//
// Threading model: the public API is callable from any thread, but every actual
// SQLite call is serialized through one private dispatch queue. This avoids any need
// for `SQLITE_OPEN_FULLMUTEX` and keeps prepared statements safely owned. Callers
// that want async behavior should wrap calls in their own DispatchQueue.async or
// Task.detached.
//
// Schema sanity: on first open we read PRAGMA user_version and compare to a constant.
// A mismatch is a hard error (we surface it via DatabaseError) — better to refuse than
// to silently render bad data because garmin-dump's schema moved.

import Foundation
import SQLite3

// SQLite C constants are exposed as `Int32`, but the official sqlite3.h defines a
// pair of "transient" / "static" sentinels for `sqlite3_bind_*` that we have to
// recreate at the Swift level because they're macros, not symbols.
private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

/// Schema version this binary was written against. Bump in lockstep with garmin-dump.
/// v2: added `local_offset_s` to sleep_sessions and wellness_samples so the
///     viewer can render times in the wearer's local zone instead of UTC.
public let GARMIN_DUMP_SCHEMA_VERSION: Int32 = 2

// MARK: - Errors

public enum DatabaseError: Error, CustomStringConvertible {
    case cannotOpen(path: String, code: Int32, message: String)
    case prepare(sql: String, message: String)
    case bind(index: Int, message: String)
    case step(message: String)
    case schemaMismatch(found: Int32, expected: Int32)
    case fileMissing(path: String)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let code, let message):
            return "cannot open SQLite at \(path): code=\(code) \(message)"
        case .prepare(let sql, let message):
            return "prepare failed for SQL `\(sql)`: \(message)"
        case .bind(let index, let message):
            return "bind \(index) failed: \(message)"
        case .step(let message):
            return "step failed: \(message)"
        case .schemaMismatch(let found, let expected):
            return """
                garmin-dump schema mismatch: database is at version \(found), \
                GarminDisconnect expects \(expected). Upgrade one of the tools to match.
                """
        case .fileMissing(let path):
            return "no garmin-dump archive at \(path). Run `garmin-dump pull` first."
        }
    }
}

// MARK: - Bindable values

/// What you can pass to a parameterized query. Sticking to a fixed enum keeps the
/// SQLite C bind dance contained to one place.
public enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    public init(_ v: Int) { self = .int(Int64(v)) }
    public init(_ v: Int64) { self = .int(v) }
    public init(_ v: Double) { self = .double(v) }
    public init(_ v: String) { self = .text(v) }
    public init(_ v: Data) { self = .blob(v) }
}

extension SQLValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Row

/// One row from a SELECT. Internally just an array of column names paired with
/// `Any?` values; the typed accessors do the casting at the call site so query code
/// reads cleanly without `as?` everywhere.
public struct Row {
    public let columns: [String]
    public let values: [Any?]

    public init(columns: [String], values: [Any?]) {
        self.columns = columns
        self.values = values
    }

    public subscript(column: String) -> Any? {
        guard let idx = columns.firstIndex(of: column) else { return nil }
        return values[idx]
    }

    public func int(_ column: String) -> Int? {
        switch self[column] {
        case let v as Int64: return Int(v)
        case let v as Int: return v
        case let v as Double: return Int(v)
        default: return nil
        }
    }

    public func int64(_ column: String) -> Int64? {
        switch self[column] {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Double: return Int64(v)
        default: return nil
        }
    }

    public func double(_ column: String) -> Double? {
        switch self[column] {
        case let v as Double: return v
        case let v as Int64: return Double(v)
        case let v as Int: return Double(v)
        default: return nil
        }
    }

    public func string(_ column: String) -> String? {
        return self[column] as? String
    }

    public func data(_ column: String) -> Data? {
        return self[column] as? Data
    }

    /// Parse an ISO-8601 UTC string from `column`. garmin-dump stores all timestamps
    /// as ISO strings ("2026-04-08T07:13:22+00:00"), which Foundation's
    /// ISO8601DateFormatter understands.
    public func isoDate(_ column: String) -> Date? {
        guard let s = string(column) else { return nil }
        return Database.iso8601.date(from: s)
    }
}

// MARK: - Database

public final class Database {

    /// Shared ISO-8601 date formatter. SQLite isn't picky about precision, but
    /// garmin-dump always emits second-precision UTC strings via Python's
    /// `datetime.isoformat()`, which writes the timezone with a colon
    /// (`+00:00`). The default `.withInternetDateTime` set does NOT include
    /// `.withColonSeparatorInTimeZone`, so without this flag the formatter
    /// silently returns nil for every garmin-dump timestamp — and every Plotly
    /// chart that filters its rows through `isoIn.date(from:)` ends up with
    /// zero data points.
    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f
    }()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.opal.garmin-disconnect.db")

    /// Cache of prepared statements keyed on the raw SQL text. Each entry's
    /// `sqlite3_stmt*` is reused via `sqlite3_reset` + `sqlite3_clear_bindings`
    /// rather than being prepared anew on every query. There are ~30 unique queries
    /// in the whole app so this cache lives forever in practice.
    private var stmtCache: [String: OpaquePointer] = [:]
    private static let stmtCacheCap = 64

    public let path: String

    /// Opens an existing garmin-dump archive read-only. Throws if the file doesn't
    /// exist, can't be opened, or has a schema version we don't understand.
    ///
    /// Before the read-only open we briefly open the same file read-write and
    /// run any in-place additive migrations the viewer knows about (currently:
    /// v1 → v2, which adds `local_offset_s` to `sleep_sessions` and
    /// `wellness_samples`). This means a user upgrading the .app no longer
    /// has to manually `garmin-dump ingest --reparse` first to satisfy the
    /// schema check — the new column gets created empty and the next reparse
    /// fills it. Migrations are intentionally limited to additive ALTERs that
    /// the Python tool would also apply, so the two sides stay in lockstep.
    public init(path: URL) throws {
        self.path = path.path
        guard FileManager.default.fileExists(atPath: self.path) else {
            throw DatabaseError.fileMissing(path: self.path)
        }
        try Self.upgradeOnDiskIfNeeded(path: self.path)
        var handle: OpaquePointer?
        // SQLITE_OPEN_NOMUTEX: we serialize ourselves on `queue`, so the per-conn
        // mutex is wasted work.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(self.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close_v2(h) }
            throw DatabaseError.cannotOpen(path: self.path, code: rc, message: msg)
        }
        self.db = opened
        sqlite3_busy_timeout(opened, 5000)
        try assertSchemaVersion()
    }

    /// Run any additive in-place migrations the viewer knows about. Idempotent.
    /// Opens its own short-lived read-write connection so the main connection
    /// can stay read-only after this returns.
    private static func upgradeOnDiskIfNeeded(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let db = handle else {
            // If we can't open it RW (file permissions, locked, etc.) we
            // silently bail — the read-only open below will surface the real
            // error to the user.
            if let h = handle { sqlite3_close_v2(h) }
            return
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5000)

        // Viewer-owned tables: not part of the garmin-dump FIT-ingest schema
        // and not gated on user_version. These hold UI state (e.g. soft
        // activity trims) the Python tool doesn't know or care about; running
        // garmin-dump won't drop them and won't notice them.
        try createViewerTablesIfMissing(db)

        let current = readUserVersion(db)
        guard current < GARMIN_DUMP_SCHEMA_VERSION else { return }

        // v1 → v2: add `local_offset_s` columns. Both ALTERs are guarded by
        // a `PRAGMA table_info` check so the migration is idempotent — if
        // the user happens to have run `garmin-dump ingest --reparse` first
        // (which already ran the same migration on the Python side) we just
        // bump the version and exit.
        if current < 2 {
            try addColumnIfMissing(db, table: "sleep_sessions",
                                   column: "local_offset_s", decl: "INTEGER")
            try addColumnIfMissing(db, table: "wellness_samples",
                                   column: "local_offset_s", decl: "INTEGER")
        }

        // Bump user_version to whatever we successfully reached.
        let bump = "PRAGMA user_version = \(GARMIN_DUMP_SCHEMA_VERSION)"
        if sqlite3_exec(db, bump, nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.step(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// CREATE-IF-NOT-EXISTS for tables the viewer owns end-to-end (no Python
    /// counterpart). Currently: `activity_trims`, which stores per-activity
    /// non-destructive trim ranges set by the user (or the autotrim heuristic).
    private static func createViewerTablesIfMissing(_ db: OpaquePointer) throws {
        let ddl = """
            CREATE TABLE IF NOT EXISTS activity_trims (
                activity_id INTEGER PRIMARY KEY,
                trim_json   TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            )
            """
        if sqlite3_exec(db, ddl, nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.step(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Idempotent ALTER TABLE ADD COLUMN. Returns silently if the column
    /// already exists. Throws on any other SQLite error.
    private static func addColumnIfMissing(
        _ db: OpaquePointer,
        table: String,
        column: String,
        decl: String
    ) throws {
        // PRAGMA table_info doesn't take bind params; the table name is a
        // controlled identifier so f-string interpolation is safe here.
        var stmt: OpaquePointer?
        let probe = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, probe, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(sql: probe,
                                        message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var existing = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            // table_info columns: cid, name, type, notnull, dflt_value, pk
            if let name = sqlite3_column_text(stmt, 1) {
                existing.insert(String(cString: name))
            }
        }
        if existing.contains(column) { return }

        let alter = "ALTER TABLE \(table) ADD COLUMN \(column) \(decl)"
        if sqlite3_exec(db, alter, nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.step(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Read PRAGMA user_version off a raw connection. Returns 0 on any error.
    private static func readUserVersion(_ db: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    deinit {
        // Finalize every cached statement before closing the connection. SQLite will
        // refuse to close cleanly if any statements remain alive.
        for (_, stmt) in stmtCache {
            sqlite3_finalize(stmt)
        }
        stmtCache.removeAll()
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    /// Reads `PRAGMA user_version` and compares to `GARMIN_DUMP_SCHEMA_VERSION`.
    /// Throws on mismatch so the UI can show a clear "upgrade one of the tools" error.
    private func assertSchemaVersion() throws {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard rc == SQLITE_OK else {
            throw DatabaseError.prepare(
                sql: "PRAGMA user_version",
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.step(message: String(cString: sqlite3_errmsg(db)))
        }
        let found = sqlite3_column_int(stmt, 0)
        if found != GARMIN_DUMP_SCHEMA_VERSION {
            throw DatabaseError.schemaMismatch(
                found: found,
                expected: GARMIN_DUMP_SCHEMA_VERSION
            )
        }
    }

    // MARK: - Short-lived RW connection (viewer-owned tables only)

    /// Open a short-lived read-write connection, run `body`, close.
    ///
    /// The main `db` handle stays read-only (per the file header). This escape
    /// hatch is for mutating viewer-owned tables — `activity_trims` and any
    /// future ones — without giving the rest of the codebase write access to
    /// the FIT-ingest tables that garmin-dump owns. Callers should run only
    /// statements against viewer-owned tables.
    public func withWriteConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        return try queue.sync {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
            let rc = sqlite3_open_v2(path, &handle, flags, nil)
            guard rc == SQLITE_OK, let rw = handle else {
                let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                if let h = handle { sqlite3_close_v2(h) }
                throw DatabaseError.cannotOpen(path: path, code: rc, message: msg)
            }
            defer { sqlite3_close_v2(rw) }
            sqlite3_busy_timeout(rw, 5000)
            return try body(rw)
        }
    }

    // MARK: - Public query API

    /// Run a query and collect every row. Convenience wrapper around `step` for
    /// SELECT statements that return a small bounded number of rows. For very
    /// large result sets, use `forEach` instead and process row-by-row.
    public func query(_ sql: String, bind: [SQLValue] = []) throws -> [Row] {
        return try queue.sync {
            try unsafeQuery(sql, bind: bind)
        }
    }

    /// Run a query expected to return at most one row.
    public func queryOne(_ sql: String, bind: [SQLValue] = []) throws -> Row? {
        return try queue.sync {
            try unsafeQuery(sql, bind: bind).first
        }
    }

    /// Run a query and call `body` for each row, never materializing the full set.
    /// Use for queries that may return millions of rows (e.g. activity_records).
    public func forEach(
        _ sql: String,
        bind: [SQLValue] = [],
        body: (Row) throws -> Void
    ) throws {
        try queue.sync {
            try unsafeForEach(sql, bind: bind, body: body)
        }
    }

    /// Get a single scalar from a query (e.g. `SELECT COUNT(*) FROM ...`). Returns
    /// nil if the query produced no rows.
    public func scalarInt(_ sql: String, bind: [SQLValue] = []) throws -> Int? {
        return try queryOne(sql, bind: bind)?.int(columnsOf: 0)
    }

    public func scalarString(_ sql: String, bind: [SQLValue] = []) throws -> String? {
        return try queryOne(sql, bind: bind)?.string(columnsOf: 0)
    }

    // MARK: - Private internals (must be called on `queue`)

    private func unsafeQuery(_ sql: String, bind: [SQLValue]) throws -> [Row] {
        var rows: [Row] = []
        try unsafeForEach(sql, bind: bind) { rows.append($0) }
        return rows
    }

    private func unsafeForEach(
        _ sql: String,
        bind: [SQLValue],
        body: (Row) throws -> Void
    ) throws {
        guard let db = db else { return }
        let stmt = try cachedStatement(sql)
        // Reset before reuse so any previous bindings/iteration state is cleared.
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)

        try bindAll(stmt: stmt, values: bind)

        let columnCount = Int(sqlite3_column_count(stmt))
        var columns: [String] = []
        columns.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            if let cstr = sqlite3_column_name(stmt, Int32(i)) {
                columns.append(String(cString: cstr))
            } else {
                columns.append("col\(i)")
            }
        }

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW {
                throw DatabaseError.step(message: String(cString: sqlite3_errmsg(db)))
            }
            var values: [Any?] = []
            values.reserveCapacity(columnCount)
            for i in 0..<columnCount {
                values.append(extractColumn(stmt: stmt, index: Int32(i)))
            }
            try body(Row(columns: columns, values: values))
        }
    }

    private func cachedStatement(_ sql: String) throws -> OpaquePointer {
        if let cached = stmtCache[sql] {
            return cached
        }
        guard let db = db else {
            throw DatabaseError.prepare(sql: sql, message: "database not open")
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            throw DatabaseError.prepare(
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        // LRU: drop the oldest cached entry if we're at the cap. We don't track real
        // recency since the cache rarely fills, but if it does, the oldest insertion
        // wins eviction.
        if stmtCache.count >= Database.stmtCacheCap {
            if let victimKey = stmtCache.keys.first {
                if let victimStmt = stmtCache.removeValue(forKey: victimKey) {
                    sqlite3_finalize(victimStmt)
                }
            }
        }
        stmtCache[sql] = prepared
        return prepared
    }

    private func bindAll(stmt: OpaquePointer, values: [SQLValue]) throws {
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)  // SQLite bind indexes are 1-based.
            let rc: Int32
            switch value {
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v):
                rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        return sqlite3_bind_blob(
                            stmt, idx, base, Int32(raw.count), SQLITE_TRANSIENT
                        )
                    } else {
                        return sqlite3_bind_zeroblob(stmt, idx, 0)
                    }
                }
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw DatabaseError.bind(index: i, message: msg)
            }
        }
    }

    private func extractColumn(stmt: OpaquePointer, index: Int32) -> Any? {
        let type = sqlite3_column_type(stmt, index)
        switch type {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return sqlite3_column_int64(stmt, index)
        case SQLITE_FLOAT:
            return sqlite3_column_double(stmt, index)
        case SQLITE_TEXT:
            if let cstr = sqlite3_column_text(stmt, index) {
                return String(cString: cstr)
            }
            return nil
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(stmt, index) {
                let len = Int(sqlite3_column_bytes(stmt, index))
                return Data(bytes: bytes, count: len)
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Row column-index helpers

private extension Row {
    /// Index-by-position accessor used by `scalarInt` / `scalarString`. Not exposed
    /// publicly because the named-column API is what callers should use.
    func int(columnsOf index: Int) -> Int? {
        guard index >= 0 && index < values.count else { return nil }
        switch values[index] {
        case let v as Int64: return Int(v)
        case let v as Int: return v
        case let v as Double: return Int(v)
        default: return nil
        }
    }

    func string(columnsOf index: Int) -> String? {
        guard index >= 0 && index < values.count else { return nil }
        return values[index] as? String
    }
}
