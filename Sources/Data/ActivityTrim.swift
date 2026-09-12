// ActivityTrim.swift
//
// Soft, non-destructive activity trims. The user (or the auto-trim heuristic)
// can clip the start, end, or any pause/resume boundary of an activity; the
// raw FIT data and the `activity_records` table are never mutated. Every
// graph and analytics path runs its rows through `ActivityTrim.filter(_:with:)`
// so a clipped range is invisible to the rest of the app.
//
// Persistence: `activity_trims` table in garmin.db, owned end-to-end by the
// viewer (garmin-dump doesn't know or care about it). Created idempotently
// in `Database.upgradeOnDiskIfNeeded`. Read via the main read-only handle;
// writes go through `Database.withWriteConnection` so the main connection
// stays read-only.

import Foundation
import SQLite3

// MARK: - Trim state

/// One contiguous "kept" window in elapsed-second units (relative to the
/// activity start). Inclusive on both ends.
public struct TrimRange: Codable, Equatable {
    public var startElapsedS: Int
    public var endElapsedS: Int
    public init(startElapsedS: Int, endElapsedS: Int) {
        self.startElapsedS = startElapsedS
        self.endElapsedS = endElapsedS
    }
}

/// Persisted per-activity trim state. `ranges` is the sorted, non-overlapping
/// set of kept windows (everything outside is filtered out).
///
/// `auto = true` means the heuristic produced this trim (or just the note,
/// in the cycling-flag case where ranges still cover the full activity).
/// `reason` is shown to the user below the timeline.
public struct TrimState: Codable, Equatable {
    public var ranges: [TrimRange]
    public var auto: Bool
    public var reason: String?

    public init(ranges: [TrimRange], auto: Bool = false, reason: String? = nil) {
        self.ranges = ranges
        self.auto = auto
        self.reason = reason
    }
}

// MARK: - Store + filter + autotrim

public enum ActivityTrim {

    // MARK: Heuristic constants

    /// Per-sport speed thresholds (m/s) above which sustained motion is
    /// considered "vehicular" rather than human-powered.
    ///
    /// - hiking/walking: a fit hiker tops out around 6 km/h (~1.7 m/s); 18
    ///   km/h (5 m/s) is well past any plausible human pace.
    /// - running: a sub-3-hour marathoner averages ~20 km/h (~5.5 m/s) and
    ///   sprints peak ~36 km/h (~10 m/s) but only in flashes; sustained 25+
    ///   km/h (7 m/s) over 30 s+ is a vehicle.
    /// - cycling: cyclists routinely hit 50–60 km/h on descents, so the only
    ///   reliable "definitely a car" threshold is highway speeds — 80 km/h
    ///   (22.2 m/s).
    private static let vehicleThresholdMps: [String: Double] = [
        "hiking":  5.0,
        "walking": 5.0,
        "running": 7.0,
        "cycling": 22.2,
    ]

    /// Sustained-window for the heuristic. Avoids tripping on a single bad
    /// GPS sample.
    private static let sustainedSeconds: Int = 30

    /// Sports whose tail we'll auto-clip if the heuristic finds vehicular
    /// motion. Cycling is handled separately (note-only, no clipping).
    private static let trimTailSports: Set<String> = ["hiking", "walking", "running"]

    // MARK: Load / save

    /// Read this activity's trim from the viewer's table, or nil if untrimmed.
    public static func load(db: Database, activityID: Int) -> TrimState? {
        do {
            let row = try db.queryOne(
                "SELECT trim_json FROM activity_trims WHERE activity_id = ?",
                bind: [.int(Int64(activityID))]
            )
            guard let json = row?.string("trim_json") else { return nil }
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(TrimState.self, from: data)
        } catch {
            // Missing table on a fresh DB pre-migration shouldn't crash the
            // viewer — treat as untrimmed.
            return nil
        }
    }

