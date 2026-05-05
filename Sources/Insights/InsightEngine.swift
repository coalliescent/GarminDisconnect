// InsightEngine.swift
//
// Computes the 10-card insight strip rendered atop the Overview tab. Each
// insight is a small interpreted summary of recent data — e.g. "RHR -3 bpm
// vs 76 days ago" — designed to give the user a one-glance read of trends
// without making them dig through charts.
//
// Design rules:
//   - Insights MUST be honest about data gaps. Every aggregate filters
//     `WHERE x IS NOT NULL` and reports the denominator ("over N days") so
//     the user knows how much they're trusting it.
//   - An insight that lacks enough data to compute returns nil — it just
//     doesn't appear in the strip. We don't fake values.
//   - Compute target: <200ms total for all 10 insights, since they run on
//     every Overview tab activation. The cap is enforced informally by
//     reusing data we've already pulled (one Database round-trip per insight
//     at most).

import Foundation

public struct Insight {
    public enum Direction: String { case up, down, flat }
    public enum Severity: String { case info = "", positive, negative }

    public let title: String
    public let primaryValue: String
    public let secondaryValue: String?
    public let direction: Direction
    public let severity: Severity
}

public enum InsightEngine {

    /// Compute the full insight strip. Order matters — cards are rendered in
    /// the returned sequence. Cards that can't be computed are omitted, not
    /// stubbed with placeholder text.
    public static func compute(db: Database, deviceID: Int) -> [Insight] {
        var out: [Insight] = []

        if let i = restingHRTrend90d(db: db, deviceID: deviceID) { out.append(i) }
        // Activity streaks (current and longest) deliberately removed: they
        // implicitly assume the watch is worn every day, which doesn't hold
        // for this user's irregular wear pattern. A "broken streak" with a
        // gap day reads as a regression even when nothing real has changed,
        // so the insight is more misleading than useful here.
        if let i = weeklyRunningKM(db: db, deviceID: deviceID) { out.append(i) }
        if let i = sleepConsistencyScore(db: db, deviceID: deviceID) { out.append(i) }
        if let i = biggestActivityThisMonth(db: db, deviceID: deviceID) { out.append(i) }
        if let i = daysSinceLastSync(db: db) { out.append(i) }
        if let i = watchWearRate(db: db, deviceID: deviceID) { out.append(i) }
        if let i = bodyBatteryRecovery(db: db, deviceID: deviceID) { out.append(i) }
        // Skipping easy-pace HR drift in v1: needs >=8 same-pace runs which the
        // tiny.db fixture doesn't have, and the calculation is fragile in the
        // absence of stride data.

        return out
    }

    // MARK: - Individual insights

    /// "Resting HR -3 bpm vs 76 days ago" — compares the trailing 14-day mean
    /// against the prior 76-day mean. Both windows skip null days.
    private static func restingHRTrend90d(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query(
            Queries.overviewRestingHR90d, bind: [.int(Int64(deviceID))]
        )) ?? []
        // Sort descending by date to make recent-vs-prior split easier.
        let pairs: [(date: String, hr: Double)] = rows.compactMap { r in
            guard let d = r.string("date_local"), let hr = r.int("resting_hr") else { return nil }
            return (d, Double(hr))
        }.sorted(by: { $0.date > $1.date })
        guard pairs.count >= 14 else { return nil }

        let recent = Array(pairs.prefix(14)).map { $0.hr }
        let prior = Array(pairs.dropFirst(14)).map { $0.hr }
        guard !recent.isEmpty, !prior.isEmpty else { return nil }
        let recentMean = recent.reduce(0, +) / Double(recent.count)
        let priorMean = prior.reduce(0, +) / Double(prior.count)
        let delta = recentMean - priorMean

