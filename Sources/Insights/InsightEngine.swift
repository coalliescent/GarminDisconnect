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
        return computeOverview(db: db, deviceID: deviceID)
    }

    /// Insight strip for the Overview tab.
    public static func computeOverview(db: Database, deviceID: Int) -> [Insight] {
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

    /// Insight strip for the Wellness tab. RHR, HRV, stress, body battery
    /// recovery, intensity minutes, SpO2 — everything that gives a quick read
    /// on physiological state.
    public static func computeWellness(db: Database, deviceID: Int) -> [Insight] {
        var out: [Insight] = []
        if let i = restingHRTrend90d(db: db, deviceID: deviceID) { out.append(i) }
        if let i = hrvLastNight(db: db, deviceID: deviceID) { out.append(i) }
        if let i = stressSevenDay(db: db, deviceID: deviceID) { out.append(i) }
        if let i = bodyBatteryRecovery(db: db, deviceID: deviceID) { out.append(i) }
        if let i = intensityMinutesWeek(db: db, deviceID: deviceID) { out.append(i) }
        if let i = spo2SevenDay(db: db, deviceID: deviceID) { out.append(i) }
        return out
    }

    /// Insight strip for the Activities tab. Volume, active days, longest
    /// activity, training-load week-over-week, average pace for runs, sport
    /// mix.
    public static func computeActivities(db: Database, deviceID: Int) -> [Insight] {
        var out: [Insight] = []
        if let i = activeTimeWeek(db: db, deviceID: deviceID) { out.append(i) }
        if let i = distanceWeek(db: db, deviceID: deviceID) { out.append(i) }
        if let i = activeDays7d(db: db, deviceID: deviceID) { out.append(i) }
        if let i = trainingLoadWeek(db: db, deviceID: deviceID) { out.append(i) }
        if let i = avgRunPace14d(db: db, deviceID: deviceID) { out.append(i) }
        if let i = biggestActivityThisMonth(db: db, deviceID: deviceID) { out.append(i) }
        if let i = sportMix30d(db: db, deviceID: deviceID) { out.append(i) }
        return out
    }

    /// Insight strip for the Sleep tab. Last night's score, duration, deep%,
    /// REM%, bedtime consistency, efficiency.
    public static func computeSleep(db: Database, deviceID: Int) -> [Insight] {
        var out: [Insight] = []
        if let i = sleepScoreLastNight(db: db, deviceID: deviceID) { out.append(i) }
        if let i = sleepDurationLastNight(db: db, deviceID: deviceID) { out.append(i) }
        if let i = sleepDeepPercent(db: db, deviceID: deviceID) { out.append(i) }
        if let i = sleepREMPercent(db: db, deviceID: deviceID) { out.append(i) }
        if let i = sleepConsistencyScore(db: db, deviceID: deviceID) { out.append(i) }
        if let i = sleepEfficiencyWeek(db: db, deviceID: deviceID) { out.append(i) }
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

    // MARK: - Activities insights

    /// Sum of total_timer_s across all activities in the trailing 7 days,
    /// vs the prior 7 days. Reads as "5h 12m vs 4h 38m last week".
    private static func activeTimeWeek(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT start_time_utc, total_timer_s FROM activities
            WHERE device_id = ?
              AND total_timer_s IS NOT NULL
              AND start_time_utc >= datetime('now', '-14 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard !rows.isEmpty else { return nil }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var thisWeek = 0.0, lastWeek = 0.0
        for row in rows {
            guard let s = row.string("start_time_utc"),
                  let d = Database.iso8601.date(from: s),
                  let t = row.double("total_timer_s") else { continue }
            if d >= weekAgo { thisWeek += t } else { lastWeek += t }
        }
        let durHHMM: (Double) -> String = { secs in
            let total = Int(secs.rounded())
            let h = total / 3600, m = (total % 3600) / 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }
        let direction: Insight.Direction = thisWeek > lastWeek + 60 ? .up
            : (thisWeek < lastWeek - 60 ? .down : .flat)
        let severity: Insight.Severity = thisWeek > lastWeek ? .positive : .info
        return Insight(
            title: "Active time (7 d)",
            primaryValue: durHHMM(thisWeek),
            secondaryValue: lastWeek > 0 ? "vs \(durHHMM(lastWeek)) prior" : nil,
            direction: direction, severity: severity
        )
    }

    /// Sum of total_distance_m across all sports in the trailing 7 days.
    private static func distanceWeek(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT start_time_utc, total_distance_m FROM activities
            WHERE device_id = ?
              AND total_distance_m IS NOT NULL
              AND start_time_utc >= datetime('now', '-14 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard !rows.isEmpty else { return nil }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var thisWeek = 0.0, lastWeek = 0.0
        for row in rows {
            guard let s = row.string("start_time_utc"),
                  let d = Database.iso8601.date(from: s),
                  let dist = row.double("total_distance_m") else { continue }
            if d >= weekAgo { thisWeek += dist } else { lastWeek += dist }
        }
        let direction: Insight.Direction = thisWeek > lastWeek + 500 ? .up
            : (thisWeek < lastWeek - 500 ? .down : .flat)
        let severity: Insight.Severity = thisWeek > lastWeek ? .positive : .info
        return Insight(
            title: "Distance (7 d)",
            primaryValue: String(format: "%.1f km", thisWeek / 1000),
            secondaryValue: lastWeek > 0 ? String(format: "vs %.1f prior", lastWeek / 1000) : nil,
            direction: direction, severity: severity
        )
    }

    /// "5/7 days active" — count of distinct local-time days in the last 7
    /// that had at least one activity.
    private static func activeDays7d(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT DISTINCT date(start_time_utc, 'localtime') AS day FROM activities
            WHERE device_id = ?
              AND start_time_utc >= datetime('now', '-7 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        let days = rows.compactMap { $0.string("day") }.count
        let severity: Insight.Severity = days >= 5 ? .positive : (days < 2 ? .negative : .info)
        let direction: Insight.Direction = days >= 4 ? .up : (days < 2 ? .down : .flat)
        return Insight(
            title: "Active days",
            primaryValue: "\(days)/7",
            secondaryValue: nil,
            direction: direction, severity: severity
        )
    }

    /// "Load 280 vs 210 last 7d" — sum of training_load this week vs prior.
    private static func trainingLoadWeek(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT start_time_utc, training_load FROM activities
            WHERE device_id = ?
              AND training_load IS NOT NULL
              AND start_time_utc >= datetime('now', '-14 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard !rows.isEmpty else { return nil }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var thisWeek = 0.0, lastWeek = 0.0
        for row in rows {
            guard let s = row.string("start_time_utc"),
                  let d = Database.iso8601.date(from: s),
                  let l = row.double("training_load") else { continue }
            if d >= weekAgo { thisWeek += l } else { lastWeek += l }
        }
        let direction: Insight.Direction = thisWeek > lastWeek + 20 ? .up
            : (thisWeek < lastWeek - 20 ? .down : .flat)
        return Insight(
            title: "Training load (7 d)",
            primaryValue: String(format: "%.0f", thisWeek),
            secondaryValue: lastWeek > 0 ? String(format: "vs %.0f prior", lastWeek) : nil,
            direction: direction, severity: .info
        )
    }

    /// Average pace across all runs in the last 14 days, vs the 14 days
    /// before that. Both windows take the dist-weighted mean speed and
    /// invert to min/km. Skipped if either window has fewer than 2 runs.
    private static func avgRunPace14d(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT start_time_utc, total_distance_m, total_timer_s FROM activities
            WHERE device_id = ?
              AND sport = 'running'
              AND total_distance_m IS NOT NULL AND total_distance_m > 0
              AND total_timer_s   IS NOT NULL AND total_timer_s   > 0
              AND start_time_utc >= datetime('now', '-28 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard rows.count >= 2 else { return nil }
        let twoWeeksAgo = Date().addingTimeInterval(-14 * 86400)
        var recentDist = 0.0, recentTime = 0.0
        var priorDist = 0.0, priorTime = 0.0
        for row in rows {
            guard let s = row.string("start_time_utc"),
                  let d = Database.iso8601.date(from: s),
                  let dist = row.double("total_distance_m"),
                  let time = row.double("total_timer_s") else { continue }
            if d >= twoWeeksAgo { recentDist += dist; recentTime += time }
            else { priorDist += dist; priorTime += time }
        }
        guard recentDist > 0, recentTime > 0 else { return nil }
        let recentPace = recentTime / recentDist * 1000.0 / 60.0  // min/km
        let priorPace: Double? = (priorDist > 0 && priorTime > 0)
            ? priorTime / priorDist * 1000.0 / 60.0
            : nil
        let paceLabel: (Double) -> String = { p in
            let mins = Int(p)
            let secs = Int((p - Double(mins)) * 60)
            return String(format: "%d:%02d /km", mins, secs)
        }
        var direction: Insight.Direction = .flat
        var severity: Insight.Severity = .info
        var sub: String? = nil
        if let pp = priorPace {
            let delta = recentPace - pp
            // Faster pace = lower number = positive direction here.
            direction = delta < -0.05 ? .down : (delta > 0.05 ? .up : .flat)
            severity = delta < -0.1 ? .positive : (delta > 0.1 ? .negative : .info)
            sub = "vs \(paceLabel(pp)) prior"
        }
        return Insight(
            title: "Avg run pace (14 d)",
            primaryValue: paceLabel(recentPace),
            secondaryValue: sub,
            direction: direction, severity: severity
        )
    }

    /// Top-share sport in the trailing 30 days, by total active time.
    /// "Running 62% (12 acts)".
    private static func sportMix30d(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT sport, total_timer_s FROM activities
            WHERE device_id = ?
              AND sport IS NOT NULL
              AND total_timer_s IS NOT NULL
              AND start_time_utc >= datetime('now', '-30 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        guard !rows.isEmpty else { return nil }
        var bySport: [String: Double] = [:]
        var countsBySport: [String: Int] = [:]
        var total = 0.0
        for row in rows {
            guard let sport = row.string("sport"),
                  let t = row.double("total_timer_s") else { continue }
            bySport[sport, default: 0] += t
            countsBySport[sport, default: 0] += 1
            total += t
        }
        guard let top = bySport.max(by: { $0.value < $1.value }), total > 0 else { return nil }
        let pct = Int((top.value / total * 100).rounded())
        let count = countsBySport[top.key] ?? 0
        return Insight(
            title: "Top sport (30 d)",
            primaryValue: top.key.capitalized,
            secondaryValue: "\(pct)% · \(count) acts",
            direction: .flat, severity: .info
        )
    }

    // MARK: - Wellness insights

    /// "HRV 56 ms vs 52 over 7d" — last night's per-session HRV (mesg_num
    /// 371) compared against the prior 7-night mean.
    private static func hrvLastNight(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT date(timestamp_utc, 'localtime') AS date_local,
                   AVG(value) AS hrv_ms
            FROM wellness_samples
            WHERE device_id = ?
              AND metric = 'hrv_value_ms'
              AND value IS NOT NULL
              AND timestamp_utc >= datetime('now', '-14 days')
            GROUP BY date_local
            ORDER BY date_local DESC
            """, bind: [.int(Int64(deviceID))])) ?? []
        let pairs: [(date: String, hrv: Double)] = rows.compactMap { r in
            guard let d = r.string("date_local"), let v = r.double("hrv_ms") else { return nil }
            return (d, v)
        }
        guard let latest = pairs.first else { return nil }
        let prior = Array(pairs.dropFirst())
        guard prior.count >= 2 else {
            return Insight(
                title: "HRV (last night)",
                primaryValue: String(format: "%.0f ms", latest.hrv),
                secondaryValue: latest.date,
                direction: .flat, severity: .info
            )
        }
        let priorMean = prior.map { $0.hrv }.reduce(0, +) / Double(prior.count)
        let delta = latest.hrv - priorMean
        let direction: Insight.Direction = delta > 1.5 ? .up : (delta < -1.5 ? .down : .flat)
        let severity: Insight.Severity = delta > 3 ? .positive : (delta < -3 ? .negative : .info)
        return Insight(
            title: "HRV (last night)",
            primaryValue: String(format: "%.0f ms", latest.hrv),
            secondaryValue: String(format: "vs %.0f over %d nights", priorMean, prior.count),
            direction: direction, severity: severity
        )
    }

    /// "Stress 28 (7d) vs 35 prior" — 7-day mean stress vs preceding 7-day mean.
    private static func stressSevenDay(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT date_local, avg_stress
            FROM wellness_daily
            WHERE device_id = ?
              AND avg_stress IS NOT NULL
              AND date_local >= date('now', '-14 days')
            ORDER BY date_local DESC
            """, bind: [.int(Int64(deviceID))])) ?? []
        let values = rows.compactMap { $0.int("avg_stress").map(Double.init) }
        guard values.count >= 4 else { return nil }
        let recent = Array(values.prefix(7))
        let prior = Array(values.dropFirst(7))
        let recentMean = recent.reduce(0, +) / Double(recent.count)
        let priorMean = prior.isEmpty ? recentMean : prior.reduce(0, +) / Double(prior.count)
        let delta = recentMean - priorMean
        // Lower stress is the desirable direction.
        let direction: Insight.Direction = delta < -1 ? .down : (delta > 1 ? .up : .flat)
        let severity: Insight.Severity = delta < -3 ? .positive : (delta > 3 ? .negative : .info)
        let sub = prior.isEmpty ? "over \(recent.count) days" : String(format: "vs %.0f prior 7d", priorMean)
        return Insight(
            title: "Stress (7 d)",
            primaryValue: String(format: "%.0f", recentMean),
            secondaryValue: sub,
            direction: direction, severity: severity
        )
    }

    /// "Intensity: 87 / 150 min this week" — sum of intensity minutes from
    /// wellness_daily over the trailing 7 days.
    private static func intensityMinutesWeek(db: Database, deviceID: Int) -> Insight? {
        let total = (try? db.scalarInt("""
            SELECT SUM(intensity_min) FROM wellness_daily
            WHERE device_id = ?
              AND intensity_min IS NOT NULL
              AND date_local >= date('now', '-7 days')
            """, bind: [.int(Int64(deviceID))])) ?? nil
        guard let n = total, n >= 0 else { return nil }
        let pct = Double(n) / 150.0
        let severity: Insight.Severity = pct >= 1.0 ? .positive : (pct < 0.4 ? .negative : .info)
        let direction: Insight.Direction = pct >= 1.0 ? .up : (pct < 0.5 ? .down : .flat)
        return Insight(
            title: "Intensity (7 d)",
            primaryValue: "\(n) / 150 min",
            secondaryValue: String(format: "%.0f%% of weekly goal", pct * 100),
            direction: direction, severity: severity
        )
    }

    /// "SpO2 96% (7d)" — average SpO2 over the trailing 7 days. Returns nil
    /// when nothing is recorded — Instinct 3 only emits SpO2 if the user has
    /// pulse-ox enabled, so most archives won't have any.
    private static func spo2SevenDay(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT spo2_avg FROM wellness_daily
            WHERE device_id = ?
              AND spo2_avg IS NOT NULL
              AND date_local >= date('now', '-7 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        let values = rows.compactMap { $0.int("spo2_avg").map(Double.init) }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let severity: Insight.Severity = mean >= 95 ? .positive : (mean < 90 ? .negative : .info)
        return Insight(
            title: "SpO2 (7 d)",
            primaryValue: String(format: "%.0f%%", mean),
            secondaryValue: "over \(values.count) days",
            direction: .flat, severity: severity
        )
    }

    // MARK: - Sleep insights

    /// "Score 78 vs 73 over 7d"
    private static func sleepScoreLastNight(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT sleep_score FROM sleep_sessions
            WHERE device_id = ? AND sleep_score IS NOT NULL
            ORDER BY start_utc DESC LIMIT 8
            """, bind: [.int(Int64(deviceID))])) ?? []
        let scores = rows.compactMap { $0.int("sleep_score") }
        guard let latest = scores.first else { return nil }
        let prior = Array(scores.dropFirst())
        guard !prior.isEmpty else {
            return Insight(
                title: "Sleep score",
                primaryValue: "\(latest)",
                secondaryValue: nil,
                direction: .flat,
                severity: latest >= 85 ? .positive : (latest < 60 ? .negative : .info)
            )
        }
        let priorMean = Double(prior.reduce(0, +)) / Double(prior.count)
        let delta = Double(latest) - priorMean
        let direction: Insight.Direction = delta > 1.5 ? .up : (delta < -1.5 ? .down : .flat)
        let severity: Insight.Severity = delta > 3 ? .positive : (delta < -3 ? .negative : .info)
        return Insight(
            title: "Sleep score",
            primaryValue: "\(latest)",
            secondaryValue: String(format: "vs %.0f over %d nights", priorMean, prior.count),
            direction: direction, severity: severity
        )
    }

    /// "7h 12m vs 6h 51m over 7d"
    private static func sleepDurationLastNight(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT deep_s, light_s, rem_s
            FROM sleep_sessions
            WHERE device_id = ?
            ORDER BY start_utc DESC LIMIT 8
            """, bind: [.int(Int64(deviceID))])) ?? []
        let durations: [Double] = rows.compactMap { r in
            guard let d = r.int("deep_s"), let l = r.int("light_s"), let m = r.int("rem_s")
            else { return nil }
            return Double(d + l + m)
        }
        guard let latest = durations.first, latest > 0 else { return nil }
        let prior = Array(durations.dropFirst())
        let durHHMM: (Double) -> String = { secs in
            let total = Int(secs.rounded())
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
        guard !prior.isEmpty else {
            return Insight(
                title: "Asleep (last night)",
                primaryValue: durHHMM(latest),
                secondaryValue: nil,
                direction: .flat, severity: .info
            )
        }
        let priorMean = prior.reduce(0, +) / Double(prior.count)
        let delta = latest - priorMean
        let direction: Insight.Direction = delta > 600 ? .up : (delta < -600 ? .down : .flat)
        let severity: Insight.Severity = delta > 1200 ? .positive : (delta < -1200 ? .negative : .info)
        return Insight(
            title: "Asleep (last night)",
            primaryValue: durHHMM(latest),
            secondaryValue: "vs \(durHHMM(priorMean)) over \(prior.count) nights",
            direction: direction, severity: severity
        )
    }

    /// "Deep 22% vs 18% over 30d"
    private static func sleepDeepPercent(db: Database, deviceID: Int) -> Insight? {
        return stagePercentInsight(db: db, deviceID: deviceID, stageColumn: "deep_s", title: "Deep sleep")
    }

    /// "REM 21% vs 19% over 30d"
    private static func sleepREMPercent(db: Database, deviceID: Int) -> Insight? {
        return stagePercentInsight(db: db, deviceID: deviceID, stageColumn: "rem_s", title: "REM sleep")
    }

    private static func stagePercentInsight(
        db: Database, deviceID: Int, stageColumn: String, title: String
    ) -> Insight? {
        let rows = (try? db.query("""
            SELECT \(stageColumn) AS stage_s, deep_s, light_s, rem_s
            FROM sleep_sessions
            WHERE device_id = ?
              AND deep_s IS NOT NULL
              AND light_s IS NOT NULL
              AND rem_s IS NOT NULL
              AND start_utc >= datetime('now', '-30 days')
            ORDER BY start_utc DESC
            """, bind: [.int(Int64(deviceID))])) ?? []
        let pcts: [Double] = rows.compactMap { r in
            guard let s = r.int("stage_s"),
                  let d = r.int("deep_s"),
                  let l = r.int("light_s"),
                  let m = r.int("rem_s") else { return nil }
            let total = d + l + m
            guard total > 0 else { return nil }
            return Double(s) * 100.0 / Double(total)
        }
        guard let latest = pcts.first else { return nil }
        let prior = Array(pcts.dropFirst())
        guard !prior.isEmpty else {
            return Insight(
                title: title,
                primaryValue: String(format: "%.0f%%", latest),
                secondaryValue: nil,
                direction: .flat, severity: .info
            )
        }
        let priorMean = prior.reduce(0, +) / Double(prior.count)
        let delta = latest - priorMean
        let direction: Insight.Direction = delta > 1 ? .up : (delta < -1 ? .down : .flat)
        let severity: Insight.Severity = delta > 2 ? .positive : (delta < -2 ? .negative : .info)
        return Insight(
            title: title,
            primaryValue: String(format: "%.0f%%", latest),
            secondaryValue: String(format: "vs %.0f%% over %d nights", priorMean, prior.count),
            direction: direction, severity: severity
        )
    }

    /// "Efficiency 92% over 7 nights" — asleep / (asleep + awake) averaged
    /// over the trailing week.
    private static func sleepEfficiencyWeek(db: Database, deviceID: Int) -> Insight? {
        let rows = (try? db.query("""
            SELECT deep_s, light_s, rem_s, awake_s
            FROM sleep_sessions
            WHERE device_id = ?
              AND deep_s IS NOT NULL
              AND awake_s IS NOT NULL
              AND start_utc >= datetime('now', '-7 days')
            """, bind: [.int(Int64(deviceID))])) ?? []
        var pcts: [Double] = []
        for r in rows {
            guard let d = r.int("deep_s"),
                  let l = r.int("light_s"),
                  let m = r.int("rem_s"),
                  let a = r.int("awake_s") else { continue }
            let asleep = d + l + m
            let inBed = asleep + a
            guard inBed > 0 else { continue }
            pcts.append(Double(asleep) * 100.0 / Double(inBed))
        }
        guard !pcts.isEmpty else { return nil }
        let mean = pcts.reduce(0, +) / Double(pcts.count)
        let severity: Insight.Severity = mean >= 90 ? .positive : (mean < 80 ? .negative : .info)
        return Insight(
            title: "Sleep efficiency",
            primaryValue: String(format: "%.0f%%", mean),
            secondaryValue: "over \(pcts.count) nights",
            direction: .flat, severity: severity
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