    /// Persist (or, with `state == nil`, delete) this activity's trim.
    public static func save(db: Database, activityID: Int, state: TrimState?) {
        do {
            if let state = state {
                guard let bytes = try? JSONEncoder().encode(state),
                      let json = String(data: bytes, encoding: .utf8) else { return }
                let nowISO = ISO8601DateFormatter().string(from: Date())
                try db.withWriteConnection { rw in
                    let sql = """
                        INSERT INTO activity_trims (activity_id, trim_json, updated_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(activity_id) DO UPDATE SET
                            trim_json = excluded.trim_json,
                            updated_at = excluded.updated_at
                        """
                    try execBound(rw, sql: sql, binds: [
                        .int(Int64(activityID)),
                        .text(json),
                        .text(nowISO),
                    ])
                }
            } else {
                try db.withWriteConnection { rw in
                    try execBound(rw, sql: "DELETE FROM activity_trims WHERE activity_id = ?",
                                  binds: [.int(Int64(activityID))])
                }
            }
        } catch {
            print("ActivityTrim.save failed: \(error)")
        }
    }

    // MARK: Filter

    /// Filter `rows` (output of `Queries.activityRecords`) down to just the
    /// kept ranges in `trim`.
    ///
    /// Three cases:
    ///   - `trim == nil`           → no trim configured, return all rows
    ///   - `trim.ranges.isEmpty`   → user collapsed everything, return nothing
    ///   - otherwise               → return only rows inside any kept range
    public static func filter(_ rows: [Row], with trim: TrimState?) -> [Row] {
        guard let trim = trim else { return rows }
        if trim.ranges.isEmpty { return [] }
        return rows.filter { row in
            guard let e = row.int("elapsed_s") else { return false }
            return keeps(elapsedS: e, with: trim)
        }
    }

    /// Does `trim` keep a record at this within-activity elapsed second?
    /// The row-level predicate behind `filter`, exposed so callers holding
    /// something other than a `[Row]` (ActivityGroup) apply the same rule.
    /// nil trim keeps everything; an empty range list keeps nothing.
    public static func keeps(elapsedS: Int, with trim: TrimState?) -> Bool {
        guard let trim = trim else { return true }
        if trim.ranges.isEmpty { return false }
        return trim.ranges.contains { elapsedS >= $0.startElapsedS && elapsedS <= $0.endElapsedS }
    }

    // MARK: Auto-trim heuristic

    /// Compact view of one record needed by the heuristic — avoids reading
    /// extra columns we don't care about here.
    public struct AutoTrimSample {
        public let elapsedS: Int
        public let speedMps: Double?
        public init(elapsedS: Int, speedMps: Double?) {
            self.elapsedS = elapsedS
            self.speedMps = speedMps
        }
    }

    /// If the rules below apply, returns a `TrimState` ready to persist;
    /// otherwise nil. Intended to run once per activity, only when no
    /// user-saved trim exists.
    ///
    /// Rules:
    /// - hiking / walking / running: walk samples backward from the end and
    ///   trim the tail at the last point where speed dropped below the
    ///   sport's vehicle threshold for a sustained 30 s window.
    /// - cycling: don't clip; if any 30 s window exceeded 80 km/h, return a
    ///   full-range trim with `auto: true` and a "Highway speeds detected"
    ///   reason so the UI can show the note.
    public static func autoTrim(sport: String?, samples: [AutoTrimSample]) -> TrimState? {
        guard let sportRaw = sport?.lowercased(), samples.count >= 2 else { return nil }
        guard let threshold = vehicleThresholdMps[sportRaw] else { return nil }
        guard let totalElapsed = samples.last?.elapsedS,
              let firstElapsed = samples.first?.elapsedS else { return nil }

        // Build a forward-looking sustained-window flag per sample: true if
        // the median speed over the next `sustainedSeconds` (in elapsed time,
        // not sample count) is above the threshold.
        let sustainedFlags = sustainedAboveThreshold(
            samples: samples,
            threshold: threshold,
            windowSeconds: sustainedSeconds
        )

        // Cycling: note-only. Look for any sustained-vehicle window anywhere
        // in the activity; if none, do nothing.
        if sportRaw == "cycling" {
            guard sustainedFlags.contains(true) else { return nil }
            return TrimState(
                ranges: [TrimRange(startElapsedS: firstElapsed, endElapsedS: totalElapsed)],
                auto: true,
                reason: "Highway speeds detected (>80 km/h) — possible vehicle segment, review manually"
            )
        }

        // Hiking / walking / running: trim the tail. Walk backward from the
        // end. The tail is "vehicular" while sustainedFlags[i] is true; we
        // want the last index where the activity was *not* vehicular for the
        // forward window. We trim *after* that point — i.e., end the kept
        // range at the last non-vehicular sample's elapsed time.
        guard trimTailSports.contains(sportRaw) else { return nil }

        // Find the boundary: scan from the end, keep skipping while the
        // sample is part of a sustained-vehicle window. If we never hit such
        // a window, no trim.
        var i = samples.count - 1
        var sawVehicle = false
        while i >= 0 && sustainedFlags[i] {
            sawVehicle = true
            i -= 1
        }
        guard sawVehicle, i >= 0 else { return nil }

        let trimEnd = samples[i].elapsedS
        // Skip if the trim would remove less than 30 s of activity (noise).
        guard totalElapsed - trimEnd >= sustainedSeconds else { return nil }

        let kmh = threshold * 3.6
        let removedSec = totalElapsed - trimEnd
        let reason = String(
            format: "Auto-trimmed: tail looked like a drive home (>%.0f km/h sustained for %d:%02d at end)",
            kmh, removedSec / 60, removedSec % 60
        )
        return TrimState(
            ranges: [TrimRange(startElapsedS: firstElapsed, endElapsedS: trimEnd)],
            auto: true,
            reason: reason
        )
    }

