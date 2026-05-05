// ChartWindow.swift
//
// Per-chart "interval + anchor" state for the time-series charts in the
// viewer. Every chart that shows data over time can be re-windowed at runtime
// by the user via:
//
//     ◀ [ Day | Week | Month | Year ] ▶
//
// `interval` controls window width, `endDate` is the right edge of the
// window (inclusive). The user shifts the window with the ◀/▶ arrows; the
// interval choice itself persists in UserDefaults so a relaunch picks the
// same Day/Week/Month/Year mode the user prefers, but `endDate` deliberately
// resets to "today" on every launch — the user always sees their most
// recent data first.
//
// All Calendar math is done in `DateUtil.calendar` (UTC, Sunday-start) so
// it lines up with the SQL date math (`date('now', '-N days')`).

import Foundation

public enum ChartInterval: String, CaseIterable {
    case day, week, month, year, all

    /// Display label for the interval-picker tab strip.
    public var displayLabel: String {
        switch self {
        case .day:   return "Day"
        case .week:  return "Week"
        case .month: return "Month"
        case .year:  return "Year"
        case .all:   return "All"
        }
    }

    /// Number of days in the window (or 0 for `.all`, which is unbounded).
    public var spanDays: Int {
        switch self {
        case .day:   return 1
        case .week:  return 7
        case .month: return 30
        case .year:  return 365
        case .all:   return 0
        }
    }
}

public struct ChartWindow {
    public let interval: ChartInterval
    /// The right edge of the window, inclusive. Always normalized to UTC
    /// midnight so windowed SQL queries get a stable end-of-day boundary.
    public let endDate: Date

    public init(interval: ChartInterval, endDate: Date) {
        self.interval = interval
        self.endDate = DateUtil.calendar.startOfDay(for: endDate)
    }

    /// The left edge of the window, inclusive. Returns the unix epoch for
    /// `.all` so callers can pass it through to a SQL >= comparison.
    public var startDate: Date {
        switch interval {
        case .day:
            return endDate
        case .week, .month, .year:
            return DateUtil.adding(days: -(interval.spanDays - 1), to: endDate)
        case .all:
            return Date(timeIntervalSince1970: 0)
        }
    }

    /// Right edge expressed as an ISO timestamp at end-of-day, for queries
    /// keyed by `timestamp_utc` columns. We compare the window's full last
    /// day inclusively, so the upper bound is `endDate + 24h`.
    public var endTimestampISO: String {
        let nextDay = DateUtil.adding(days: 1, to: endDate)
        return Database.iso8601.string(from: nextDay)
    }

    /// Left edge expressed as an ISO timestamp at midnight UTC.
    public var startTimestampISO: String {
        return Database.iso8601.string(from: startDate)
    }

    /// Right edge as a `YYYY-MM-DD` local date string, for queries keyed by
    /// `date_local` columns.
    public var endDateLocal: String {
        return DateUtil.dayString(from: endDate)
    }

    /// Left edge as a `YYYY-MM-DD` local date string.
    public var startDateLocal: String {
        return DateUtil.dayString(from: startDate)
    }

    /// Shift the window by `delta` units of its current interval. Negative
    /// = older, positive = newer. `.all` doesn't shift.
    public func shifted(by delta: Int) -> ChartWindow {
        guard interval != .all, delta != 0 else { return self }
        let newEnd = DateUtil.adding(days: delta * interval.spanDays, to: endDate)
        return ChartWindow(interval: interval, endDate: newEnd)
    }

    /// Human-readable label for the window's right edge / range. Used in the
    /// interval-picker strip so the user always knows what they're looking at.
    public var label: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = DateUtil.calendar.timeZone
        switch interval {
        case .day:
            f.dateFormat = "MMM d, yyyy"
            return f.string(from: endDate)
        case .week:
            f.dateFormat = "MMM d"
            let s = f.string(from: startDate)
            f.dateFormat = "MMM d, yyyy"
            let e = f.string(from: endDate)
            return "\(s) – \(e)"
        case .month:
            f.dateFormat = "MMM d"
            let s = f.string(from: startDate)
            f.dateFormat = "MMM d, yyyy"
            let e = f.string(from: endDate)
            return "\(s) – \(e)"
        case .year:
            f.dateFormat = "MMM yyyy"
            let s = f.string(from: startDate)
            let e = f.string(from: endDate)
            return "\(s) – \(e)"
        case .all:
            return "All time"
        }
    }
}

/// Singleton that owns the per-chart interval + anchor state. Interval
/// persists in `UserDefaults`; anchor is in-memory only and is reset to
/// "today" on every launch.
public final class ChartWindowStore {

    public static let shared = ChartWindowStore()

    private var windows: [String: ChartWindow] = [:]
    private let defaultsKey = "GarminDisconnect.chartInterval"

    private init() {}

    /// Return the active window for `chartID`. On first call this:
    ///   - reads the interval from UserDefaults (or uses `defaultInterval`)
    ///   - sets the anchor to "today" (most recent data)
    /// Subsequent calls return the cached value (potentially mutated by
    /// `setInterval` or `shift`).
    public func window(
        for chartID: String,
        defaultInterval: ChartInterval
    ) -> ChartWindow {
        if let existing = windows[chartID] { return existing }
        let key = "\(defaultsKey).\(chartID)"
        let raw = UserDefaults.standard.string(forKey: key) ?? defaultInterval.rawValue
        let interval = ChartInterval(rawValue: raw) ?? defaultInterval
        let w = ChartWindow(interval: interval, endDate: Date())
        windows[chartID] = w
        return w
    }

    /// User picked a new interval from the chart's tab strip. Persist the
    /// choice and reset the anchor to "today".
    public func setInterval(_ chartID: String, interval: ChartInterval) {
        let key = "\(defaultsKey).\(chartID)"
        UserDefaults.standard.set(interval.rawValue, forKey: key)
        windows[chartID] = ChartWindow(interval: interval, endDate: Date())
    }

    /// User clicked ◀ or ▶ on the chart's tab strip. `delta` is in units of
    /// the current interval (-1 = one interval older, +1 = one newer).
    public func shift(_ chartID: String, by delta: Int) {
        guard let current = windows[chartID] else { return }
        windows[chartID] = current.shifted(by: delta)
    }

    /// Reset every chart's window state — used by the test suite if needed.
    public func resetAll() {
        windows.removeAll()
    }
}
