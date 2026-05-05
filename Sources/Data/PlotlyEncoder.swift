// PlotlyEncoder.swift
//
// Per-chart functions that take SQL query results and emit a JSON-serializable
// dictionary in the shape Plotly's `Plotly.newPlot(div, data, layout, config)`
// expects. The Swift→JS bridge in `WebChartView` then JSON-encodes this dict
// and injects it into the WebView.
//
// Each chart gets one builder function. The function:
//   1. Pulls the relevant rows from `Database`
//   2. Reshapes them into Plotly trace data
//   3. Returns a `[String: Any]` dict shaped like:
//        ["chart": "<chart-id>",
//         "data": [<traces>],
//         "layout": [<layout>],
//         "config": [<config>]]
//
// All builders should be safe against empty result sets — they return an
// `emptyPayload()` instead of throwing or returning a malformed dict. Per-chart
// errors that DO escape are caught at the tab loader level (TabLoader.swift)
// and converted to emptyPayloads with a "Failed to load X" message.
//
// JSON-serialization rules:
//   - `nil` Swift values must be `NSNull()` so JSONSerialization emits `null`
//     (Swift's `nil` in a heterogeneous array is just missing).
//   - Numeric literals must be `Double` or `Int`, not `CGFloat`, or
//     JSONSerialization will throw "Invalid JSON value".

import Foundation

public enum PlotlyEncoder {

    // MARK: - Common layout pieces

    /// Plotly config used by every chart.
    public static let defaultConfig: [String: Any] = [
        "displayModeBar": false,
        "responsive": true,
        "doubleClick": "reset",
    ]

    /// Standard dark theme layout fragment that every chart starts from. Merge
    /// with chart-specific overrides.
    ///
    /// Title placement notes: we anchor the title to the top of the figure
    /// container (yref=container, y=0.97, yanchor=top) so it sits in the very
    /// top of the top margin. Charts that add a legend should position it just
    /// above the plot area (yanchor=bottom, y=1.02) so the legend nestles
    /// between title and plot without overlapping the title text. The 70px
    /// top margin in this baseline is sized to fit both.
    public static func darkLayout(title: String, height: Int = 280) -> [String: Any] {
        return [
            "title": [
                "text": title,
                "font": ["color": "#dddddd", "size": 15],
                "x": 0.02, "xanchor": "left",
                "y": 0.97, "yref": "container", "yanchor": "top",
            ] as [String: Any],
            "paper_bgcolor": "rgba(0,0,0,0)",
            "plot_bgcolor": "rgba(0,0,0,0)",
            "font": ["color": "#dddddd", "size": 11],
            "xaxis": [
                "showgrid": false,
                "zeroline": false,
                "tickfont": ["color": "#888888", "size": 10],
                "linecolor": "#444444",
            ] as [String: Any],
            "yaxis": [
                "showgrid": true,
                "gridcolor": "#333333",
                "zeroline": false,
                "tickfont": ["color": "#888888", "size": 10],
                "linecolor": "#444444",
            ] as [String: Any],
            "margin": ["l": 50, "r": 30, "t": 70, "b": 40],
            "height": height,
            "hovermode": "closest",
            "hoverlabel": [
                "bgcolor": "#1e1e1e",
                "bordercolor": "#444444",
                "font": ["color": "#dddddd", "size": 11],
            ] as [String: Any],
        ]
    }

    /// Standard horizontal legend dict, positioned just above the plot area
    /// so it doesn't collide with the title (which sits in the top margin).
    /// Use for any chart that wants a legend, so all five chart types share
    /// the exact same anchor geometry.
    static let topHorizontalLegend: [String: Any] = [
        "orientation": "h",
        "x": 0.02, "xanchor": "left",
        "y": 1.02, "yanchor": "bottom",
        "font": ["color": "#888888", "size": 10],
        "bgcolor": "rgba(0,0,0,0)",
    ]

    /// Build a placeholder payload for a chart that has no data to display.
    public static func emptyPayload(chartID: String, message: String) -> [String: Any] {
        return [
            "chart": chartID,
            "chart_empty": true,
            "message": message,
        ]
    }

    // MARK: - Helpers

