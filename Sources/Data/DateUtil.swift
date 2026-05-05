// DateUtil.swift
//
// Date helpers used by the chart data pipeline. Two main jobs:
//
//  1. ISO-8601 ↔ Date conversion. garmin-dump stores everything as ISO strings,
//     so we parse them once at the database boundary.
//  2. Gap detection / fill. Time-series charts need a contiguous, dense array of
//     `(date, value?)` pairs so Plotly can draw visible gaps for missing days.
//     `fillGaps()` is the chokepoint that enforces the "show the data, not the
//     lack of data" rule.

import Foundation

public enum DateUtil {

    /// UTC calendar pinned to the Gregorian system. Created once and reused.
    /// Used for date math that has to match SQLite's `date('now', '-N days')`
    /// and other UTC-anchored persistence.
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        c.firstWeekday = 1  // Sunday — matches GitHub-style calendar heatmaps
        return c
    }()

    /// Build a Gregorian calendar pinned to a specific TZ offset (signed
    /// seconds east-of-UTC, e.g. -25200 for PDT). Used by the chart code
    /// when it has to ask "what hour-of-day was this in the wearer's local
    /// zone?" and the per-row offset is available from the database.
    ///
    /// When `offsetSeconds` is nil, falls back to `TimeZone.current` so the
    /// charts still display sensible times for users whose archive predates
    /// the schema-v2 `local_offset_s` columns.
    public static func localCalendar(offsetSeconds: Int?) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        if let s = offsetSeconds, let tz = TimeZone(secondsFromGMT: s) {
            c.timeZone = tz
        } else {
            c.timeZone = TimeZone.current
        }
        c.firstWeekday = 1
        return c
    }

    /// Date formatter that emits "YYYY-MM-DD" strings (the format garmin-dump
    /// uses for `wellness_daily.date_local`).
    public static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Parse a `YYYY-MM-DD` string into a Date at midnight UTC. Returns nil if the
    /// string isn't in the expected format.
    public static func day(from string: String) -> Date? {
        return dayFormatter.date(from: string)
    }

    /// Format a Date as `YYYY-MM-DD`.
    public static func dayString(from date: Date) -> String {
        return dayFormatter.string(from: date)
    }

    /// Day of the week, 0 = Sunday … 6 = Saturday. Matches the row index our
    /// calendar heatmap uses.
    public static func dayOfWeek(_ date: Date) -> Int {
        // Calendar.component(.weekday) returns 1=Sun..7=Sat. Subtract 1 for 0-indexed.
        return calendar.component(.weekday, from: date) - 1
    }

    /// Distance in whole days between `from` and `to`. Negative if `to` is earlier.
    public static func daysBetween(_ from: Date, _ to: Date) -> Int {
        let comps = calendar.dateComponents([.day], from: from, to: to)
        return comps.day ?? 0
    }

    /// Add `n` days to a date.
    public static func adding(days: Int, to date: Date) -> Date {
        return calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// First Sunday on or before `date`. Used to align the start of a calendar
    /// heatmap to a column of Sundays.
    public static func firstSundayOnOrBefore(_ date: Date) -> Date {
        let dow = dayOfWeek(date)
        return adding(days: -dow, to: date)
    }

    // MARK: - Gap fill

    /// One element in a dense, gap-filled time series. `value == nil` means
    /// "no data on this day" — render as a visible break, not as zero.
    public struct DayValue {
        public let date: Date
        public let value: Double?
        public init(date: Date, value: Double?) {
            self.date = date
            self.value = value
        }
    }

    /// Take an irregular `(date, value)` series and turn it into a dense series
    /// covering every day from `start` through `end` inclusive. Days the input
    /// doesn't mention get a `nil` value — Plotly will render them as visible
    /// gaps when `connectgaps: false`.
    ///
    /// Both `start` and `end` are clamped to the actual range of the input. If
    /// the caller wants a window like "last 90 days" wider than the input, that's
    /// fine — they just get fewer cells than they asked for, with the gap on the
    /// "we don't have data here yet" side. Padding the entire requested window
    /// would be misleading.
    public static func fillGaps(
        _ rows: [(date: Date, value: Double?)],
        start: Date? = nil,
        end: Date? = nil
    ) -> [DayValue] {
        guard !rows.isEmpty else { return [] }
        // Build a lookup table keyed on the day-string (cheaper than Date hashing).
        var byKey: [String: Double?] = [:]
        for r in rows {
            byKey[dayString(from: r.date)] = r.value
        }

        let sortedDates = rows.map { $0.date }.sorted()
        let minDate = sortedDates.first!
        let maxDate = sortedDates.last!

        let lo: Date = {
            guard let s = start, s > minDate else { return minDate }
            return s
        }()
        let hi: Date = {
            guard let e = end, e < maxDate else { return maxDate }
            return e
        }()

        var result: [DayValue] = []
        var cursor = lo
        while cursor <= hi {
            let key = dayString(from: cursor)
            result.append(DayValue(date: cursor, value: byKey[key] ?? nil))
            cursor = adding(days: 1, to: cursor)
        }
        return result
    }
}
