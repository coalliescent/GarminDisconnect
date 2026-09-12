// ActivityGroup.swift
//
// A *group* is one or more watch activities viewed as if they were a single
// activity. Real-life outings get split across several FIT files all the time:
// the watch is stopped and restarted mid-ride, or a multi-day hike is recorded
// one activity per day. Selecting them together (cmd+click in the activity
// list) should produce one detail pane, not several.
//
// This file is the single place that loads activity_records and stitches them
// into a group timeline. Every activity-detail encoder in PlotlyEncoder reads
// an `ActivityGroup` rather than querying records itself, so all of them agree
// on the same stitched view.
//
// The stitching rules:
//
//   - Members are ordered by the timestamp of their first record (falling back
//     to activities.start_time_utc, then activity_id) — i.e. chronologically,
//     regardless of the order the user clicked them in.
//   - `elapsedS` is rebased onto a group clock anchored at the first member:
//     member k's records are offset by the real wall-clock gap between its
//     first record and the first member's first record. A stop/start pause of
//     four minutes therefore shows up as a four-minute hole, and a
//     one-activity-per-day hike spreads across days, which is what actually
//     happened.
//   - `distanceM` is made cumulative: member k's distances are offset by the
//     total distance covered by members 0..<k. So a route chained out of three
//     files runs 0 → 38 km on one axis instead of restarting at zero twice.
//   - `memberElapsedS` keeps each record's original within-activity elapsed
//     value, because that is the coordinate system saved trims are expressed
//     in (see ActivityTrim).
//
// A group of one is the degenerate case and is byte-for-byte what the viewer
// did before groups existed: both offsets are zero, so `elapsedS ==
// memberElapsedS` and `distanceM` is the raw column. That is deliberate — it
// means there is exactly one code path, and the single-activity case is
// covered by the same tests.

import Foundation

/// One record from `activity_records`, rebased onto its group's timeline.
public struct GroupRecord {
    /// Which activity this record came from.
    public let activityID: Int
    /// Index of that activity within `ActivityGroup.members`.
    public let memberIndex: Int
    public let timestampISO: String
    /// Seconds since the group's first record (see the rebasing note above).
    public let elapsedS: Int
    /// Seconds since this record's *own* activity started. Trim coordinates.
    public let memberElapsedS: Int
    public let latDeg: Double?
    public let lonDeg: Double?
    public let altitudeM: Double?
    /// Distance from the group's start, in metres — cumulative across members.
    public let distanceM: Double?
    public let speedMps: Double?
    public let heartRate: Int?
    public let cadence: Int?
    public let powerW: Int?
}

/// One activity inside a group, plus the offsets that placed it there.
public struct ActivityGroupMember {
    public let activityID: Int
    /// Added to each record's own `elapsed_s` to get the group clock.
    public let elapsedOffsetS: Int
    /// Added to each record's own `distance_m` to get cumulative distance.
    public let distanceOffsetM: Double
    /// The trim in force for this member (nil = untrimmed).
    public let trim: TrimState?
}

public struct ActivityGroup {

    /// Members in chronological order.
    public let members: [ActivityGroupMember]

    /// Trim-filtered records across every member, in group-clock order.
    /// This is what the charts draw.
    public let records: [GroupRecord]

    /// The same records *without* trim filtering. The trim timeline needs the
    /// full activity so a handle dragged inward can be dragged back out.
    public let allRecords: [GroupRecord]

    public var activityIDs: [Int] { members.map(\.activityID) }

    public var isMulti: Bool { members.count > 1 }

    /// True when any member carries a non-empty trim.
    public var hasTrim: Bool {
        members.contains { ($0.trim?.ranges.isEmpty == false) }
    }

    /// True when every trim in force was produced by the autotrim heuristic.
    /// Used only for the summary card's "Trim: auto / manual" hint.
    public var trimIsAuto: Bool {
        let active = members.compactMap(\.trim).filter { !$0.ranges.isEmpty }
        return !active.isEmpty && active.allSatisfy(\.auto)
    }

    /// Indices into `records` where each member's slice begins, for callers
    /// that need to break a line at a member boundary.
    public var memberStartIndices: Set<Int> {
        var out: Set<Int> = []
        var lastMember = -1
        for (i, r) in records.enumerated() where r.memberIndex != lastMember {
            out.insert(i)
            lastMember = r.memberIndex
        }
        return out
    }

    // MARK: - Loading

