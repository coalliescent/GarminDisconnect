// Queries.swift
//
// Single source of truth for every SQL query the app runs. Grouped by tab so
// the audit story is easy to follow:
//   - every aggregate must filter `WHERE <field> IS NOT NULL`
//   - every time series passes its raw rows through `DateUtil.fillGaps` before
//     reaching Plotly, so missing days appear as visible breaks (the "show the
//     data, not the lack of data" rule)
//   - never `COALESCE(...,0)` for missing wellness fields
//
// All `?` placeholders are bound positionally in the order the comment above
// each query lists.

import Foundation

public enum Queries {

    // MARK: - Overview

    /// Daily steps for all days the watch was worn. Bind: device_id.
    public static let overviewDailySteps = """
        SELECT date_local, steps
        FROM wellness_daily
        WHERE device_id = ?
          AND steps IS NOT NULL
        ORDER BY date_local
        """

    /// Daily steps within an explicit `[start, end]` window (inclusive).
    /// Bind: device_id, start_date_local, end_date_local.
    public static let overviewDailyStepsWindowed = """
        SELECT date_local, steps
        FROM wellness_daily
        WHERE device_id = ?
          AND steps IS NOT NULL
          AND date_local >= ?
          AND date_local <= ?
        ORDER BY date_local
        """

    /// Resting HR for the trailing 90 days. Bind: device_id.
    public static let overviewRestingHR90d = """
        SELECT date_local, resting_hr
        FROM wellness_daily
        WHERE device_id = ?
          AND resting_hr IS NOT NULL
          AND date_local >= date('now', '-90 days')
        ORDER BY date_local
        """

    /// Resting HR within an explicit window. Bind: device_id, start, end.
    public static let overviewRestingHRWindowed = """
        SELECT date_local, resting_hr
        FROM wellness_daily
        WHERE device_id = ?
          AND resting_hr IS NOT NULL
          AND date_local >= ?
          AND date_local <= ?
        ORDER BY date_local
        """

    /// Most recent wellness day's body battery min/max for the gauge.
    /// Bind: device_id.
    public static let overviewLatestBodyBattery = """
        SELECT date_local, body_battery_min, body_battery_max
        FROM wellness_daily
        WHERE device_id = ?
          AND body_battery_max IS NOT NULL
        ORDER BY date_local DESC
        LIMIT 1
        """

    /// Activities in the trailing 14 days for the timeline. Bind: device_id.
    public static let overviewRecentActivities14d = """
        SELECT activity_id, start_time_utc, end_time_utc, sport,
               total_distance_m, total_timer_s
        FROM activities
        WHERE device_id = ?
          AND start_time_utc >= datetime('now', '-14 days')
        ORDER BY start_time_utc
        """

    /// Activities within an explicit window. Bind: device_id, start_iso, end_iso.
    public static let overviewRecentActivitiesWindowed = """
        SELECT activity_id, start_time_utc, end_time_utc, sport,
               total_distance_m, total_timer_s
        FROM activities
        WHERE device_id = ?
          AND start_time_utc >= ?
          AND start_time_utc <= ?
        ORDER BY start_time_utc
        """

    // MARK: - Activities tab

    /// Last 200 activities, newest first. Bind: device_id.
    public static let activitiesList = """
        SELECT activity_id, start_time_utc, sport, sub_sport,
               total_distance_m, total_timer_s, avg_hr, max_hr,
               training_load
        FROM activities
        WHERE device_id = ?
        ORDER BY start_time_utc DESC
        LIMIT 200
        """

    /// All records for one activity, ordered by timestamp.
    ///
    /// `elapsed_s` falls back to a computed value when the column is NULL —
    /// garmin-dump only populates it from the FIT `elapsed_time` field,
    /// which the Instinct 3 firmware doesn't always emit on records. The
    /// COALESCE here keeps every downstream chart and analytic working off
    /// a single integer "seconds since activity start" regardless of which
    /// firmware wrote the file.
    ///
    /// Bind: activity_id.
    public static let activityRecords = """
        SELECT timestamp_utc,
               COALESCE(
                   elapsed_s,
                   CAST(ROUND((julianday(timestamp_utc)
                               - julianday(MIN(timestamp_utc) OVER ())) * 86400.0) AS INTEGER)
               ) AS elapsed_s,
               lat_deg, lon_deg, altitude_m,
               distance_m, speed_mps, heart_rate, cadence, power_w
        FROM activity_records
        WHERE activity_id = ?
        ORDER BY timestamp_utc
        """

    /// Per-activity metadata used by the trim heuristic and the trim controls
    /// payload. Bind: activity_id.
    public static let activityMeta = """
        SELECT sport, sub_sport, start_time_utc, total_timer_s
        FROM activities
        WHERE activity_id = ?
        """

    /// Weekly distance broken down by sport for the trailing 16 weeks.
    /// Bind: device_id.
    public static let weeklyDistanceBySport = """
        SELECT strftime('%Y-%W', start_time_utc) AS yearweek,
               sport,
               SUM(total_distance_m) / 1000.0 AS km
        FROM activities
        WHERE device_id = ?
          AND start_time_utc >= datetime('now', '-112 days')
          AND total_distance_m IS NOT NULL
        GROUP BY yearweek, sport
        ORDER BY yearweek
        """