    private static let groupingFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f
    }()
    static func numberWithGrouping(_ n: Int) -> String {
        return groupingFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Convert a `Double?` from a query into either the value or NSNull, ready
    /// for JSON serialization. Plotly skips `null` y values which is exactly
    /// the behavior we want for gap days.
    private static func nullable(_ d: Double?) -> Any {
        return d.map { $0 as Any } ?? (NSNull() as Any)
    }
    private static func nullable(_ i: Int?) -> Any {
        return i.map { $0 as Any } ?? (NSNull() as Any)
    }

    /// Build the JSON-friendly description of a chart's interval-picker
    /// strip. Bootstrap.js consumes this and renders the ◀ tabs ▶ control
    /// above the chart. Including this dict in a chart payload's `window`
    /// field is what tells the JS side to draw the control.
    ///
    /// `dataRange` is the (oldest, newest) timestamps that exist in the
    /// underlying table for this chart. The arrows are disabled when there's
    /// no data on the corresponding side, so the user can't shift past the
    /// edges of their archive.
    static func windowControlsPayload(
        window: ChartWindow,
        intervals: [ChartInterval],
        dataRange: (min: Date?, max: Date?) = (nil, nil)
    ) -> [String: Any] {
        // .all disables both arrows because the window is unbounded.
        let shiftable = window.interval != .all
        let canShiftBack: Bool
        let canShiftForward: Bool
        if !shiftable {
            canShiftBack = false
            canShiftForward = false
        } else {
            // We can shift back if any data point lies strictly before the
            // current window's start. Same logic mirrored on the forward side.
            canShiftBack = dataRange.min.map { $0 < window.startDate } ?? false
            canShiftForward = dataRange.max.map { $0 > window.endDate } ?? false
        }
        return [
            "selected": window.interval.rawValue,
            "intervals": intervals.map { $0.rawValue },
            "labels": intervals.map { $0.displayLabel },
            "label": window.label,
            "shiftable": shiftable,
            "canShiftBack": canShiftBack,
            "canShiftForward": canShiftForward,
        ]
    }

    /// Build the xaxis layout fragment for a date-axis chart whose visible
    /// range is governed by `window`. The interval drives both the tick
    /// spacing and the label format so the labels stay legible at every
    /// zoom level — single-digit day numbers for week/month, month
    /// abbreviations for year, hour-of-day for the intraday view.
    ///
    /// We deliberately do NOT repeat the year on every tick. The chart's
    /// interval-picker strip already shows the full window range
    /// ("Mar 11 – Apr 9, 2026") right above the chart, so the axis just
    /// has to convey relative position within that range. The hover format
    /// always falls back to the verbose date so the user can pinpoint a
    /// specific bar/marker without ambiguity.
    static func dateAxisLayout(for window: ChartWindow) -> [String: Any] {
        var ax: [String: Any] = [
            "type": "date",
            "showgrid": false,
            "zeroline": false,
            "tickfont": ["color": "#888888", "size": 10],
            "linecolor": "#444444",
            "automargin": true,
            // Pin the visible range to the window edges so Plotly doesn't
            // pad with empty space on either side.
            "range": [
                Database.iso8601.string(from: window.startDate),
                Database.iso8601.string(from:
                    DateUtil.adding(days: 1, to: window.endDate)),
            ],
        ]
        switch window.interval {
        case .day:
            // Single-day intraday view: ticks every 3 hours, "9am" labels.
            ax["dtick"] = 3 * 3600 * 1000
            ax["tickformat"] = "%-l%p"
            ax["hoverformat"] = "%b %-d, %-l:%M %p"
        case .week:
            // 7-day window: tick every day, day-of-month numbers.
            ax["dtick"] = 86400 * 1000
            ax["tickformat"] = "%-d"
            ax["hoverformat"] = "%a %b %-d, %Y"
        case .month:
            // ~30-day window: tick every 5 days, "Apr 5" labels.
            ax["dtick"] = 5 * 86400 * 1000
            ax["tickformat"] = "%b %-d"
            ax["hoverformat"] = "%a %b %-d, %Y"
        case .year:
            // ~365-day window: monthly ticks, "Apr" labels. Year boundaries
            // get the year too via the tickformatstops below.
            ax["dtick"] = "M1"
            ax["tickformat"] = "%b"
            ax["hoverformat"] = "%b %-d, %Y"
            ax["tickformatstops"] = [
                ["dtickrange": ["M1", "M11"], "value": "%b"],
                ["dtickrange": ["M11", "M13"], "value": "%b<br>%Y"],
            ]
        case .all:
            // Unbounded: let Plotly auto-pick the dtick, but tickformatstops
            // covers every zoom level it might land on.
            ax["tickformatstops"] = [
                ["dtickrange": [NSNull(), 86400000],     "value": "%-l%p"],
                ["dtickrange": [86400000, 7 * 86400000],  "value": "%b %-d"],
                ["dtickrange": [7 * 86400000, "M1"],      "value": "%b %-d"],
                ["dtickrange": ["M1", "M12"],             "value": "%b '%y"],
                ["dtickrange": ["M12", NSNull()],         "value": "%Y"],
            ]
            ax["hoverformat"] = "%b %-d, %Y"
        }
        return ax
    }

    /// Cheap (MIN, MAX) date-range query helper. Used by every windowed
    /// chart so its interval-picker arrows know whether there's data past
    /// the current window edge.
    ///
    /// The SQL must alias its two output columns as `date_min` and
    /// `date_max` (either `date_local` text or full ISO timestamps — both
    /// formats are parsed via `Database.iso8601` / `DateUtil.day`).
    static func dataDateRange(
        _ db: Database,
        sql: String,
        bind: [SQLValue] = []
    ) -> (min: Date?, max: Date?) {
        guard let row = try? db.queryOne(sql, bind: bind) else {
            return (nil, nil)
        }
        return (parseAnyDate(row.string("date_min")),
                parseAnyDate(row.string("date_max")))
    }

    /// Parse either a `YYYY-MM-DD` date_local or a full ISO timestamp.
    private static func parseAnyDate(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        return DateUtil.day(from: s) ?? Database.iso8601.date(from: s)
    }

    /// Walk a time-ordered series of samples and insert explicit `(NSNull(),
    /// "")` placeholders wherever the gap between successive samples exceeds
    /// `gapSeconds`. Plotly draws a visible break across these nulls when the
    /// trace has `connectgaps: false`. Returns parallel `xs`/`ys` arrays
    /// ready to drop into a Plotly scatter trace.
    static func insertGapNulls(
        _ rows: [(date: Date, iso: String, val: Double)],
        gapSeconds: TimeInterval
    ) -> (xs: [Any], ys: [Any]) {
        var xs: [Any] = []
        var ys: [Any] = []
        var prev: Date?
        for r in rows {
            if let p = prev, r.date.timeIntervalSince(p) > gapSeconds {
                // Anchor the gap point halfway through the dead time so the
                // axis tick positioning lines up. The y is null so Plotly
                // breaks the line there.
                let mid = p.addingTimeInterval((r.date.timeIntervalSince(p)) / 2)
                xs.append(Database.iso8601.string(from: mid))
                ys.append(NSNull())
            }
            xs.append(r.iso)
            ys.append(r.val)
            prev = r.date
        }
        return (xs, ys)
    }

    /// Format a duration in seconds as "Hh Mm" or "Mm Ss".
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Convert ISO-8601 timestamp string into a "MMM d" or "yyyy-MM-dd" label.
    static func shortDateLabel(_ iso: String) -> String {
        guard let date = Database.iso8601.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    // MARK: - Overview / daily-steps-bar

    /// Default interval for daily-steps-bar when the user hasn't picked one.
    static let dailyStepsBarDefaultInterval: ChartInterval = .month
    /// Intervals offered by the daily-steps-bar tab strip.
    static let dailyStepsBarIntervals: [ChartInterval] =
        [.week, .month, .year, .all]

    public static func dailyStepsBar(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "daily-steps-bar"
        let window = ChartWindowStore.shared.window(
            for: chartID,
            defaultInterval: dailyStepsBarDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(date_local) AS date_min, MAX(date_local) AS date_max FROM wellness_daily
            WHERE device_id = ? AND steps IS NOT NULL
            """, bind: [.int(Int64(deviceID))])
        let rows: [Row]
        if window.interval == .all {
            rows = try db.query(
                Queries.overviewDailySteps,
                bind: [.int(Int64(deviceID))]
            )
        } else {
            rows = try db.query(
                Queries.overviewDailyStepsWindowed,
                bind: [
                    .int(Int64(deviceID)),
                    .text(DateUtil.dayString(from: window.startDate)),
                    .text(DateUtil.dayString(from: window.endDate)),
                ]
            )
        }
        var raw: [(date: Date, value: Double?)] = []
        for row in rows {
            guard
                let dayStr = row.string("date_local"),
                let date = DateUtil.day(from: dayStr)
            else { continue }
            raw.append((date, row.int("steps").map(Double.init)))
        }
        guard !raw.isEmpty else {
            var payload = emptyPayload(chartID: chartID, message: "No step data in this window")
            payload["window"] = windowControlsPayload(
                window: window, intervals: dailyStepsBarIntervals, dataRange: dataRange
            )
            return payload
        }
        let dense = DateUtil.fillGaps(raw)

        var xs: [String] = []
        var ys: [Any] = []
        for d in dense {
            xs.append(DateUtil.dayString(from: d.date))
            if let v = d.value {
                ys.append(v)
            } else {
                ys.append(NSNull())
            }
        }

        let trace: [String: Any] = [
            "type": "bar",
            "x": xs,
            "y": ys,
            "hovertemplate": "%{x|%a %b %-d, %Y}<br>%{y:,.0f} steps<extra></extra>",
            "marker": ["color": "#4ec9b0", "line": ["width": 0]] as [String: Any],
        ]

        var layout = darkLayout(title: "Daily steps", height: 280)
        layout["shapes"] = [[
            "type": "line", "xref": "paper",
            "x0": 0, "x1": 1, "y0": 10000, "y1": 10000,
            "line": ["color": "#888888", "width": 1, "dash": "dash"],
        ] as [String: Any]]
        layout["annotations"] = [[
            "xref": "paper", "x": 1.0, "xanchor": "right",
            "y": 10000, "yanchor": "bottom",
            "text": "10k goal", "showarrow": false,
            "font": ["color": "#888888", "size": 10],
        ] as [String: Any]]
        layout["xaxis"] = dateAxisLayout(for: window)
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["rangemode"] = "tozero"
        layout["yaxis"] = yaxis
        layout["bargap"] = 0.25

        return [
            "chart": chartID,
            "data": [trace],
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: dailyStepsBarIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Overview / resting-hr-trendline

    static let restingHRDefaultInterval: ChartInterval = .month
    static let restingHRIntervals: [ChartInterval] = [.week, .month, .year, .all]

    public static func restingHRTrendline(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "resting-hr-trendline"
        let window = ChartWindowStore.shared.window(
            for: chartID, defaultInterval: restingHRDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(date_local) AS date_min, MAX(date_local) AS date_max FROM wellness_daily
            WHERE device_id = ? AND resting_hr IS NOT NULL
            """, bind: [.int(Int64(deviceID))])
        let rows: [Row]
        if window.interval == .all {
            rows = try db.query("""
                SELECT date_local, resting_hr
                FROM wellness_daily
                WHERE device_id = ? AND resting_hr IS NOT NULL
                ORDER BY date_local
                """, bind: [.int(Int64(deviceID))])
        } else {
            rows = try db.query(
                Queries.overviewRestingHRWindowed,
                bind: [
                    .int(Int64(deviceID)),
                    .text(window.startDateLocal),
                    .text(window.endDateLocal),
                ]
            )
        }
        var raw: [(date: Date, value: Double?)] = []
        for row in rows {
            guard
                let dayStr = row.string("date_local"),
                let date = DateUtil.day(from: dayStr)
            else { continue }
            raw.append((date, row.int("resting_hr").map(Double.init)))
        }
        guard !raw.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID, message: "No resting HR data in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: restingHRIntervals, dataRange: dataRange
            )
            return payload
        }
        let dense = DateUtil.fillGaps(raw)

        let xs = dense.map { DateUtil.dayString(from: $0.date) }
        let ys: [Any] = dense.map { nullable($0.value) }

        // 7-day rolling mean (over non-null windows only). The local
        // `slice` here is a sliding window of values, not the chart window.
        var rollingMean: [Any] = []
        for i in 0..<dense.count {
            let lo = max(0, i - 6)
            let slice = dense[lo...i].compactMap { $0.value }
            if slice.isEmpty {
                rollingMean.append(NSNull())
            } else {
                rollingMean.append(slice.reduce(0, +) / Double(slice.count))
            }
        }

        let raw_trace: [String: Any] = [
            "type": "scatter", "mode": "markers",
            "x": xs, "y": ys, "name": "daily",
            "marker": ["color": "#888888", "size": 5],
            "hovertemplate": "%{x|%b %-d, %Y}<br>%{y:.0f} bpm<extra></extra>",
        ]
        let smoothed_trace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": xs, "y": rollingMean,
            "name": "7-day mean",
            "line": ["color": "#4ec9b0", "width": 2],
            "connectgaps": false,
            "hovertemplate": "%{x|%b %-d, %Y}<br>%{y:.1f} bpm (avg)<extra></extra>",
        ]

        var layout = darkLayout(title: "Resting HR", height: 280)
        layout["showlegend"] = true
        layout["legend"] = topHorizontalLegend
        layout["xaxis"] = dateAxisLayout(for: window)

        return [
            "chart": chartID,
            "data": [raw_trace, smoothed_trace],
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: restingHRIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Overview / body-battery-gauge

    public static func bodyBatteryGauge(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        guard let row = try db.queryOne(
            Queries.overviewLatestBodyBattery,
            bind: [.int(Int64(deviceID))]
        ) else {
            return emptyPayload(chartID: "body-battery-gauge", message: "No body battery data yet")
        }
        let bbMin = row.int("body_battery_min") ?? 0
        let bbMax = row.int("body_battery_max") ?? 0
        let dateStr = row.string("date_local") ?? ""
        let drain = max(0, bbMax - bbMin)

        let trace: [String: Any] = [
            "type": "indicator",
            "mode": "gauge+number",
            "value": bbMax,
            "title": [
                "text": "Body battery (max)<br><span style='font-size:0.7em;color:#888'>\(dateStr)</span>",
                "font": ["color": "#dddddd", "size": 13],
            ] as [String: Any],
            "number": ["font": ["color": "#dddddd", "size": 36]],
            "gauge": [
                "axis": [
                    "range": [0, 100],
                    "tickcolor": "#666666",
                    "tickfont": ["color": "#888888", "size": 10],
                ],
                "bar": ["color": "#4ec9b0"],
                "bgcolor": "rgba(0,0,0,0)",
                "borderwidth": 0,
                "steps": [
                    ["range": [0, 25], "color": "#3a1f1f"],
                    ["range": [25, 50], "color": "#3a2f1f"],
                    ["range": [50, 75], "color": "#1f3a2a"],
                    ["range": [75, 100], "color": "#1f3a3a"],
                ],
                "threshold": [
                    "line": ["color": "#d7ba7d", "width": 3],
                    "thickness": 0.85,
                    "value": bbMin,
                ],
            ] as [String: Any],
        ]

        var layout = darkLayout(title: "Body battery", height: 260)
        layout["margin"] = ["l": 30, "r": 30, "t": 40, "b": 30]
        layout["annotations"] = [[
            "x": 0.5, "y": -0.05, "xref": "paper", "yref": "paper",
            "text": "overnight low: \(bbMin)  •  drain: \(drain)",
            "showarrow": false,
            "font": ["color": "#888888", "size": 11],
        ] as [String: Any]]

        return [
            "chart": "body-battery-gauge",
            "data": [trace],
            "layout": layout,
            "config": defaultConfig,
        ]
    }

    // MARK: - Overview / recent-activities-timeline

    static let recentActivitiesDefaultInterval: ChartInterval = .month
    static let recentActivitiesIntervals: [ChartInterval] = [.week, .month, .year]

    public static func recentActivitiesTimeline(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "recent-activities-timeline"
        let window = ChartWindowStore.shared.window(
            for: chartID, defaultInterval: recentActivitiesDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(start_time_utc) AS date_min, MAX(start_time_utc) AS date_max FROM activities
            WHERE device_id = ?
            """, bind: [.int(Int64(deviceID))])
        let rows = try db.query(
            Queries.overviewRecentActivitiesWindowed,
            bind: [
                .int(Int64(deviceID)),
                .text(window.startTimestampISO),
                .text(window.endTimestampISO),
            ]
        )
        guard !rows.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID, message: "No activities in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: recentActivitiesIntervals, dataRange: dataRange
            )
            return payload
        }

        // One Plotly bar trace per sport (so colors are consistent and the
        // legend doubles as a sport key).
        var sports: [String: (xs: [String], starts: [Double], durs: [Double], hovers: [String])] = [:]

        for row in rows {
            guard let startStr = row.string("start_time_utc") else { continue }
            guard let s = Database.iso8601.date(from: startStr) else { continue }
            let sport = row.string("sport") ?? "other"
            let dur = row.double("total_timer_s") ?? 0
            let dist = row.double("total_distance_m")

            // Plotly horizontal bar with `base` works as a Gantt-style timeline.
            // Convert start time to a unix-millis number for the x axis.
            let startMs = s.timeIntervalSince1970 * 1000
            let durMs = dur * 1000

            var entry = sports[sport] ?? (xs: [], starts: [], durs: [], hovers: [])
            // Use sport as the y category so all activities of the same sport
            // share a row in the swimlane.
            entry.xs.append(sport)
            entry.starts.append(startMs)
            entry.durs.append(durMs)
            let hover = "\(sport.capitalized) \(DateUtil.dayString(from: s))<br>"
                + "duration: \(formatDuration(dur))"
                + (dist.map { "<br>distance: \(String(format: "%.2f km", $0 / 1000))" } ?? "")
            entry.hovers.append(hover)
            sports[sport] = entry
        }

        let palette = ["#4ec9b0", "#569cd6", "#d7ba7d", "#c586c0", "#9cdcfe"]
        var traces: [[String: Any]] = []
        for (i, key) in sports.keys.sorted().enumerated() {
            let entry = sports[key]!
            traces.append([
                "type": "bar",
                "orientation": "h",
                "y": entry.xs,
                "base": entry.starts,
                "x": entry.durs,
                "name": key.capitalized,
                "marker": ["color": palette[i % palette.count]],
                "text": entry.hovers,
                "hovertemplate": "%{text}<extra></extra>",
            ])
        }

        var layout = darkLayout(title: "Recent activities", height: 260)
        layout["barmode"] = "stack"  // doesn't actually stack since each sport is its own y; harmless
        layout["showlegend"] = true
        layout["legend"] = topHorizontalLegend
        layout["xaxis"] = dateAxisLayout(for: window)
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["type"] = "category"
        layout["yaxis"] = yaxis

        return [
            "chart": chartID,
            "data": traces,
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: recentActivitiesIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Activities / activity-list (HTML table, not Plotly)

    public static func activityListPayload(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let rows = try db.query(
            Queries.activitiesList,
            bind: [.int(Int64(deviceID))]
        )
        var out: [[String: Any]] = []
        for row in rows {
            let id = row.int("activity_id") ?? 0
            let startISO = row.string("start_time_utc") ?? ""
            let dist = row.double("total_distance_m")
            let dur = row.double("total_timer_s")
            let avgHR = row.int("avg_hr")
            let load = row.double("training_load")
            out.append([
                "activity_id": id,
                "start": shortDateLabel(startISO),
                "sport": row.string("sport") ?? "—",
                "distance": dist.map { String(format: "%.2f km", $0 / 1000) } ?? "—",
                "duration": dur.map { formatDuration($0) } ?? "—",
                "avg_hr": avgHR.map { "\($0) bpm" } ?? "—",
                "training_load": load.map { String(format: "%.0f", $0) } ?? "—",
            ])
        }
        return ["chart": "activity-list", "rows": out]
    }

    // MARK: - Activities / weekly-distance-bar

    static let weeklyDistanceDefaultInterval: ChartInterval = .year
    static let weeklyDistanceIntervals: [ChartInterval] = [.month, .year, .all]

    public static func weeklyDistanceBar(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "weekly-distance-bar"
        let window = ChartWindowStore.shared.window(
            for: chartID, defaultInterval: weeklyDistanceDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(start_time_utc) AS date_min, MAX(start_time_utc) AS date_max FROM activities
            WHERE device_id = ? AND total_distance_m IS NOT NULL
            """, bind: [.int(Int64(deviceID))])
        let rows: [Row]
        if window.interval == .all {
            rows = try db.query("""
                SELECT strftime('%Y-%W', start_time_utc) AS yearweek,
                       sport,
                       SUM(total_distance_m) / 1000.0 AS km
                FROM activities
                WHERE device_id = ?
                  AND total_distance_m IS NOT NULL
                GROUP BY yearweek, sport
                ORDER BY yearweek
                """, bind: [.int(Int64(deviceID))])
        } else {
            rows = try db.query(
                Queries.weeklyDistanceBySportWindowed,
                bind: [
                    .int(Int64(deviceID)),
                    .text(window.startTimestampISO),
                    .text(window.endTimestampISO),
                ]
            )
        }
        guard !rows.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID, message: "No activities in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: weeklyDistanceIntervals, dataRange: dataRange
            )
            return payload
        }

        // Pivot rows into per-sport series. Plotly stacked bars use one trace
        // per series with the same x-axis categories.
        var weeks: [String] = []
        var seenWeeks = Set<String>()
        var bySport: [String: [String: Double]] = [:]  // sport -> week -> km

        for row in rows {
            guard let week = row.string("yearweek") else { continue }
            if !seenWeeks.contains(week) {
                weeks.append(week); seenWeeks.insert(week)
            }
            let sport = row.string("sport") ?? "other"
            let km = row.double("km") ?? 0
            bySport[sport, default: [:]][week] = km
        }

        let palette = ["#4ec9b0", "#569cd6", "#d7ba7d", "#c586c0", "#9cdcfe", "#f48771"]
        var traces: [[String: Any]] = []
        for (i, sport) in bySport.keys.sorted().enumerated() {
            let perWeek = bySport[sport]!
            let ys = weeks.map { perWeek[$0] ?? 0 }
            traces.append([
                "type": "bar",
                "x": weeks,
                "y": ys,
                "name": sport.capitalized,
                "marker": ["color": palette[i % palette.count]],
                "hovertemplate": "%{x} %{fullData.name}<br>%{y:.1f} km<extra></extra>",
            ])
        }

        var layout = darkLayout(title: "Weekly distance", height: 280)
        layout["barmode"] = "stack"
        layout["showlegend"] = true
        layout["legend"] = topHorizontalLegend
        var xaxis = layout["xaxis"] as! [String: Any]
        xaxis["type"] = "category"
        xaxis["nticks"] = 8
        layout["xaxis"] = xaxis
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["title"] = ["text": "km", "font": ["color": "#888888", "size": 10]]
        layout["yaxis"] = yaxis

        return [
            "chart": chartID,
            "data": traces,
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: weeklyDistanceIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Activity detail / pace-altitude

    public static func activityPaceAltitude(
        from db: Database,
        activityID: Int,
        trim: TrimState? = nil
    ) throws -> [String: Any] {
        let allRows = try db.query(
            Queries.activityRecords,
            bind: [.int(Int64(activityID))]
        )
        let rows = ActivityTrim.filter(allRows, with: trim)
        guard !rows.isEmpty else {
            return emptyPayload(chartID: "activity-pace-altitude", message: "No records for this activity")
        }
        var distances: [Double] = []
        var rawSpeeds: [Double?] = []
        var rawHRs: [Double?] = []
        var rawAlts: [Double?] = []
        for row in rows {
            let dist = row.double("distance_m") ?? 0
            distances.append(dist / 1000.0)  // km
            if let speed = row.double("speed_mps"), speed > 0 {
                rawSpeeds.append(speed)
            } else {
                rawSpeeds.append(nil)
            }
            if let hr = row.int("heart_rate"), hr > 0 {
                rawHRs.append(Double(hr))
            } else {
                rawHRs.append(nil)
            }
            rawAlts.append(row.double("altitude_m"))
        }

        // Centered 15-sample rolling mean (≈15s at 1Hz). Speed is averaged
        // first then converted to pace — averaging pace directly would bias
        // toward slow samples since pace = 1/speed is non-linear, and brief
        // stops blow it up to +∞. HR is mildly smoothed for visual parity.
        let smoothedSpeeds = rollingMean(rawSpeeds, halfWindow: 7)
        let smoothedHRs = rollingMean(rawHRs, halfWindow: 7)

        let paces: [Any] = smoothedSpeeds.map { s -> Any in
            if let s = s, s > 0 { return 1000.0 / s / 60.0 }
            return NSNull()
        }
        let speedKmh: [Any] = smoothedSpeeds.map { s -> Any in
            if let s = s { return s * 3.6 }
            return NSNull()
        }
        let hrs: [Any] = smoothedHRs.map { ($0 as Any?) ?? NSNull() }
        let alts: [Any] = rawAlts.map { ($0 as Any?) ?? NSNull() }

        let pace_trace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": distances, "y": paces,
            "name": "Pace",
            "line": ["color": "#4ec9b0", "width": 2],
            "hovertemplate": "%{x:.2f} km<br>%{y:.2f} min/km<extra>Pace</extra>",
            "yaxis": "y",
            "visible": true,
        ]
        let alt_trace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": distances, "y": alts,
            "name": "Altitude",
            "line": ["color": "#569cd6", "width": 1.5],
            "hovertemplate": "%{x:.2f} km<br>%{y:.0f} m<extra>Altitude</extra>",
            "yaxis": "y2",
            "visible": true,
        ]
        let speed_trace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": distances, "y": speedKmh,
            "name": "Speed",
            "line": ["color": "#b5cea8", "width": 1.5],
            "hovertemplate": "%{x:.2f} km<br>%{y:.1f} km/h<extra>Speed</extra>",
            "yaxis": "y3",
            "visible": false,
        ]
        let hr_trace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": distances, "y": hrs,
            "name": "Heart rate",
            "line": ["color": "#f48771", "width": 1.5],
            "hovertemplate": "%{x:.2f} km<br>%{y:.0f} bpm<extra>Heart rate</extra>",
            "yaxis": "y4",
            "visible": false,
        ]

        var layout = darkLayout(title: "Activity metrics", height: 320)
        // Reserve 8% of paper width on each side so the offset y3 (far left)
        // and y4 (far right) axes have room for their labels without
        // overlapping the data area.
        layout["xaxis"] = [
            "title": ["text": "distance (km)", "font": ["color": "#888888", "size": 10]],
            "showgrid": false,
            "tickfont": ["color": "#888888", "size": 10],
            "linecolor": "#444444",
            "domain": [0.08, 0.92],
        ] as [String: Any]
        layout["yaxis"] = [
            "title": ["text": "pace (min/km)", "font": ["color": "#4ec9b0", "size": 10]],
            "tickfont": ["color": "#4ec9b0", "size": 10],
            "showgrid": true, "gridcolor": "#333333",
            "autorange": "reversed",  // faster pace = lower number, plot it on top
            "side": "left",
            "automargin": true,
        ] as [String: Any]
        layout["yaxis2"] = [
            "title": ["text": "altitude (m)", "font": ["color": "#569cd6", "size": 10]],
            "tickfont": ["color": "#569cd6", "size": 10],
            "overlaying": "y", "side": "right",
            "showgrid": false,
            "automargin": true,
        ] as [String: Any]
        layout["yaxis3"] = [
            "title": ["text": "speed (km/h)", "font": ["color": "#b5cea8", "size": 10]],
            "tickfont": ["color": "#b5cea8", "size": 10],
            "overlaying": "y", "side": "left",
            "anchor": "free", "position": 0.0,
            "showgrid": false,
            "automargin": true,
            "visible": false,
        ] as [String: Any]
        layout["yaxis4"] = [
            "title": ["text": "HR (bpm)", "font": ["color": "#f48771", "size": 10]],
            "tickfont": ["color": "#f48771", "size": 10],
            "overlaying": "y", "side": "right",
            "anchor": "free", "position": 1.0,
            "showgrid": false,
            "automargin": true,
            "visible": false,
        ] as [String: Any]
        layout["margin"] = ["l": 70, "r": 70, "t": 70, "b": 40]
        // Checkboxes outside the chart act as the legend.
        layout["showlegend"] = false

        return [
            "chart": "activity-pace-altitude",
            "data": [pace_trace, alt_trace, speed_trace, hr_trace],
            "layout": layout,
            "config": defaultConfig,
        ]
    }

    /// Centered rolling mean over an optional-Double sequence. Nil entries
    /// don't contribute to the average; a window with no non-nil samples
    /// produces nil at that position. `halfWindow` is each side's radius —
    /// total window size is `2 * halfWindow + 1`.
    private static func rollingMean(_ values: [Double?], halfWindow: Int) -> [Double?] {
        var out: [Double?] = []
        out.reserveCapacity(values.count)
        for i in 0..<values.count {
            let lo = max(0, i - halfWindow)
            let hi = min(values.count - 1, i + halfWindow)
            let slice = values[lo...hi].compactMap { $0 }
            if slice.isEmpty {
                out.append(nil)
            } else {
                out.append(slice.reduce(0, +) / Double(slice.count))
            }
        }
        return out
    }

    // MARK: - Activity detail / hr-zones

    public static func activityHRZones(
        from db: Database,
        activityID: Int,
        maxHR: Int = 190,
        trim: TrimState? = nil
    ) throws -> [String: Any] {
        let allRows = try db.query(
            Queries.activityRecords,
            bind: [.int(Int64(activityID))]
        )
        let rows = ActivityTrim.filter(allRows, with: trim)
        guard !rows.isEmpty else {
            return emptyPayload(chartID: "activity-hr-zones", message: "No HR records for this activity")
        }

        // Garmin's standard 5-zone model by % max HR.
        let bounds: [(name: String, lo: Double, hi: Double, color: String)] = [
            ("Z1 50–60%", 0.50, 0.60, "#9cdcfe"),
            ("Z2 60–70%", 0.60, 0.70, "#569cd6"),
            ("Z3 70–80%", 0.70, 0.80, "#4ec9b0"),
            ("Z4 80–90%", 0.80, 0.90, "#d7ba7d"),
            ("Z5 90%+",   0.90, 1.50, "#f48771"),
        ]
        var seconds: [Double] = Array(repeating: 0, count: bounds.count)

        // Approximate per-record duration as the spacing between samples (or 1s
        // for the last record). Tracks Garmin's Z minutes well enough for v1.
        var prevDate: Date?
        for row in rows {
            let hr = row.int("heart_rate")
            let tsStr = row.string("timestamp_utc") ?? ""
            let date = Database.iso8601.date(from: tsStr)
            let elapsed: Double
            if let date = date, let prev = prevDate {
                elapsed = max(0, min(60, date.timeIntervalSince(prev)))  // cap stalls
            } else {
                elapsed = 1
            }
            prevDate = date
            guard let hr = hr else { continue }
            let pct = Double(hr) / Double(maxHR)
            for (i, b) in bounds.enumerated() where pct >= b.lo && pct < b.hi {
                seconds[i] += elapsed
                break
            }
        }

        let xs = bounds.map { $0.name }
        let ys = seconds.map { $0 / 60.0 }  // → minutes
        let colors = bounds.map { $0.color }

        let trace: [String: Any] = [
            "type": "bar",
            "x": xs,
            "y": ys,
            "marker": ["color": colors],
            "text": ys.map { String(format: "%.1f m", $0) },
            "textposition": "outside",
            "hovertemplate": "%{x}<br>%{y:.1f} minutes<extra></extra>",
        ]

        var layout = darkLayout(title: "HR zones", height: 280)
        var xaxis = layout["xaxis"] as! [String: Any]
        xaxis["type"] = "category"
        layout["xaxis"] = xaxis
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["title"] = ["text": "minutes", "font": ["color": "#888888", "size": 10]]
        layout["yaxis"] = yaxis

        return [
            "chart": "activity-hr-zones",
            "data": [trace],
            "layout": layout,
            "config": defaultConfig,
        ]
    }

    // MARK: - Activity detail / trim-controls
    //
    // The trim-controls payload powers the timeline strip rendered below the
    // GPS map. It carries:
    //   - `segments`: pause-split spans of the activity in elapsed-second
    //     coordinates. Each segment becomes one block in the flex-row
    //     timeline; pauses render as gaps between blocks.
    //   - `samples`: a subsampled list of {elapsedS, ts} so the JS drag
    //     tooltip can show the wall-clock timestamp under the pointer
    //     without a Swift round-trip.
    //   - `trim`: the current TrimState (or null). When `trim.auto` is true
    //     and `trim.reason` is set, JS displays the reason below the
    //     timeline.
    //
    // Filtering note: this payload is intentionally NOT trim-filtered. The
    // timeline always shows the full activity so the user can drag a handle
    // back outward to undo a clip without resetting.

    public static func activityTrimControls(
        from db: Database,
        activityID: Int,
        trim: TrimState? = nil
    ) throws -> [String: Any] {
        let chartID = "activity-trim-controls"
        let rows = try db.query(
            Queries.activityRecords,
            bind: [.int(Int64(activityID))]
        )
        guard !rows.isEmpty else {
            return emptyPayload(chartID: chartID, message: "No records for this activity")
        }

        // Gather elapsed times + ISO timestamps for every record.
        struct Pt { let elapsedS: Int; let ts: String }
        var pts: [Pt] = []
        pts.reserveCapacity(rows.count)
        for row in rows {
            guard let e = row.int("elapsed_s") else { continue }
            let ts = row.string("timestamp_utc") ?? ""
            pts.append(Pt(elapsedS: e, ts: ts))
        }
        guard let firstE = pts.first?.elapsedS, let lastE = pts.last?.elapsedS else {
            return emptyPayload(chartID: chartID, message: "No timing for this activity")
        }

        // Detect pauses to split the activity into segments. Reuses the
        // same gap threshold as detectGPSPauses so the "T" markers on the
        // map agree with the segment boundaries on the timeline.
        var segments: [[String: Any]] = []
        var segStart = firstE
        for i in 0..<(pts.count - 1) {
            let gap = pts[i + 1].elapsedS - pts[i].elapsedS
            if gap > gpsPauseGapSeconds {
                segments.append([
                    "startS": segStart,
                    "endS": pts[i].elapsedS,
                ])
                segStart = pts[i + 1].elapsedS
            }
        }
        segments.append([
            "startS": segStart,
            "endS": lastE,
        ])

        // Subsample to ~1 sample per second for the tooltip. activity_records
        // is already 1 Hz on the Instinct 3, but be defensive — cap the
        // payload at ~10k points so longer activities don't blow up the
        // JSON.
        let stride = max(1, pts.count / 10_000)
        var samples: [[String: Any]] = []
        samples.reserveCapacity(pts.count / stride + 1)
        var idx = 0
        while idx < pts.count {
            samples.append([
                "elapsedS": pts[idx].elapsedS,
                "ts": pts[idx].ts,
            ])
            idx += stride
        }
        // Always include the very last point so the tail tooltip lines up
        // with the reset position of the end handle.
        if let last = pts.last,
           let lastSampled = samples.last?["elapsedS"] as? Int,
           lastSampled != last.elapsedS {
            samples.append(["elapsedS": last.elapsedS, "ts": last.ts])
        }

        var trimDict: Any = NSNull()
        if let trim = trim {
            trimDict = [
                "ranges": trim.ranges.map { ["startS": $0.startElapsedS, "endS": $0.endElapsedS] },
                "auto": trim.auto,
                "reason": trim.reason ?? NSNull(),
            ] as [String: Any]
        }

        return [
            "chart": chartID,
            "activity_id": activityID,
            "first_elapsed_s": firstE,
            "total_elapsed_s": lastE,
            "segments": segments,
            "samples": samples,
            "trim": trimDict,
        ]
    }

    // MARK: - Activity detail / gps-map
    //
    // Renders the GPS trail on a real MapLibre basemap (Plotly's `scattermap`
    // trace, available since plotly.js v2.35.0). Three keyless raster tile
    // providers are wired in via `layout.map.layers` and a Plotly updatemenu
    // button bar lets the user swap between Road / Satellite / Topo at runtime.
    //
    // A second updatemenu colors the trail by a chosen per-sample metric
    // (HR / speed / altitude / cadence / power) using a 12-stop Viridis
    // gradient. Since MapLibre line traces don't support per-vertex color, we
    // precompute one trace per (metric × bucket) and toggle visibility via
    // restyle.

    /// One GPS row from `activity_records`, with all the per-sample metrics
    /// we know how to color a polyline by.
    private struct GPSSample {
        let lat: Double
        let lon: Double
        let elapsedS: Int
        let altitudeM: Double?
        let distanceM: Double?
        let speedMps: Double?
        let heartRate: Int?
        let cadence: Int?
        let powerW: Int?
    }

    /// Per-sample metric the user can color the trail by. The order here is
    /// the order the buttons appear in the "Color by" updatemenu.
    private enum GPSMetric: CaseIterable {
        case heartRate, speed, altitude, cadence, power

        var label: String {
            switch self {
            case .heartRate: return "Heart rate"
            case .speed:     return "Speed"
            case .altitude:  return "Altitude"
            case .cadence:   return "Cadence"
            case .power:     return "Power"
            }
        }

        func value(of s: GPSSample) -> Double? {
            switch self {
            case .heartRate: return s.heartRate.map(Double.init)
            case .speed:     return s.speedMps
            case .altitude:  return s.altitudeM
            case .cadence:   return s.cadence.map(Double.init)
            case .power:     return s.powerW.map(Double.init)
            }
        }
    }

    /// Free, no-API-key raster tile providers. All HTTPS so the default
    /// WKWebView ATS settings let them through; tiles ride on Image() loads
    /// inside MapLibre so cross-origin from a file:// page is fine.
    private enum GPSTileProvider {
        case osm, esri, openTopo
    }

    private static func gpsTileLayers(_ provider: GPSTileProvider) -> [[String: Any]] {
        // `below: "traces"` is critical — without it MapLibre paints the
        // raster on top of the trail and the trail vanishes. Plotly's v2.35
        // migration notes call this out as the #1 gotcha.
        switch provider {
        case .osm:
            return [[
                "below": "traces",
                "sourcetype": "raster",
                "source": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
                "sourceattribution": "© OpenStreetMap contributors",
                "minzoom": 0, "maxzoom": 19,
                "type": "raster",
            ]]
        case .esri:
            return [[
                "below": "traces",
                "sourcetype": "raster",
                "source": ["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],
                "sourceattribution": "Tiles © Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community",
                "minzoom": 0, "maxzoom": 19,
                "type": "raster",
            ]]
        case .openTopo:
            return [[
                "below": "traces",
                "sourcetype": "raster",
                "source": ["https://a.tile.opentopomap.org/{z}/{x}/{y}.png"],
                "sourceattribution": "Map data © OpenStreetMap contributors, SRTM | Style © OpenTopoMap (CC-BY-SA)",
                "minzoom": 0, "maxzoom": 17,
                "type": "raster",
            ]]
        }
    }

    /// 12-stop sample of matplotlib's Viridis colormap, evaluated at
    /// t = 0, 1/11, 2/11, ..., 1. Hardcoded so we don't pull in a colormap
    /// dependency. Rounded to nearest stop in `viridisColor`.
    private static let viridis12: [String] = [
        "#440154", "#481b6d", "#46327e", "#3f4889",
        "#365c8d", "#2e6e8e", "#277f8e", "#21918c",
        "#1fa187", "#4ac16d", "#a5db36", "#fde725",
    ]

    private static func viridisColor(_ t: Double) -> String {
        let idx = Int((t * 11.0).rounded())
        return viridis12[max(0, min(11, idx))]
    }

    /// Filter `MetricKind.allCases` to just the metrics with at least one
    /// non-null sample on this activity, so we don't show e.g. a "Power"
    /// button on a hike with no power meter.
    private static func availableGPSMetrics(samples: [GPSSample]) -> [GPSMetric] {
        return GPSMetric.allCases.filter { metric in
            samples.contains { metric.value(of: $0) != nil }
        }
    }

    /// Compute a MapLibre center+zoom that frames the whole trail, with a
    /// touch of padding. We bias zoom by -1 from the "exact fit" computation
    /// so the trail isn't flush against the edges.
    private static func mapBoundsToCenterZoom(
        samples: [GPSSample]
    ) -> (lat: Double, lon: Double, zoom: Double) {
        let lats = samples.map(\.lat)
        let lons = samples.map(\.lon)
        let latMin = lats.min() ?? 0, latMax = lats.max() ?? 0
        let lonMin = lons.min() ?? 0, lonMax = lons.max() ?? 0
        let centerLat = (latMin + latMax) / 2
        let centerLon = (lonMin + lonMax) / 2
        // Longitudes shrink toward the poles in Mercator, so the effective
        // east-west span is lon-span × cos(lat). Take the wider of the two
        // dimensions to compute zoom.
        let latSpan = max(latMax - latMin, 0.0005)
        let lonSpanMerc = max((lonMax - lonMin) * cos(centerLat * .pi / 180), 0.0005)
        let span = max(latSpan, lonSpanMerc)
        // log2(360/span) is the zoom at which `span` exactly fills the viewport;
        // -1 leaves margin around the trail. Clamp so weird tiny / huge tracks
        // don't blow up the projection.
        let zoom = max(2.0, min(16.0, log2(360.0 / span) - 1.0))
        return (centerLat, centerLon, zoom)
    }

    /// Per-point hover text shown by the always-on plain trace. Two groups
    /// joined by a faint `<hr>` (styled in style.css):
    ///   - Physical properties: position (lat/lon, altitude) + motion
    ///     (speed, distance, elapsed time)
    ///   - Body metrics: heart rate, cadence, power
    /// The body group (and the separator) is skipped entirely if none of
    /// the physiology fields have data on this sample.
    private static func gpsHoverText(_ s: GPSSample) -> String {
        var physical: [String] = []
        physical.append(String(format: "%.5f, %.5f", s.lat, s.lon))
        if let alt = s.altitudeM {
            physical.append(String(format: "%.0f m", alt))
        }
        if let speed = s.speedMps {
            physical.append(String(format: "%.1f km/h", speed * 3.6))
        }
        if let dist = s.distanceM {
            physical.append(String(format: "%.2f km", dist / 1000))
        }
        physical.append("t+" + formatDuration(Double(s.elapsedS)))

        var body: [String] = []
        if let hr = s.heartRate { body.append("\(hr) bpm") }
        if let cad = s.cadence  { body.append("\(cad) spm") }
        if let pw = s.powerW    { body.append("\(pw) W") }

        let physicalStr = physical.joined(separator: "<br>")
        if body.isEmpty { return physicalStr }
        return physicalStr + "<hr>" + body.joined(separator: "<br>")
    }

    /// Build one scattermap line trace per non-empty Viridis bucket for the
    /// given metric. Each segment `(i, i+1)` is assigned to the bucket of its
    /// midpoint metric value, and segments inside the same bucket are joined
    /// with `NSNull()` separators so they render as separate strokes
    /// (otherwise scattermap would draw a connecting line across the whole
    /// trace, painting the wrong color over other parts of the route).
    private static func bucketedSegments(
        samples: [GPSSample],
        metric: GPSMetric,
        buckets K: Int
    ) -> [[String: Any]] {
        let values = samples.compactMap { metric.value(of: $0) }
        guard values.count >= 2 else { return [] }
        let vMin = values.min()!
        let vMax = values.max()!
        let vRange = vMax - vMin
        guard vRange > 0 else { return [] }

        var bucketLat: [[Any]] = Array(repeating: [], count: K)
        var bucketLon: [[Any]] = Array(repeating: [], count: K)

        for i in 0..<(samples.count - 1) {
            let s0 = samples[i]
            let s1 = samples[i + 1]
            guard
                let v0 = metric.value(of: s0),
                let v1 = metric.value(of: s1)
            else { continue }
            let frac = (((v0 + v1) / 2) - vMin) / vRange
            let idx = Int((frac * Double(K - 1)).rounded())
            let k = max(0, min(K - 1, idx))
            bucketLat[k].append(s0.lat)
            bucketLat[k].append(s1.lat)
            bucketLat[k].append(NSNull())
            bucketLon[k].append(s0.lon)
            bucketLon[k].append(s1.lon)
            bucketLon[k].append(NSNull())
        }

        var traces: [[String: Any]] = []
        for k in 0..<K where !bucketLat[k].isEmpty {
            let color = viridisColor(Double(k) / Double(K - 1))
            traces.append([
                "type": "scattermap",
                "lat": bucketLat[k],
                "lon": bucketLon[k],
                "mode": "lines",
                "line": ["color": color, "width": 3] as [String: Any],
                "hoverinfo": "skip",
                "showlegend": false,
                "visible": false,
            ])
        }
        return traces
    }

    /// Anything longer than this between adjacent samples counts as a pause.
    /// Garmin records GPS at ~1 Hz on the Instinct 3, so a gap > 10 s is
    /// either an explicit pause, an auto-pause, or signal loss while
    /// stationary — all worth marking with a "T" indicator.
    private static let gpsPauseGapSeconds: Int = 10

    /// Walk the samples and emit one (lat, lon, gapSeconds) per detected
    /// pause. The lat/lon is the geographic midpoint of the gap, which on
    /// most pauses lands right where the user actually stopped (since the
    /// before/after samples are normally within a few meters of each other).
    private static func detectGPSPauses(
        samples: [GPSSample]
    ) -> [(lat: Double, lon: Double, gapS: Int)] {
        var pauses: [(lat: Double, lon: Double, gapS: Int)] = []
        for i in 0..<(samples.count - 1) {
            let gap = samples[i + 1].elapsedS - samples[i].elapsedS
            if gap > gpsPauseGapSeconds {
                let midLat = (samples[i].lat + samples[i + 1].lat) / 2
                let midLon = (samples[i].lon + samples[i + 1].lon) / 2
                pauses.append((midLat, midLon, gap))
            }
        }
        return pauses
    }

    public static func activityGPSMap(
        from db: Database,
        activityID: Int,
        trim: TrimState? = nil
    ) throws -> [String: Any] {
        let chartID = "activity-gps-map"
        let allRows = try db.query(
            Queries.activityRecords,
            bind: [.int(Int64(activityID))]
        )
        let rows = ActivityTrim.filter(allRows, with: trim)

        // 1. Pull samples from rows. Drop rows without lat/lon — those are
        //    valid activity records but useless for a map.
        var samples: [GPSSample] = []
        samples.reserveCapacity(rows.count)
        for row in rows {
            guard
                let lat = row.double("lat_deg"),
                let lon = row.double("lon_deg")
            else { continue }
            samples.append(GPSSample(
                lat: lat,
                lon: lon,
                elapsedS: row.int("elapsed_s") ?? 0,
                altitudeM: row.double("altitude_m"),
                distanceM: row.double("distance_m"),
                speedMps: row.double("speed_mps"),
                heartRate: row.int("heart_rate"),
                cadence: row.int("cadence"),
                powerW: row.int("power_w")
            ))
        }
        guard samples.count >= 2 else {
            return emptyPayload(chartID: chartID, message: "No GPS data for this activity")
        }

        // 2. Center + zoom from bounds (Mercator-aware).
        let (centerLat, centerLon, zoom) = mapBoundsToCenterZoom(samples: samples)

        // 3. The always-on black outline trace. scattermap line traces have
        //    no native stroke property, so we get a hairline outline by
        //    drawing a slightly wider black line UNDERNEATH everything else.
        //    With colored traces at width 3 above, an outline at width 5
        //    leaves a 1px hairline of black on each side — enough contrast
        //    against bright satellite imagery without dominating road tiles.
        let lats = samples.map(\.lat)
        let lons = samples.map(\.lon)
        let outlineTrace: [String: Any] = [
            "type": "scattermap",
            "lat": lats,
            "lon": lons,
            "mode": "lines",
            "line": ["color": "#000000", "width": 5] as [String: Any],
            "hoverinfo": "skip",
            "showlegend": false,
            "visible": true,
        ]

        // 4. The always-on plain underlay, drawn over the outline. This trace
        //    serves two purposes:
        //    (a) it's the visual when no metric is selected ("Plain" mode),
        //    (b) it carries the per-point hovertext that drives the corner
        //        legend (see `installGPSHoverLegend` in charts.js). It stays
        //        visible in metric mode and shows through any segments where
        //        the chosen metric was null — turning gaps into "no data
        //        here" hints rather than holes in the trail.
        //
        //    `hoverinfo: "none"` suppresses Plotly's default tooltip while
        //    still firing `plotly_hover` events — the JS handler reads
        //    `pt.text` from those events and writes it into the corner
        //    legend overlay. The rainbow traces use `hoverinfo: "skip"` so
        //    they neither display nor fire events.
        let plainTrace: [String: Any] = [
            "type": "scattermap",
            "lat": lats,
            "lon": lons,
            "mode": "lines+markers",
            "line": ["color": "#4ec9b0", "width": 3] as [String: Any],
            "marker": ["size": 4, "color": "#4ec9b0", "opacity": 0.85] as [String: Any],
            "text": samples.map(gpsHoverText),
            "hoverinfo": "none",
            "name": "route",
            "showlegend": false,
            "visible": true,
        ]

        // 5. Build rainbow trace groups, one per available metric. Track the
        //    rainbowTraces-relative range each metric occupies so we can
        //    construct visibility arrays for the "Color by" buttons.
        let metrics = availableGPSMetrics(samples: samples)
        var rainbowTraces: [[String: Any]] = []
        var metricRanges: [(metric: GPSMetric, range: Range<Int>)] = []
        for metric in metrics {
            let start = rainbowTraces.count
            let group = bucketedSegments(samples: samples, metric: metric, buckets: 12)
            rainbowTraces.append(contentsOf: group)
            let end = rainbowTraces.count
            if end > start {
                metricRanges.append((metric, start..<end))
            }
        }

        // 6. Pause markers — one "T" badge per detected gap > 10s.
        //    `mode: "markers+text"` draws a dark filled circle behind a white
        //    "T" character. Always visible regardless of color mode.
        let pauses = detectGPSPauses(samples: samples)
        let pauseTrace: [String: Any] = [
            "type": "scattermap",
            "lat": pauses.map { $0.lat },
            "lon": pauses.map { $0.lon },
            "mode": "markers+text",
            "marker": [
                "size": 18,
                "color": "#1e1e1e",
                "opacity": 0.92,
            ] as [String: Any],
            "text": pauses.map { _ in "T" },
            "textfont": [
                "color": "#ffffff",
                "size": 12,
                "family": "ui-monospace, Menlo, monospace",
            ] as [String: Any],
            "textposition": "middle center",
            // Distinct hover text from the line samples — events still fire so
            // the corner legend shows it; pauses with longer gaps get a more
            // useful label than just "Paused".
            "hoverinfo": "none",
            "hovertext": pauses.map { p in
                "Paused (\(formatDuration(Double(p.gapS))))"
            },
            "showlegend": false,
            "visible": true,
        ]

        // 7. Start / end markers — vivid green/red dots at samples[0] and
        //    samples[last]. Drawn last so they sit on top of every line.
        let startSample = samples.first!
        let endSample = samples.last!
        let startTrace: [String: Any] = [
            "type": "scattermap",
            "lat": [startSample.lat],
            "lon": [startSample.lon],
            "mode": "markers",
            "marker": [
                "size": 16,
                "color": "#22c55e",  // green-500
                "opacity": 1.0,
            ] as [String: Any],
            "hoverinfo": "none",
            "hovertext": ["Start"],
            "showlegend": false,
            "visible": true,
        ]
        let endTrace: [String: Any] = [
            "type": "scattermap",
            "lat": [endSample.lat],
            "lon": [endSample.lon],
            "mode": "markers",
            "marker": [
                "size": 16,
                "color": "#ef4444",  // red-500
                "opacity": 1.0,
            ] as [String: Any],
            "hoverinfo": "none",
            "hovertext": ["End"],
            "showlegend": false,
            "visible": true,
        ]

        // 8. Final trace order — earlier traces draw underneath later ones:
        //    [outline, plain, ...rainbow, pauses, start, end]
        var allTraces: [[String: Any]] = [outlineTrace, plainTrace]
        allTraces.append(contentsOf: rainbowTraces)
        allTraces.append(pauseTrace)
        allTraces.append(startTrace)
        allTraces.append(endTrace)
        let totalTraces = allTraces.count
        // Index of the first "always on" extra trace (pause) — the three
        // trailing traces (pause, start, end) are visible in every mode.
        let extrasStart = 2 + rainbowTraces.count

        // 9. Visibility array helper. Outline (idx 0), plain (idx 1), and the
        //    three trailing extras (pause / start / end) are always visible;
        //    only the active metric's rainbow traces toggle.
        func visibility(forMetric active: GPSMetric?) -> [Bool] {
            var vis = [Bool](repeating: false, count: totalTraces)
            vis[0] = true  // outline
            vis[1] = true  // plain (carries hover, fills metric gaps)
            if let active = active,
               let entry = metricRanges.first(where: { $0.metric == active }) {
                for i in entry.range { vis[2 + i] = true }
            }
            for i in extrasStart..<totalTraces { vis[i] = true }  // pauses + start + end
            return vis
        }

        // 10. Tile-style updatemenu — relayout `map.layers` between providers.
        let osmLayers = gpsTileLayers(.osm)
        let esriLayers = gpsTileLayers(.esri)
        let topoLayers = gpsTileLayers(.openTopo)
        let tileMenu: [String: Any] = [
            "type": "buttons",
            "direction": "right",
            "showactive": true,
            "active": 0,
            "x": 1.0, "xanchor": "right",
            "y": 1.02, "yanchor": "bottom",
            "pad": ["t": 2, "r": 4, "b": 2, "l": 4] as [String: Any],
            "bgcolor": "#1e1e1e",
            "bordercolor": "#444444",
            "font": ["color": "#dddddd", "size": 10] as [String: Any],
            "buttons": [
                ["label": "Road",      "method": "relayout", "args": [["map.layers": osmLayers]]],
                ["label": "Satellite", "method": "relayout", "args": [["map.layers": esriLayers]]],
                ["label": "Topo",      "method": "relayout", "args": [["map.layers": topoLayers]]],
            ] as [[String: Any]],
        ]

        // 11. Color-by updatemenu — restyle `visible` across all traces.
        var colorButtons: [[String: Any]] = [
            [
                "label": "Plain",
                "method": "restyle",
                "args": [["visible": visibility(forMetric: nil)]],
            ]
        ]
        for entry in metricRanges {
            colorButtons.append([
                "label": entry.metric.label,
                "method": "restyle",
                "args": [["visible": visibility(forMetric: entry.metric)]],
            ])
        }
        let colorMenu: [String: Any] = [
            "type": "buttons",
            "direction": "right",
            "showactive": true,
            "active": 0,
            "x": 0.0, "xanchor": "left",
            "y": 1.02, "yanchor": "bottom",
            "pad": ["t": 2, "r": 4, "b": 2, "l": 4] as [String: Any],
            "bgcolor": "#1e1e1e",
            "bordercolor": "#444444",
            "font": ["color": "#dddddd", "size": 10] as [String: Any],
            "buttons": colorButtons,
        ]

        // 12. Layout. Note `map` (singular) — Plotly v2.35+ MapLibre namespace,
        //     NOT the deprecated `mapbox`.
        let layout: [String: Any] = [
            "title": [
                "text": "GPS trail",
                "font": ["color": "#dddddd", "size": 14] as [String: Any],
                "x": 0.5, "xanchor": "center",
                "y": 0.99, "yref": "container", "yanchor": "top",
            ] as [String: Any],
            "paper_bgcolor": "rgba(0,0,0,0)",
            "map": [
                "style": "white-bg",
                "center": ["lat": centerLat, "lon": centerLon] as [String: Any],
                "zoom": zoom,
                "layers": osmLayers,
            ] as [String: Any],
            // Small left/right margins so the updatemenu button bars (color
            // tabs on the left, tile-style tabs on the right) live in a
            // stable margin area instead of riding the very edge of the
            // SVG, where sub-pixel resize jitter can clip them.
            "margin": ["l": 8, "r": 8, "t": 60, "b": 0] as [String: Any],
            "height": 560,
            "showlegend": false,
            "updatemenus": [tileMenu, colorMenu],
            "hoverlabel": [
                "bgcolor": "#1e1e1e",
                "bordercolor": "#444444",
                "font": ["color": "#dddddd", "size": 11] as [String: Any],
            ] as [String: Any],
        ]

        // Per-sample stash for the trim controls' live drag preview. JS
        // pulls these off the rendered slot and uses them to build
        // null-replaced lat/lon arrays during pointer-move without a Swift
        // round-trip.
        //
        // IMPORTANT: build from the UNFILTERED rows (`allRows`), not the
        // trimmed `samples` array above. If a user has saved a trim and
        // later drags a handle back outward to extend the kept range, the
        // JS preview needs lat/lon for samples *outside* the current
        // filter — otherwise the polyline would just stop at the old trim
        // boundary even as the handle moves past it.
        var trimSamples: [[String: Any]] = []
        trimSamples.reserveCapacity(allRows.count)
        for row in allRows {
            guard
                let lat = row.double("lat_deg"),
                let lon = row.double("lon_deg"),
                let e = row.int("elapsed_s")
            else { continue }
            trimSamples.append(["lat": lat, "lon": lon, "elapsedS": e])
        }
        let trimTargets: [String: Any] = [
            "outline_idx": 0,
            "plain_idx": 1,
            // The pause / start / end traces are appended in that order at
            // the very end of `allTraces`, so:
            "start_idx": totalTraces - 2,
            "end_idx": totalTraces - 1,
            "samples": trimSamples,
        ]

        return [
            "chart": chartID,
            "data": allTraces,
            "layout": layout,
            "config": defaultConfig,
            "trim_targets": trimTargets,
        ]
    }

    // MARK: - Wellness / stress-body-battery-ts

    static let stressBBDefaultInterval: ChartInterval = .week
    static let stressBBIntervals: [ChartInterval] = [.day, .week, .month]

    public static func stressBodyBatteryTS(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "stress-body-battery-ts"
        let window = ChartWindowStore.shared.window(
            for: chartID, defaultInterval: stressBBDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(timestamp_utc) AS date_min, MAX(timestamp_utc) AS date_max FROM wellness_samples
            WHERE device_id = ?
              AND metric IN ('stress_level', 'body_battery_level')
              AND value IS NOT NULL
            """, bind: [.int(Int64(deviceID))])
        let rows = try db.query(
            Queries.wellnessStressAndBodyBatteryWindowed,
            bind: [
                .int(Int64(deviceID)),
                .text(window.startTimestampISO),
                .text(window.endTimestampISO),
            ]
        )
        guard !rows.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID, message: "No stress/body battery data in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: stressBBIntervals, dataRange: dataRange
            )
            return payload
        }

        // Bucket the (already-time-ordered) rows by metric, then walk each
        // bucket and inject explicit null y-values whenever consecutive
        // samples are more than 5 minutes apart. The watch records these
        // metrics at 1-minute cadence when worn; a > 5 min gap means it
        // came off the wrist, and we want the line to break visibly there
        // instead of bridging the dead time.
        var stressRaw: [(date: Date, iso: String, val: Double)] = []
        var bbRaw: [(date: Date, iso: String, val: Double)] = []
        for row in rows {
            guard
                let ts = row.string("timestamp_utc"),
                let date = Database.iso8601.date(from: ts),
                let val = row.double("value")
            else { continue }
            let metric = row.string("metric") ?? ""
            if metric == "stress_level" {
                stressRaw.append((date, ts, val))
            } else if metric == "body_battery_level" {
                bbRaw.append((date, ts, val))
            }
        }

        let (stressX, stressY) = insertGapNulls(stressRaw, gapSeconds: 300)
        let (bbX, bbY) = insertGapNulls(bbRaw, gapSeconds: 300)

        let stressTrace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": stressX, "y": stressY,
            "name": "stress",
            "line": ["color": "#f48771", "width": 1.5],
            "hovertemplate": "%{x|%b %-d, %-l:%M %p}<br>stress %{y:.0f}<extra></extra>",
            "connectgaps": false,
        ]
        let bbTrace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": bbX, "y": bbY,
            "name": "body battery",
            "line": ["color": "#4ec9b0", "width": 1.5],
            "hovertemplate": "%{x|%b %-d, %-l:%M %p}<br>body battery %{y:.0f}<extra></extra>",
            "connectgaps": false,
        ]

        var layout = darkLayout(title: "Stress + body battery", height: 300)
        layout["xaxis"] = dateAxisLayout(for: window)
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["range"] = [0, 100]
        layout["yaxis"] = yaxis
        layout["showlegend"] = true
        layout["legend"] = topHorizontalLegend

        return [
            "chart": chartID,
            "data": [stressTrace, bbTrace],
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: stressBBIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Wellness / daily-intensity-minutes-bar

    static let intensityDefaultInterval: ChartInterval = .month
    static let intensityIntervals: [ChartInterval] = [.week, .month, .year, .all]

    public static func dailyIntensityMinutesBar(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "daily-intensity-minutes-bar"
        let window = ChartWindowStore.shared.window(
            for: chartID, defaultInterval: intensityDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(date_local) AS date_min, MAX(date_local) AS date_max FROM wellness_daily
            WHERE device_id = ? AND intensity_min IS NOT NULL
            """, bind: [.int(Int64(deviceID))])
        let rows: [Row]
        if window.interval == .all {
            rows = try db.query("""
                SELECT date_local, intensity_min FROM wellness_daily
                WHERE device_id = ? AND intensity_min IS NOT NULL
                ORDER BY date_local
                """, bind: [.int(Int64(deviceID))])
        } else {
            rows = try db.query(
                Queries.wellnessIntensityMinutesWindowed,
                bind: [
                    .int(Int64(deviceID)),
                    .text(window.startDateLocal),
                    .text(window.endDateLocal),
                ]
            )
        }
        var raw: [(date: Date, value: Double?)] = []
        for row in rows {
            guard
                let dayStr = row.string("date_local"),
                let date = DateUtil.day(from: dayStr)
            else { continue }
            raw.append((date, row.int("intensity_min").map(Double.init)))
        }
        guard !raw.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID, message: "No intensity data in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: intensityIntervals, dataRange: dataRange
            )
            return payload
        }
        let dense = DateUtil.fillGaps(raw)

        let xs = dense.map { DateUtil.dayString(from: $0.date) }
        let ys: [Any] = dense.map { nullable($0.value) }

        let trace: [String: Any] = [
            "type": "bar",
            "x": xs,
            "y": ys,
            "marker": ["color": "#d7ba7d"],
            "hovertemplate": "%{x|%a %b %-d, %Y}<br>%{y:.0f} min<extra></extra>",
        ]

        // Garmin's weekly intensity minutes goal is 150/wk → ~22/day. Show that
        // as a horizontal target line so the user has context.
        var layout = darkLayout(title: "Intensity minutes", height: 280)
        layout["shapes"] = [[
            "type": "line", "xref": "paper",
            "x0": 0, "x1": 1, "y0": 22, "y1": 22,
            "line": ["color": "#888888", "width": 1, "dash": "dash"],
        ] as [String: Any]]
        layout["annotations"] = [[
            "xref": "paper", "x": 1.0, "xanchor": "right",
            "y": 22, "yanchor": "bottom",
            "text": "150/wk goal",
            "showarrow": false,
            "font": ["color": "#888888", "size": 10],
        ] as [String: Any]]
        layout["xaxis"] = dateAxisLayout(for: window)
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["rangemode"] = "tozero"
        layout["yaxis"] = yaxis
        layout["bargap"] = 0.25

        return [
            "chart": chartID,
            "data": [trace],
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: intensityIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Wellness / steps-hourly-heatmap (actually HR-by-hour)
    //
    // The plan called this "hourly steps heatmap" but the wellness_samples
    // table doesn't include intraday step data on the Instinct 3 — only HR,
    // stress, body battery. We do the same idea for HR: day-of-week × hour-of-day
    // grid showing your typical heart rate by time of day, which is just as
    // useful for spotting circadian patterns.

    static let hourlyHRDefaultInterval: ChartInterval = .month
    static let hourlyHRIntervals: [ChartInterval] = [.month, .year, .all]

    public static func hourlyHRHeatmap(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "steps-hourly-heatmap"
        let window = ChartWindowStore.shared.window(
            for: chartID, defaultInterval: hourlyHRDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(timestamp_utc) AS date_min, MAX(timestamp_utc) AS date_max FROM wellness_samples
            WHERE device_id = ? AND metric = 'heart_rate' AND value IS NOT NULL
            """, bind: [.int(Int64(deviceID))])
        let rows: [Row]
        if window.interval == .all {
            rows = try db.query("""
                SELECT timestamp_utc, value, local_offset_s FROM wellness_samples
                WHERE device_id = ? AND metric = 'heart_rate' AND value IS NOT NULL
                """, bind: [.int(Int64(deviceID))])
        } else {
            rows = try db.query(
                Queries.wellnessIntradayHRWindowed,
                bind: [
                    .int(Int64(deviceID)),
                    .text(window.startTimestampISO),
                    .text(window.endTimestampISO),
                ]
            )
        }
        guard !rows.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID,
                message: "No intraday HR data in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: hourlyHRIntervals, dataRange: dataRange
            )
            return payload
        }
        // Bucket: [dow][hour] → (sum, count) → mean. Hour and day-of-week
        // are computed in the wearer's local zone (per-row offset, falling
        // back to system TZ) so the heatmap actually reflects when the user
        // was awake / active rather than UTC noon.
        var sums: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var counts: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)

        for row in rows {
            guard
                let tsStr = row.string("timestamp_utc"),
                let date = Database.iso8601.date(from: tsStr),
                let val = row.double("value")
            else { continue }
            let cal = DateUtil.localCalendar(offsetSeconds: row.int("local_offset_s"))
            let dow = cal.component(.weekday, from: date) - 1
            let hour = cal.component(.hour, from: date)
            guard dow >= 0 && dow < 7 && hour >= 0 && hour < 24 else { continue }
            sums[dow][hour] += val
            counts[dow][hour] += 1
        }

        var z: [[Any]] = Array(repeating: Array(repeating: NSNull() as Any, count: 24), count: 7)
        for d in 0..<7 {
            for h in 0..<24 where counts[d][h] > 0 {
                z[d][h] = sums[d][h] / Double(counts[d][h])
            }
        }

        let trace: [String: Any] = [
            "type": "heatmap",
            "z": z,
            "x": (0..<24).map { String($0) },
            "y": ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
            "colorscale": "Viridis",
            "hoverongaps": false,
            "hovertemplate": "%{y} %{x}:00<br>%{z:.0f} bpm<extra></extra>",
            "xgap": 1, "ygap": 1,
            "colorbar": [
                "title": ["text": "bpm", "side": "right"],
                "thickness": 12, "len": 0.7,
                "outlinewidth": 0,
                "tickfont": ["color": "#aaaaaa", "size": 10],
            ] as [String: Any],
        ]

        var layout = darkLayout(title: "Average HR by hour-of-day", height: 280)
        var xaxis = layout["xaxis"] as! [String: Any]
        xaxis["type"] = "category"
        xaxis["title"] = ["text": "hour", "font": ["color": "#888888", "size": 10]]
        layout["xaxis"] = xaxis
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["type"] = "category"
        yaxis["autorange"] = "reversed"
        layout["yaxis"] = yaxis

        return [
            "chart": chartID,
            "data": [trace],
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: hourlyHRIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Sleep / hypnogram

    public static func sleepHypnogram(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        guard let session = try db.queryOne(
            Queries.sleepLatestSession,
            bind: [.int(Int64(deviceID))]
        ) else {
            return emptyPayload(chartID: "sleep-hypnogram", message: "No sleep data yet")
        }
        let sleepID = session.int("sleep_id") ?? 0
        let stages = try db.query(
            Queries.sleepStagesForSession,
            bind: [.int(Int64(sleepID))]
        )

        // Stage colors. Y values are level numbers so the chart looks like a
        // step-down hypnogram (deep at bottom, awake at top).
        let stageMap: [String: (level: Double, color: String)] = [
            "awake":   (4, "#f48771"),
            "rem":     (3, "#c586c0"),
            "light":   (2, "#569cd6"),
            "deep":    (1, "#4ec9b0"),
            "unknown": (0, "#666666"),
        ]

        var xs: [String] = []
        var ys: [Any] = []
        var colors: [String] = []
        for row in stages {
            guard
                let startStr = row.string("start_utc"),
                let endStr = row.string("end_utc"),
                Database.iso8601.date(from: startStr) != nil,
                Database.iso8601.date(from: endStr) != nil
            else { continue }
            let stage = row.string("stage")?.lowercased() ?? "unknown"
            let map = stageMap[stage] ?? stageMap["unknown"]!
            // Plot two points per stage segment to make a horizontal "shelf".
            xs.append(startStr); ys.append(map.level); colors.append(map.color)
            xs.append(endStr);   ys.append(map.level); colors.append(map.color)
            xs.append("");       ys.append(NSNull());  colors.append(map.color)  // gap
        }
        guard !xs.isEmpty else {
            return emptyPayload(chartID: "sleep-hypnogram", message: "No sleep stages parsed")
        }

        let trace: [String: Any] = [
            "type": "scatter", "mode": "lines",
            "x": xs, "y": ys,
            "line": ["color": "#4ec9b0", "width": 4, "shape": "hv"],
            "connectgaps": false,
            "hovertemplate": "%{x}<br>level %{y}<extra></extra>",
        ]

        let scoreText: String
        if let score = session.int("sleep_score") {
            scoreText = "score \(score)"
        } else {
            scoreText = "—"
        }

        var layout = darkLayout(title: "Last night — \(scoreText)", height: 260)
        var xaxis = layout["xaxis"] as! [String: Any]
        xaxis["type"] = "date"
        layout["xaxis"] = xaxis
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["tickvals"] = [1, 2, 3, 4]
        yaxis["ticktext"] = ["deep", "light", "REM", "awake"]
        yaxis["range"] = [0.5, 4.5]
        layout["yaxis"] = yaxis

        return [
            "chart": "sleep-hypnogram",
            "data": [trace],
            "layout": layout,
            "config": defaultConfig,
        ]
    }

    // MARK: - Sleep / regularity-heatmap

    static let sleepRegularityDefaultInterval: ChartInterval = .month
    static let sleepRegularityIntervals: [ChartInterval] = [.month, .year, .all]

    public static func sleepRegularityHeatmap(
        from db: Database,
        deviceID: Int
    ) throws -> [String: Any] {
        let chartID = "sleep-regularity-heatmap"
        let window = ChartWindowStore.shared.window(
            for: chartID, defaultInterval: sleepRegularityDefaultInterval
        )
        let dataRange = dataDateRange(db, sql: """
            SELECT MIN(start_utc) AS date_min, MAX(end_utc) AS date_max FROM sleep_sessions
            WHERE device_id = ?
            """, bind: [.int(Int64(deviceID))])
        let rows: [Row]
        if window.interval == .all {
            rows = try db.query("""
                SELECT start_utc, end_utc, sleep_score FROM sleep_sessions
                WHERE device_id = ? ORDER BY start_utc
                """, bind: [.int(Int64(deviceID))])
        } else {
            rows = try db.query(
                Queries.sleepSessionsWindowed,
                bind: [
                    .int(Int64(deviceID)),
                    .text(window.startTimestampISO),
                    .text(window.endTimestampISO),
                ]
            )
        }
        guard !rows.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID,
                message: "No sleep sessions in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: sleepRegularityIntervals, dataRange: dataRange
            )
            return payload
        }
        // Build a [day-row][hour-col] grid where each cell is 1 if the user
        // was asleep at that hour. Day-of-row and hour-of-column are both
        // computed in the wearer's local time zone (per-session offset from
        // sleep_sessions.local_offset_s, falling back to system TZ when the
        // session predates the schema-v2 column or was logged with no
        // offset). Otherwise the heatmap shows UTC-noon-as-bedtime, which
        // is meaningless for circadian patterns.
        struct LocalSession {
            let start: Date
            let end: Date
            let cal: Calendar
        }
        var rawSessions: [LocalSession] = []
        for row in rows {
            guard
                let s = row.string("start_utc"),
                let e = row.string("end_utc"),
                let sd = Database.iso8601.date(from: s),
                let ed = Database.iso8601.date(from: e)
            else { continue }
            let cal = DateUtil.localCalendar(offsetSeconds: row.int("local_offset_s"))
            rawSessions.append(LocalSession(start: sd, end: ed, cal: cal))
        }
        guard !rawSessions.isEmpty else {
            var payload = emptyPayload(
                chartID: chartID,
                message: "No sleep sessions in this window"
            )
            payload["window"] = windowControlsPayload(
                window: window, intervals: sleepRegularityIntervals, dataRange: dataRange
            )
            return payload
        }

        // Anchor: the right edge of the window (or "today" for `.all`),
        // pinned to start-of-day in the most recent session's local zone.
        let anchorCal = rawSessions.last!.cal
        let anchorRef = window.interval == .all ? Date() : window.endDate
        let anchorDay = anchorCal.startOfDay(for: anchorRef)
        // Number of day rows = the window span. For `.all`, default to 90.
        let numDays = window.interval == .all ? 90 : window.interval.spanDays
        var z: [[Any]] = Array(repeating: Array(repeating: NSNull() as Any, count: 24), count: numDays)
        var dayLabels: [String] = []
        for i in 0..<numDays {
            let day = DateUtil.adding(days: -(numDays - 1 - i), to: anchorDay)
            dayLabels.append(DateUtil.dayString(from: day))
        }

        for sess in rawSessions {
            // Walk hour by hour through the session, using THIS session's
            // local calendar to bucket. Different sessions can have different
            // offsets if the user travelled between them.
            var cursor = sess.start
            while cursor < sess.end {
                let day = sess.cal.startOfDay(for: cursor)
                let dayOffset = sess.cal.dateComponents([.day], from: day, to: anchorDay).day.map { -$0 } ?? 0
                let dayIndex = dayOffset + (numDays - 1)
                let hour = sess.cal.component(.hour, from: cursor)
                if dayIndex >= 0 && dayIndex < numDays && hour >= 0 && hour < 24 {
                    z[dayIndex][hour] = 1.0
                }
                cursor = cursor.addingTimeInterval(60 * 60)
            }
        }

        let trace: [String: Any] = [
            "type": "heatmap",
            "z": z,
            "x": (0..<24).map { String($0) },
            "y": dayLabels,
            "colorscale": [
                [0.0, "#1e1e1e"],
                [1.0, "#4ec9b0"],
            ] as [Any],
            "showscale": false,
            "hoverongaps": false,
            "hovertemplate": "%{y} %{x}:00<br>asleep<extra></extra>",
            "xgap": 0, "ygap": 1,
        ]

        var layout = darkLayout(title: "Sleep regularity", height: 380)
        var xaxis = layout["xaxis"] as! [String: Any]
        xaxis["type"] = "category"
        xaxis["title"] = ["text": "hour", "font": ["color": "#888888", "size": 10]]
        xaxis["nticks"] = 12
        layout["xaxis"] = xaxis
        var yaxis = layout["yaxis"] as! [String: Any]
        yaxis["type"] = "category"
        yaxis["nticks"] = 8
        layout["yaxis"] = yaxis
        layout["margin"] = ["l": 80, "r": 30, "t": 40, "b": 50]

        return [
            "chart": chartID,
            "data": [trace],
            "layout": layout,
            "config": defaultConfig,
            "window": windowControlsPayload(
                window: window, intervals: sleepRegularityIntervals, dataRange: dataRange
            ),
        ]
    }

    // MARK: - Sync / runs table + summary banner

    public static func syncRunsPayload(from db: Database) throws -> [String: Any] {
        let rows = try db.query(Queries.syncRunsHistory)
        var out: [[String: Any]] = []
        for row in rows {
            out.append([
                "started": shortDateTimeLabel(row.string("started_utc") ?? ""),
                "subcommand": row.string("subcommand") ?? "",
                "files": row.int("files_downloaded") ?? 0,
                "bytes": formatBytes(row.int("bytes_downloaded") ?? 0),
                "errors": row.int("errors_count") ?? 0,
                "exit_code": (row.int("exit_code") as Any?) ?? NSNull(),
            ])
        }
        return ["chart": "sync-runs", "rows": out]
    }

    public static func syncSummaryPayload(
        from db: Database,
        deviceID: Int?,
        busy: Bool
    ) throws -> [String: Any] {
        let lastPullISO = try db.scalarString(Queries.syncLastSuccessfulPull) ?? ""
        let lastSync: String
        if lastPullISO.isEmpty {
            lastSync = "Last sync: never"
        } else {
            lastSync = "Last sync: \(shortDateTimeLabel(lastPullISO))"
        }

        var deviceInfo = ""
        if let deviceID = deviceID,
           let row = try db.queryOne(
                "SELECT model, serial, software_version FROM devices WHERE device_id = ?",
                bind: [.int(Int64(deviceID))]
            )
        {
            let model = row.string("model") ?? "?"
            let serial = row.string("serial") ?? "?"
            let fw = row.string("software_version") ?? "?"
            deviceInfo = "\(model) • serial \(serial) • fw \(fw)"
        }

        return [
            "chart": "sync-summary",
            "lastSync": lastSync,
            "deviceInfo": deviceInfo,
            "busy": busy,
        ]
    }

    // MARK: - Local format helpers

    static func shortDateTimeLabel(_ iso: String) -> String {
        guard let date = Database.iso8601.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KiB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MiB", mb) }
        return String(format: "%.1f GiB", mb / 1024)
    }
}