    /// For every index `i`, returns true iff the median speed over the
    /// preceding `windowSeconds` of samples exceeds `threshold`. We look
    /// BACKWARD (not forward) so the very last samples of an activity get
    /// reliable context — a forward window of size 30 starting at
    /// `samples.count - 1` is just one sample, far too noisy to classify.
    /// Median (not mean) absorbs single-sample GPS spikes.
    private static func sustainedAboveThreshold(
        samples: [AutoTrimSample],
        threshold: Double,
        windowSeconds: Int
    ) -> [Bool] {
        var flags = [Bool](repeating: false, count: samples.count)
        for i in 0..<samples.count {
            let startS = samples[i].elapsedS - windowSeconds
            var window: [Double] = []
            var k = i
            while k >= 0 && samples[k].elapsedS >= startS {
                if let s = samples[k].speedMps { window.append(s) }
                k -= 1
            }
            // Need at least a few readings to bother taking a median —
            // protects the head of the activity (where the backward window
            // is empty) from false positives.
            guard window.count >= 3 else { continue }
            window.sort()
            let median = window[window.count / 2]
            if median > threshold {
                flags[i] = true
            }
        }
        return flags
    }
}

// MARK: - SQLite write helpers

/// Prepare + bind + step + finalize a single statement on the given RW
/// connection. Used by the trim writer for idempotent INSERT/UPDATE/DELETE.
private func execBound(
    _ db: OpaquePointer,
    sql: String,
    binds: [SQLValue]
) throws {
    var stmt: OpaquePointer?
    let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard rc == SQLITE_OK, let prepared = stmt else {
        throw DatabaseError.prepare(sql: sql, message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(prepared) }
    let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )
    for (i, value) in binds.enumerated() {
        let idx = Int32(i + 1)
        let brc: Int32
        switch value {
        case .int(let v):    brc = sqlite3_bind_int64(prepared, idx, v)
        case .double(let v): brc = sqlite3_bind_double(prepared, idx, v)
        case .text(let v):   brc = sqlite3_bind_text(prepared, idx, v, -1, SQLITE_TRANSIENT)
        case .blob(let v):
            brc = v.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    return sqlite3_bind_blob(prepared, idx, base, Int32(raw.count), SQLITE_TRANSIENT)
                } else {
                    return sqlite3_bind_zeroblob(prepared, idx, 0)
                }
            }
        case .null:          brc = sqlite3_bind_null(prepared, idx)
        }
        if brc != SQLITE_OK {
            throw DatabaseError.bind(index: i, message: String(cString: sqlite3_errmsg(db)))
        }
    }
    let step = sqlite3_step(prepared)
    if step != SQLITE_DONE && step != SQLITE_ROW {
        throw DatabaseError.step(message: String(cString: sqlite3_errmsg(db)))
    }
}