    /// Weekly distance broken down by sport within an explicit window.
    /// Bind: device_id, start_iso, end_iso.
    public static let weeklyDistanceBySportWindowed = """
        SELECT strftime('%Y-%W', start_time_utc) AS yearweek,
               sport,
               SUM(total_distance_m) / 1000.0 AS km
        FROM activities
        WHERE device_id = ?
          AND start_time_utc >= ?
          AND start_time_utc <= ?
          AND total_distance_m IS NOT NULL
        GROUP BY yearweek, sport
        ORDER BY yearweek
        """

    // MARK: - Wellness tab

    /// Stress + body battery samples for the trailing 30 days.
    /// Bind: device_id.
    public static let wellnessStressAndBodyBattery30d = """
        SELECT timestamp_utc, metric, value
        FROM wellness_samples
        WHERE device_id = ?
          AND metric IN ('stress_level', 'body_battery_level')
          AND value IS NOT NULL
          AND timestamp_utc >= datetime('now', '-30 days')
        ORDER BY timestamp_utc
        """

    /// Stress + body battery samples within an explicit window.
    /// Bind: device_id, start_iso, end_iso.
    public static let wellnessStressAndBodyBatteryWindowed = """
        SELECT timestamp_utc, metric, value
        FROM wellness_samples
        WHERE device_id = ?
          AND metric IN ('stress_level', 'body_battery_level')
          AND value IS NOT NULL
          AND timestamp_utc >= ?
          AND timestamp_utc <= ?
        ORDER BY timestamp_utc
        """

    /// Daily intensity minutes for the trailing 8 weeks. Bind: device_id.
    public static let wellnessIntensityMinutes8w = """
        SELECT date_local, intensity_min
        FROM wellness_daily
        WHERE device_id = ?
          AND intensity_min IS NOT NULL
          AND date_local >= date('now', '-56 days')
        ORDER BY date_local
        """

    /// Daily intensity minutes within an explicit window.
    /// Bind: device_id, start_date_local, end_date_local.
    public static let wellnessIntensityMinutesWindowed = """
        SELECT date_local, intensity_min
        FROM wellness_daily
        WHERE device_id = ?
          AND intensity_min IS NOT NULL
          AND date_local >= ?
          AND date_local <= ?
        ORDER BY date_local
        """

    /// Hourly heart-rate samples for the trailing 90 days. We aggregate to
    /// (day-of-week, hour-of-day) buckets in Swift to build the heatmap, since
    /// SQLite's strftime() makes the SQL side simple. Bind: device_id.
    public static let wellnessIntradayHR90d = """
        SELECT timestamp_utc, value
        FROM wellness_samples
        WHERE device_id = ?
          AND metric = 'heart_rate'
          AND value IS NOT NULL
          AND timestamp_utc >= datetime('now', '-90 days')
        """

    /// Hourly heart-rate samples within an explicit window.
    /// Bind: device_id, start_iso, end_iso.
    public static let wellnessIntradayHRWindowed = """
        SELECT timestamp_utc, value, local_offset_s
        FROM wellness_samples
        WHERE device_id = ?
          AND metric = 'heart_rate'
          AND value IS NOT NULL
          AND timestamp_utc >= ?
          AND timestamp_utc <= ?
        """

    // MARK: - Sleep tab

    /// Most recent sleep session for the hypnogram. Bind: device_id.
    public static let sleepLatestSession = """
        SELECT sleep_id, start_utc, end_utc, sleep_score,
               deep_s, light_s, rem_s, awake_s
        FROM sleep_sessions
        WHERE device_id = ?
        ORDER BY start_utc DESC
        LIMIT 1
        """

    /// Stages for one sleep session. Bind: sleep_id.
    public static let sleepStagesForSession = """
        SELECT start_utc, end_utc, stage
        FROM sleep_stages
        WHERE sleep_id = ?
        ORDER BY start_utc
        """

    /// Sleep sessions in the trailing 60 days for the regularity heatmap.
    /// Bind: device_id.
    public static let sleepSessions60d = """
        SELECT start_utc, end_utc, sleep_score, local_offset_s
        FROM sleep_sessions
        WHERE device_id = ?
          AND start_utc >= datetime('now', '-60 days')
        ORDER BY start_utc
        """

    /// Sleep sessions within an explicit window.
    /// Bind: device_id, start_iso, end_iso.
    public static let sleepSessionsWindowed = """
        SELECT start_utc, end_utc, sleep_score, local_offset_s
        FROM sleep_sessions
        WHERE device_id = ?
          AND start_utc >= ?
          AND start_utc <= ?
        ORDER BY start_utc
        """

    // MARK: - Sync tab

    /// Last 50 garmin-dump runs for the audit table. No bind args.
    public static let syncRunsHistory = """
        SELECT run_id, started_utc, finished_utc, subcommand,
               files_downloaded, bytes_downloaded, errors_count, exit_code
        FROM runs
        ORDER BY started_utc DESC
        LIMIT 50
        """

    /// Most recent successful pull for "last sync N hours ago". No bind args.
    public static let syncLastSuccessfulPull = """
        SELECT MAX(finished_utc)
        FROM runs
        WHERE subcommand = 'pull'
          AND exit_code = 0
        """
}
