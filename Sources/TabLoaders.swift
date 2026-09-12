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
        let insights = InsightEngine.computeOverview(db: db, deviceID: deviceID)
        return insightsPayload(containerID: "overview-insights", insights: insights)
    }

    /// Build payloads for the Activities tab. The weekly-distance-bar chart
    /// lives on the Overview tab now; the Activities tab is just the
    /// sidebar list + selected-activity detail.
    ///
    /// `selectedActivityIDs` is forwarded to the JS list renderer so each
    /// selected row carries the `.selected` class on first paint (without it
    /// the auto-selected default activity would have no visual indicator in
    /// the sidebar). More than one id means a cmd+clicked group.
    static func loadActivities(
        db: Database,
        deviceID: Int,
        selectedActivityIDs: [Int] = []
    ) -> [[String: Any]] {
        return [
            tryEncode(chart: "activity-list") {
                try PlotlyEncoder.activityListPayload(
                    from: db, deviceID: deviceID,
                    selectedActivityIDs: selectedActivityIDs
                )
            },
        ]
    }

    /// Most recent activity for the device, by start time. Returns nil if
    /// the device has no activities. Used by MainWindowController to pick
    /// a default selection on first activities-tab visit.
    static func mostRecentActivityID(db: Database, deviceID: Int) -> Int? {
        do {
            let row = try db.queryOne("""
                SELECT activity_id FROM activities
                WHERE device_id = ?
                ORDER BY start_time_utc DESC
                LIMIT 1
                """, bind: [.int(Int64(deviceID))])
            return row?.int("activity_id")
        } catch {
            return nil
        }
    }

    /// Insight strip for the Activities tab.
    static func loadActivitiesInsights(db: Database, deviceID: Int) -> [String: Any] {
        let insights = InsightEngine.computeActivities(db: db, deviceID: deviceID)
        return insightsPayload(containerID: "activities-insights", insights: insights)
    }

    /// Build payloads for the activity-detail sub-section. Called when the
    /// user clicks (or cmd+clicks) activity-list rows.
    ///
    /// Resolves each activity's trim once (load existing or run the autotrim
    /// heuristic on first view), stitches the selected activities into one
    /// `ActivityGroup`, and passes that group to every encoder — so all five
    /// payloads agree both on what's clipped and on how the members are
    /// chained together. A single selected activity is a group of one and
    /// renders exactly as it always did.
    static func loadActivityDetail(db: Database, activityIDs: [Int]) -> [[String: Any]] {
        let detailCharts = [
            "activity-summary-card", "activity-pace-altitude", "activity-hr-zones",
            "activity-gps-map", "activity-trim-controls",
        ]
        guard !activityIDs.isEmpty else {
            // The trim control is hidden rather than emptied, exactly as it is
            // for a multi-activity selection (#261) — there is nothing useful
            // to say in a box that size.
            return detailCharts.map { chart in
                chart == "activity-trim-controls"
                    ? PlotlyEncoder.hiddenPayload(chartID: chart)
                    : PlotlyEncoder.emptyPayload(chartID: chart, message: "No activity selected")
            }
        }
        var trims: [Int: TrimState] = [:]
        for id in activityIDs {
            if let trim = resolveActivityTrim(db: db, activityID: id) {
                trims[id] = trim
            }
        }
        let group: ActivityGroup
        do {
            group = try ActivityGroup.load(db: db, activityIDs: activityIDs, trims: trims)
        } catch {
            print("TabLoaders.loadActivityDetail failed: \(error)")
            return detailCharts.map {
                PlotlyEncoder.emptyPayload(chartID: $0, message: "Failed to load: \(error)")
            }
        }
        return [
            tryEncode(chart: "activity-summary-card") {
                try PlotlyEncoder.activitySummaryCard(from: db, group: group)
            },
            tryEncode(chart: "activity-pace-altitude") {
                PlotlyEncoder.activityPaceAltitude(group: group)
            },
            tryEncode(chart: "activity-hr-zones") {
                PlotlyEncoder.activityHRZones(group: group)
            },
            tryEncode(chart: "activity-gps-map") {
                PlotlyEncoder.activityGPSMap(group: group)
            },
            tryEncode(chart: "activity-trim-controls") {
                PlotlyEncoder.activityTrimControls(group: group)
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
            tryEncode(chart: "hrv-daily-trend") {
                try PlotlyEncoder.hrvDailyTrend(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "hr-range-band") {
                try PlotlyEncoder.hrRangeBand(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "daily-steps-distance-combo") {
                try PlotlyEncoder.dailyStepsDistanceCombo(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "daily-intensity-minutes-bar") {
                try PlotlyEncoder.dailyIntensityMinutesBar(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "steps-hourly-heatmap") {
                try PlotlyEncoder.hourlyHRHeatmap(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "respiration-spo2-ts") {
                try PlotlyEncoder.respirationSpo2TS(from: db, deviceID: deviceID)
            },
        ]
    }

    /// Insight strip for Wellness (parallel to loadOverviewInsights).
    static func loadWellnessInsights(db: Database, deviceID: Int) -> [String: Any] {
        let insights = InsightEngine.computeWellness(db: db, deviceID: deviceID)
        return insightsPayload(containerID: "wellness-insights", insights: insights)
    }

    /// Build payloads for the Sleep tab.
    static func loadSleep(db: Database, deviceID: Int) -> [[String: Any]] {
        return [
            tryEncode(chart: "sleep-hypnogram") {
                try PlotlyEncoder.sleepHypnogram(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-stage-donut") {
                try PlotlyEncoder.sleepStageDonut(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-summary-card") {
                try PlotlyEncoder.sleepSummaryCard(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-score-trend") {
                try PlotlyEncoder.sleepScoreTrend(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-duration-bar") {
                try PlotlyEncoder.sleepDurationBar(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-stage-stacked") {
                try PlotlyEncoder.sleepStageStacked(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-bed-wake-scatter") {
                try PlotlyEncoder.sleepBedWakeScatter(from: db, deviceID: deviceID)
            },
            tryEncode(chart: "sleep-regularity-heatmap") {
                try PlotlyEncoder.sleepRegularityHeatmap(from: db, deviceID: deviceID)
            },
        ]
    }

    /// Insight strip for Sleep.
    static func loadSleepInsights(db: Database, deviceID: Int) -> [String: Any] {
        let insights = InsightEngine.computeSleep(db: db, deviceID: deviceID)
        return insightsPayload(containerID: "sleep-insights", insights: insights)
    }

    /// Click-to-load: rebuild just the hero (hypnogram + donut + summary)
    /// for a specific sleep_id. Returns three payloads ready to ship to the
    /// WebChartView.
    static func loadSleepNight(db: Database, sleepID: Int) -> [[String: Any]] {
        return [
            tryEncode(chart: "sleep-hypnogram") {
                try PlotlyEncoder.sleepHypnogramFor(from: db, sleepID: sleepID)
            },
            tryEncode(chart: "sleep-stage-donut") {
                try PlotlyEncoder.sleepStageDonutFor(from: db, sleepID: sleepID)
            },
            tryEncode(chart: "sleep-summary-card") {
                try PlotlyEncoder.sleepSummaryCardFor(from: db, sleepID: sleepID)
            },
        ]
    }

    /// Shared shape for the per-tab insight payloads. `containerID` is the
    /// HTML id of the insight-grid div the JS renderer will append cards into.
    private static func insightsPayload(
        containerID: String, insights: [Insight]
    ) -> [String: Any] {
        return [
            "chart": "insight-cards",
            "container": containerID,
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