    /// Load and stitch the records for `activityIDs`.
    ///
    /// `trims` maps activity_id → the trim to apply to that member; ids absent
    /// from the map are untrimmed. Duplicate ids are collapsed. Ids with no
    /// rows in `activities` and no records are dropped.
    public static func load(
        db: Database,
        activityIDs: [Int],
        trims: [Int: TrimState] = [:]
    ) throws -> ActivityGroup {
        // Collapse duplicates, keeping first-seen order as the tiebreak base.
        var uniqueIDs: [Int] = []
        var seen = Set<Int>()
        for id in activityIDs where !seen.contains(id) {
            uniqueIDs.append(id)
            seen.insert(id)
        }

        /// Everything we need about one candidate member before ordering.
        struct Loaded {
            let activityID: Int
            let rows: [Row]
            let sortKey: Date?
            let firstElapsedS: Int
        }

        var loaded: [Loaded] = []
        for id in uniqueIDs {
            let rows = try db.query(Queries.activityRecords, bind: [.int(Int64(id))])
            // Prefer the first record's timestamp; fall back to the activities
            // row so an activity with zero records still sorts sensibly.
            var sortKey = rows.first?.isoDate("timestamp_utc")
            if sortKey == nil {
                let meta = try? db.queryOne(
                    Queries.activityMeta, bind: [.int(Int64(id))]
                )
                sortKey = meta?.isoDate("start_time_utc")
            }
            loaded.append(Loaded(
                activityID: id,
                rows: rows,
                sortKey: sortKey,
                firstElapsedS: rows.first?.int("elapsed_s") ?? 0
            ))
        }

        // Chronological, with unknown-date members last and activity_id as a
        // stable tiebreak so the group never reshuffles between renders.
        loaded.sort { a, b in
            switch (a.sortKey, b.sortKey) {
            case let (x?, y?):
                if x != y { return x < y }
                return a.activityID < b.activityID
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.activityID < b.activityID
            }
        }

        guard let anchor = loaded.first else {
            return ActivityGroup(members: [], records: [], allRecords: [])
        }

        var members: [ActivityGroupMember] = []
        var records: [GroupRecord] = []
        var allRecords: [GroupRecord] = []
        var distanceOffset: Double = 0

        for (index, member) in loaded.enumerated() {
            // Real seconds between this member's start and the anchor's, then
            // corrected so the member's own elapsed origin lands there. For the
            // anchor this is identically zero.
            let elapsedOffset: Int
            if index == 0 {
                elapsedOffset = 0
            } else if let mine = member.sortKey, let theirs = anchor.sortKey {
                elapsedOffset = Int(mine.timeIntervalSince(theirs).rounded())
                    + anchor.firstElapsedS - member.firstElapsedS
            } else {
                // No usable timestamp on one side — fall back to butting this
                // member up against wherever the previous one ended.
                let prevEnd = allRecords.last?.elapsedS ?? 0
                elapsedOffset = prevEnd - member.firstElapsedS
            }

            let trim = trims[member.activityID]
            let myDistanceOffset = distanceOffset
            var lastKeptDistance: Double?
            for row in member.rows {
                let elapsed = row.int("elapsed_s") ?? 0
                let rec = GroupRecord(
                    activityID: member.activityID,
                    memberIndex: index,
                    timestampISO: row.string("timestamp_utc") ?? "",
                    elapsedS: elapsed + elapsedOffset,
                    memberElapsedS: elapsed,
                    latDeg: row.double("lat_deg"),
                    lonDeg: row.double("lon_deg"),
                    altitudeM: row.double("altitude_m"),
                    distanceM: row.double("distance_m").map { $0 + myDistanceOffset },
                    speedMps: row.double("speed_mps"),
                    heartRate: row.int("heart_rate"),
                    cadence: row.int("cadence"),
                    powerW: row.int("power_w")
                )
                allRecords.append(rec)
                if ActivityTrim.keeps(elapsedS: elapsed, with: trim) {
                    records.append(rec)
                    if let d = row.double("distance_m") { lastKeptDistance = d }
                }
            }

            members.append(ActivityGroupMember(
                activityID: member.activityID,
                elapsedOffsetS: elapsedOffset,
                distanceOffsetM: myDistanceOffset,
                trim: trim
            ))

            // The next member's route continues from where this one stopped.
            // Uses the last *kept* distance so a trimmed tail doesn't leave a
            // phantom kilometre in the middle of the group's x-axis.
            distanceOffset = myDistanceOffset + (lastKeptDistance ?? 0)
        }

        return ActivityGroup(members: members, records: records, allRecords: allRecords)
    }

    /// Records belonging to one member, from the trim-filtered set.
    public func records(ofMember index: Int) -> ArraySlice<GroupRecord> {
        guard let lo = records.firstIndex(where: { $0.memberIndex == index })
        else { return [] }
        var hi = lo
        while hi < records.count && records[hi].memberIndex == index { hi += 1 }
        return records[lo..<hi]
    }

    /// Untrimmed records belonging to one member.
    public func allRecords(ofMember index: Int) -> ArraySlice<GroupRecord> {
        guard let lo = allRecords.firstIndex(where: { $0.memberIndex == index })
        else { return [] }
        var hi = lo
        while hi < allRecords.count && allRecords[hi].memberIndex == index { hi += 1 }
        return allRecords[lo..<hi]
    }
}
