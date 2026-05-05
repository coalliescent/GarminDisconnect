// TabLoaders.swift
//
// Per-tab functions that build the full set of chart payloads for that tab in
// one call. They're pure functions: take a Database + deviceID, return an
// array of `[String: Any]` payloads ready to ship to WebChartView.
//
// Each loader catches per-chart errors and converts them to `emptyPayload`
// entries so a single bad chart doesn't tank the whole tab. Errors are logged
// to the console (and visible in Console.app) but don't propagate.

import Foundation

enum TabLoaders {

    /// Build payloads for the Overview tab.
    /// Includes: daily-steps-bar, resting-hr-trendline, body-battery-gauge,
    /// recent-activities-timeline, weekly-distance-bar. Insight cards come
    /// from InsightEngine in `loadOverviewInsights`.
    static func loadOverview(db: Database, deviceID: Int) -> [[String: Any]] {
        return [
            tryEncode(chart: "daily-steps-bar") {
                try PlotlyEncoder.dailyStepsBar(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "resting-hr-trendline") {
                try PlotlyEncoder.restingHRTrendline(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "body-battery-gauge") {
                try PlotlyEncoder.bodyBatteryGauge(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "recent-activities-timeline") {
                try PlotlyEncoder.recentActivitiesTimeline(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "weekly-distance-bar") {
                try PlotlyEncoder.weeklyDistanceBar(from: db, deviceID: deviceID)
            },
        ]
    }

    /// Build the insight-cards payload from InsightEngine. Separate from the
    /// other Overview charts because it has its own caching layer.
    static func loadOverviewInsights(db: Database, deviceID: Int) -> [String: Any] {
        let insights = InsightEngine.compute(db: db, deviceID: deviceID)
        return [
            "chart": "insight-cards",
            "insights": insights.map { i -> [String: Any] in
                return [
                    "title": i.title,
                    "value": i.primaryValue,
                    "sub": i.secondaryValue ?? "",
                    "direction": i.direction.rawValue,
                    "severity": i.severity.rawValue,
                ]
            },
        ]
    }

    /// Build payloads for the Activities tab. The weekly-distance-bar chart
    /// lives on the Overview tab now; the Activities tab is just the
    /// sidebar list + selected-activity detail.
    static func loadActivities(db: Database, deviceID: Int) -> [[String: Any]] {
        return [
            tryEncode(chart: "activity-list") {
                try PlotlyEncoder.activityListPayload(from: db, deviceID: deviceID)
            },
        ]
    }

    /// Build payloads for the activity-detail sub-section. Called when the
    /// user clicks an activity-list row.
    ///
    /// Resolves the trim once (load existing or run autotrim heuristic on
    /// first view) and passes it into each encoder so all four payloads
    /// agree on what's clipped.
    static func loadActivityDetail(db: Database, activityID: Int) -> [[String: Any]] {
        let trim = resolveActivityTrim(db: db, activityID: activityID)
        return [
            tryEncode(chart: "activity-pace-altitude") {
                try PlotlyEncoder.activityPaceAltitude(from: db, activityID: activityID, trim: trim)
            },
            tryEncode(chart: "activity-hr-zones") {
                try PlotlyEncoder.activityHRZones(from: db, activityID: activityID, trim: trim)
            },
            tryEncode(chart: "activity-gps-map") {
                try PlotlyEncoder.activityGPSMap(from: db, activityID: activityID, trim: trim)
            },
            tryEncode(chart: "activity-trim-controls") {
                try PlotlyEncoder.activityTrimControls(from: db, activityID: activityID, trim: trim)
            },
        ]
    }

    /// Look up the user's saved trim for this activity. If none, run the
    /// autotrim heuristic on the raw records — and if it produces a trim,
    /// persist it (with `auto: true`) so the heuristic doesn't re-fire on
    /// every view.
    private static func resolveActivityTrim(db: Database, activityID: Int) -> TrimState? {
        if let existing = ActivityTrim.load(db: db, activityID: activityID) {
            return existing
        }
        do {
            let metaRow = try db.queryOne(Queries.activityMeta, bind: [.int(Int64(activityID))])
            let sport = metaRow?.string("sport")
            let rows = try db.query(Queries.activityRecords, bind: [.int(Int64(activityID))])
            let samples = rows.compactMap { row -> ActivityTrim.AutoTrimSample? in
                guard let e = row.int("elapsed_s") else { return nil }
                return ActivityTrim.AutoTrimSample(
                    elapsedS: e,
                    speedMps: row.double("speed_mps")
                )
            }
            if let auto = ActivityTrim.autoTrim(sport: sport, samples: samples) {
                ActivityTrim.save(db: db, activityID: activityID, state: auto)
                return auto
            }
        } catch {
            print("TabLoaders.resolveActivityTrim failed: \(error)")
        }
        return nil
    }

    /// Build payloads for the Wellness tab.
    static func loadWellness(db: Database, deviceID: Int) -> [[String: Any]] {
        return [
            tryEncode(chart: "stress-body-battery-ts") {
                try PlotlyEncoder.stressBodyBatteryTS(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "daily-intensity-minutes-bar") {
                try PlotlyEncoder.dailyIntensityMinutesBar(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "steps-hourly-heatmap") {
                try PlotlyEncoder.hourlyHRHeatmap(from: db, deviceID: deviceID)
            },
        ]
    }

    /// Build payloads for the Sleep tab.
    static func loadSleep(db: Database, deviceID: Int) -> [[String: Any]] {
        return [
            tryEncode(chart: "sleep-hypnogram") {
                try PlotlyEncoder.sleepHypnogram(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-regularity-heatmap") {
                try PlotlyEncoder.sleepRegularityHeatmap(from: db, deviceID: deviceID)
            },
        ]
    }

    /// Build payloads for the Sync tab. Doesn't need a device — runs are
    /// device-agnostic.
    static func loadSync(db: Database, deviceID: Int?, busy: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        out.append(tryEncode(chart: "sync-summary") {
            try PlotlyEncoder.syncSummaryPayload(from: db, deviceID: deviceID, busy: busy)
        })
        out.append(tryEncode(chart: "sync-runs") {
            try PlotlyEncoder.syncRunsPayload(from: db)
        })
        return out
    }

    // MARK: - Helpers

    /// Run a builder closure, returning either its payload or an empty-state
    /// payload tagged with the failure message. Used by every loader so a
    /// single bad chart doesn't break a whole tab.
    private static func tryEncode(
        chart: String,
        _ build: () throws -> [String: Any]
    ) -> [String: Any] {
        do {
            return try build()
        } catch {
            print("TabLoaders: \(chart) failed: \(error)")
            return PlotlyEncoder.emptyPayload(
                chartID: chart,
                message: "Failed to load: \(error)"
            )
        }
    }
}