        let direction: Insight.Direction = delta < -0.5 ? .down : (delta > 0.5 ? .up : .flat)
        // Lower RHR is the desirable direction.
        let severity: Insight.Severity = delta < -1.0 ? .positive : (delta > 1.0 ? .negative : .info)
        let sub = String(format: "%.0f → %.0f over %d days", priorMean, recentMean, prior.count + recent.count)
        return Insight(
            title: "Resting HR (90 d)",
            primaryValue: String(format: "%+.1f bpm", delta),
            secondaryValue: sub,
            direction: direction,
            severity: severity
        )
    }

    /// "Current streak: 5 days" — consecutive days ending at today with at
    /// least one activity. Uses local-time bucketing.
    private static func currentActivityStreak(db: Database, deviceID: Int) -> Insight? {
        let dates = activityDays(db: db, deviceID: deviceID)
        guard !dates.isEmpty else { return nil }
        let today = DateUtil.calendar.startOfDay(for: Date())
        var streak = 0
        var cursor = today
        while dates.contains(DateUtil.dayString(from: cursor)) {
            streak += 1
            cursor = DateUtil.adding(days: -1, to: cursor)
        }
        if streak == 0 {
            // Find how long the gap is so we can show "1 day off" or similar.
            var gap = 0
            cursor = today
            while !dates.contains(DateUtil.dayString(from: cursor)) {
                gap += 1
                cursor = DateUtil.adding(days: -1, to: cursor)
                if gap > 30 { break }
            }
            return Insight(
                title: "Current streak",
                primaryValue: "0 days",
                secondaryValue: "\(gap) day rest",
                direction: .flat,
                severity: .info
            )
        }
        return Insight(
            title: "Current streak",
            primaryValue: "\(streak) days",
            secondaryValue: nil,
            direction: .up,
            severity: streak >= 7 ? .positive : .info
        )
    }

    /// "Longest streak ever: 14 days" — longest run of consecutive activity
    /// days in the entire history.
    private static func longestActivityStreak(db: Database, deviceID: Int) -> Insight? {
        let dates = Array(activityDays(db: db, deviceID: deviceID)).sorted()
        guard !dates.isEmpty else { return nil }
        var longest = 1
        var current = 1
        for i in 1..<dates.count {
            guard
                let prev = DateUtil.day(from: dates[i - 1]),
                let curr = DateUtil.day(from: dates[i])
            else { continue }
            if DateUtil.daysBetween(prev, curr) == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return Insight(
            title: "Longest streak",
            primaryValue: "\(longest) days",
            secondaryValue: nil,
            direction: .flat,
            severity: .info
        )
    }

    /// "Running this week: 23.4 km (vs 18.1)" — running km this week vs last.
    private static func weeklyRunningKM(db: Database, deviceID: Int) -> Insight? {
        // Pull all running activities in the last 14 days; bucket by week.
        let rows = (try? db.query("""
            SELECT start_time_utc, total_distance_m
            FROM activities
            WHERE device_id = ?
              AND sport = 'running'
              AND start_time_utc >= datetime('now', '-14 days')
              AND total_distance_m IS NOT NULL
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard !rows.isEmpty else { return nil }
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        var thisWeek = 0.0
        var lastWeek = 0.0
        for row in rows {
            guard let s = row.string("start_time_utc"),
                  let d = Database.iso8601.date(from: s),
                  let dist = row.double("total_distance_m") else { continue }
            let km = dist / 1000.0
            if d >= weekAgo { thisWeek += km } else { lastWeek += km }
        }
        let direction: Insight.Direction = thisWeek > lastWeek + 0.5
            ? .up : (thisWeek < lastWeek - 0.5 ? .down : .flat)
        let severity: Insight.Severity = thisWeek > lastWeek ? .positive : .info
        return Insight(
            title: "Running this week",
            primaryValue: String(format: "%.1f km", thisWeek),
            secondaryValue: String(format: "vs %.1f last week", lastWeek),
            direction: direction,
            severity: severity
        )
    }

    /// Standard deviation of sleep midpoint over the last 14 days, in minutes.
    /// Lower = more consistent bedtime.
    private static func sleepConsistencyScore(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT start_utc, end_utc
            FROM sleep_sessions
            WHERE device_id = ?
              AND start_utc >= datetime('now', '-14 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard rows.count >= 3 else { return nil }
        var midpoints: [Double] = []
        for row in rows {
            guard let s = row.string("start_utc"),
                  let e = row.string("end_utc"),
                  let sd = Database.iso8601.date(from: s),
                  let ed = Database.iso8601.date(from: e) else { continue }
            let mid = sd.timeIntervalSince1970 + (ed.timeIntervalSince1970 - sd.timeIntervalSince1970) / 2
            // Reduce to seconds-into-day so std-dev measures bedtime regularity, not absolute calendar drift.
            let dayStart = DateUtil.calendar.startOfDay(for: Date(timeIntervalSince1970: mid))
            midpoints.append(mid - dayStart.timeIntervalSince1970)
        }
        guard midpoints.count >= 3 else { return nil }
        let mean = midpoints.reduce(0, +) / Double(midpoints.count)
        let variance = midpoints.map { pow($0 - mean, 2) }.reduce(0, +) / Double(midpoints.count)
        let stdMinutes = sqrt(variance) / 60.0
        let severity: Insight.Severity = stdMinutes < 30 ? .positive : (stdMinutes > 90 ? .negative : .info)
        return Insight(
            title: "Sleep consistency",
            primaryValue: String(format: "±%.0f min", stdMinutes),
            secondaryValue: "over \(midpoints.count) nights",
            direction: .flat,
            severity: severity
        )
    }

    /// Longest activity (by duration) in the trailing 30 days.
    private static func biggestActivityThisMonth(db: Database, deviceID: Int) -> Insight? {
        let row = try? db.queryOne("""
            SELECT sport, total_timer_s, total_distance_m, start_time_utc
            FROM activities
            WHERE device_id = ?
              AND start_time_utc >= datetime('now', '-30 days')
              AND total_timer_s IS NOT NULL
            ORDER BY total_timer_s DESC
            LIMIT 1
            """, bind: [.int(Int64(deviceID))])
        guard let row = row,
              let sport = row.string("sport"),
              let dur = row.double("total_timer_s") else { return nil }
        let dist = row.double("total_distance_m")
        let sub = dist.map { String(format: "%.1f km %@", $0 / 1000, sport) } ?? sport
        return Insight(
            title: "Biggest workout (30 d)",
            primaryValue: PlotlyEncoder.formatDuration(dur),
            secondaryValue: sub,
            direction: .flat,
            severity: .info
        )
    }

    /// "Last sync: 2 days ago"
    private static func daysSinceLastSync(db: Database) -> Insight? {
        let isoStr = (try? db.scalarString(Queries.syncLastSuccessfulPull)) ?? nil
        guard let isoStr = isoStr,
              let date = Database.iso8601.date(from: isoStr)
        else {
            return Insight(
                title: "Last sync",
                primaryValue: "never",
                secondaryValue: nil,
                direction: .flat,
                severity: .negative
            )
        }
        let days = DateUtil.daysBetween(DateUtil.calendar.startOfDay(for: date),
                                        DateUtil.calendar.startOfDay(for: Date()))
        let primary: String
        let severity: Insight.Severity
        if days == 0 {
            primary = "today"; severity = .positive
        } else if days == 1 {
            primary = "yesterday"; severity = .info
        } else if days < 7 {
            primary = "\(days) days ago"; severity = .info
        } else {
            primary = "\(days) days ago"; severity = .negative
        }
        return Insight(
            title: "Last sync",
            primaryValue: primary,
            secondaryValue: nil,
            direction: .flat,
            severity: severity
        )
    }

    /// "Wear rate: 27/30 days (90%)"
    private static func watchWearRate(db: Database, deviceID: Int) -> Insight? {
        let count = (try? db.scalarInt("""
            SELECT COUNT(*) FROM wellness_daily
            WHERE device_id = ?
              AND date_local >= date('now', '-30 days')
            """, bind: [.int(Int64(deviceID))])) ?? nil
        guard let n = count else { return nil }
        let pct = Int((Double(n) / 30.0 * 100).rounded())
        let severity: Insight.Severity = pct >= 80 ? .positive : (pct < 50 ? .negative : .info)
        return Insight(
            title: "Watch wear rate",
            primaryValue: "\(n)/30 days",
            secondaryValue: "\(pct)%",
            direction: .flat,
            severity: severity
        )
    }

    /// Mean of (max - min) body battery over the last 14 nights vs prior 14.
    /// Up trend = better recovery.
    private static func bodyBatteryRecovery(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT date_local, body_battery_min, body_battery_max
            FROM wellness_daily
            WHERE device_id = ?
              AND body_battery_min IS NOT NULL
              AND body_battery_max IS NOT NULL
              AND date_local >= date('now', '-28 days')
            ORDER BY date_local DESC
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard rows.count >= 4 else { return nil }
        let drains: [Double] = rows.compactMap { r in
            guard let lo = r.int("body_battery_min"),
                  let hi = r.int("body_battery_max") else { return nil }
            return Double(max(0, hi - lo))
        }
        guard drains.count >= 4 else { return nil }
        let recent = Array(drains.prefix(14))
        let prior = Array(drains.dropFirst(14))
        let recentMean = recent.reduce(0, +) / Double(recent.count)
        guard !prior.isEmpty else {
            return Insight(
                title: "Recovery (drain)",
                primaryValue: String(format: "%.0f", recentMean),
                secondaryValue: "over \(recent.count) days",
                direction: .flat,
                severity: .info
            )
        }
        let priorMean = prior.reduce(0, +) / Double(prior.count)
        let delta = recentMean - priorMean
        // Higher drain = the user spent more battery during the day, which is
        // generally a sign of either training stress or sleep debt. Treating
        // it as info-only: we don't have enough domain knowledge to call it
        // good or bad without more context.
        let direction: Insight.Direction = delta > 1 ? .up : (delta < -1 ? .down : .flat)
        return Insight(
            title: "Recovery (drain)",
            primaryValue: String(format: "%.0f", recentMean),
            secondaryValue: String(format: "%+.0f vs prior", delta),
            direction: direction,
            severity: .info
        )
    }

    // MARK: - Shared helpers

    /// Set of `YYYY-MM-DD` strings for every day with at least one activity.
    private static func activityDays(db: Database, deviceID: Int) -> Set<String> {
        let rows = (try? db.query("""
            SELECT DISTINCT date(start_time_utc, 'localtime') AS day
            FROM activities
            WHERE device_id = ?
            """, bind: [.int(Int64(deviceID))])) ?? []
        var out = Set<String>()
        for row in rows {
            if let d = row.string("day") { out.insert(d) }
        }
        return out
    }
}
