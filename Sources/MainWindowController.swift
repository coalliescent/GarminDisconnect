// MainWindowController.swift
//
// Owns the main window, the toolbar, and the single shared WebChartView that
// all charts render into. Tab switching is JS-side: the toolbar segmented
// control just calls `WebChartView.showTab()` and the HTML page toggles
// section visibility. The Sync tab is also rendered in HTML inside the same
// WebChartView (no AppKit/WebKit mixing).
//
// Responsibilities:
//   1. Window + toolbar setup (delegates to ToolbarBuilder)
//   2. Routing toolbar actions: tab switch, device pick, sync request
//   3. Listening to AppState notifications (database, devices, dataVersion)
//      and SyncCoordinator notifications
//   4. Telling the WebChartView which charts to render after each state change
//   5. Routing JS messages back to Swift handlers (activitySelected,
//      syncRequested, etc.)

import AppKit

final class MainWindowController: NSWindowController, WebChartViewDelegate {

    private var toolbarBuilder: ToolbarBuilder!
    private let webChartView = WebChartView(frame: .zero)
    private let contentContainer = NSView()
    private var welcomeView: WelcomeView?
    private var currentTab: Tab = .overview
    /// Activity id currently expanded in the Activities tab detail section.
    private var selectedActivityID: Int?

    convenience init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "GarminDisconnect"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.setFrameAutosaveName("GarminDisconnect.MainWindow")
        self.init(window: window)
        configure()
    }

    private func configure() {
        guard let window = window else { return }

        toolbarBuilder = ToolbarBuilder(target: self)
        window.toolbar = toolbarBuilder.make()

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let root = NSView(frame: window.frame)
        root.wantsLayer = true
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root

        webChartView.translatesAutoresizingMaskIntoConstraints = false
        webChartView.delegate = self

        applyState()
        // First-launch multi-device modal: only fires if there's >1 device AND
        // the user hasn't explicitly picked one yet. Deferred until after the
        // window is on screen so the sheet has somewhere to attach.
        DispatchQueue.main.async { [weak self] in
            self?.maybePresentDevicePickerOnFirstLaunch()
        }

        // Listen for AppState + sync notifications.
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(databaseStateChanged(_:)),
            name: .databaseStateChanged, object: nil
        )
        nc.addObserver(
            self, selector: #selector(selectedDeviceChanged(_:)),
            name: .selectedDeviceChanged, object: nil
        )
        nc.addObserver(
            self, selector: #selector(dataVersionChanged(_:)),
            name: .dataVersionChanged, object: nil
        )
        nc.addObserver(
            self, selector: #selector(syncStateChanged(_:)),
            name: .syncStateChanged, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - State application

    /// Reconcile the UI to whatever AppState currently says.
    private func applyState() {
        toolbarBuilder.refreshDevicePicker()
        if AppState.shared.database == nil || AppState.shared.devices.isEmpty {
            showWelcome()
        } else {
            showWebContent()
        }
    }

    /// Show the WelcomeView (no DB / no devices).
    private func showWelcome() {
        let view = welcomeView ?? WelcomeView()
        welcomeView = view
        view.update(
            databasePath: AppState.shared.databasePath,
            error: AppState.shared.databaseError
        )
        swapContent(view)
    }

    /// Show the WebChartView (the normal app state) and refresh whichever tab
    /// is currently active.
    private func showWebContent() {
        if webChartView.superview !== contentContainer {
            swapContent(webChartView)
        }
        webChartView.showTab(currentTab.id)
        loadCurrentTab()
    }

    private func swapContent(_ view: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
    }

    // MARK: - Per-tab loading

    /// Build the chart payloads for whichever tab is currently active and
    /// ship them to the WebChartView. Called on tab switch, device change,
    /// data refresh, and welcome→content transition.
    private func loadCurrentTab() {
        guard let db = AppState.shared.database,
              let deviceID = AppState.shared.selectedDeviceID else {
            return
        }
        switch currentTab {
        case .overview:
            webChartView.render(TabLoaders.loadOverviewInsights(db: db, deviceID: deviceID))
            webChartView.render(TabLoaders.loadOverview(db: db, deviceID: deviceID))
        case .activities:
            // Default to the most recent activity if the user hasn't picked
            // one yet. Lets the right pane show real content on first visit
            // instead of just the insight strip + an empty detail section.
            if selectedActivityID == nil {
                selectedActivityID = TabLoaders.mostRecentActivityID(
                    db: db, deviceID: deviceID
                )
            }
            webChartView.render(TabLoaders.loadActivitiesInsights(db: db, deviceID: deviceID))
            webChartView.render(TabLoaders.loadActivities(
                db: db, deviceID: deviceID,
                selectedActivityID: selectedActivityID
            ))
            if let aid = selectedActivityID {
                webChartView.render(TabLoaders.loadActivityDetail(db: db, activityID: aid))
            }
        case .wellness:
            webChartView.render(TabLoaders.loadWellnessInsights(db: db, deviceID: deviceID))
            webChartView.render(TabLoaders.loadWellness(db: db, deviceID: deviceID))
        case .sleep:
            webChartView.render(TabLoaders.loadSleepInsights(db: db, deviceID: deviceID))
            webChartView.render(TabLoaders.loadSleep(db: db, deviceID: deviceID))
        case .sync:
            webChartView.render(
                TabLoaders.loadSync(
                    db: db, deviceID: deviceID, busy: SyncCoordinator.shared.isBusy
                )
            )
        }
    }

    // MARK: - Toolbar action targets

    @objc func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = Tab(rawValue: sender.selectedSegment) else { return }
        currentTab = tab
        webChartView.showTab(tab.id)
        loadCurrentTab()
    }

    @objc func deviceChanged(_ sender: NSPopUpButton) {
        guard let deviceID = sender.selectedItem?.representedObject as? Int else { return }
        AppState.shared.selectDevice(deviceID)
    }

    @objc func syncRequested(_ sender: Any?) {
        SyncCoordinator.shared.requestSync()
    }

    // MARK: - AppState observers

    @objc private func databaseStateChanged(_ note: Notification) {
        applyState()
    }

    @objc private func selectedDeviceChanged(_ note: Notification) {
        toolbarBuilder.refreshDevicePicker()
        loadCurrentTab()
    }

    @objc private func dataVersionChanged(_ note: Notification) {
        // Re-fetch from the (possibly newly populated) database.
        AppState.shared.loadDevices()
        toolbarBuilder.refreshDevicePicker()
        applyState()
    }

    @objc private func syncStateChanged(_ note: Notification) {
        // Surface failures immediately. `.failed` is reached only on the
        // .syncing → .failed edge, so this fires once per failed sync.
        if case .failed(let error) = SyncCoordinator.shared.state {
            presentSyncError(error)
        }
        // Re-render the sync tab (or just its summary banner) so the busy
        // state and the most recent run row are up to date.
        if currentTab == .sync, let db = AppState.shared.database {
            webChartView.render(
                TabLoaders.loadSync(
                    db: db,
                    deviceID: AppState.shared.selectedDeviceID,
                    busy: SyncCoordinator.shared.isBusy
                )
            )
        } else {
            // Even if we're not on the sync tab, push the summary banner
            // alone so it's accurate when the user navigates over.
            if let db = AppState.shared.database {
                if let summary = try? PlotlyEncoder.syncSummaryPayload(
                    from: db,
                    deviceID: AppState.shared.selectedDeviceID,
                    busy: SyncCoordinator.shared.isBusy
                ) {
                    webChartView.render(summary)
                }
            }
        }
    }

    // MARK: - Sync failure modal

    /// Present a sheet describing why a sync failed. Maps the typed Swift-side
    /// errors (and the CLI's "error: ..." lines) into human-readable copy via
    /// `GarminDumpError.alertTitle` / `alertMessage`.
    private func presentSyncError(_ error: Error) {
        guard let window = window else { return }
        let alert = NSAlert()
        if let gde = error as? GarminDumpError {
            alert.messageText = gde.alertTitle
            alert.informativeText = gde.alertMessage
        } else {
            alert.messageText = "Sync failed"
            alert.informativeText = "\(error)"
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - First-launch multi-device modal

    /// If the archive has more than one device and the user has never made a
    /// selection in this app's UserDefaults, present a sheet asking them to
    /// pick a primary. The sheet is one-shot per install — once the user picks,
    /// the choice is persisted via AppState.selectDevice.
    private func maybePresentDevicePickerOnFirstLaunch() {
        guard let window = window else { return }
        let devices = AppState.shared.devices
        guard devices.count > 1 else { return }
        let userPicked = UserDefaults.standard.object(forKey: "GarminDisconnect.selectedDeviceID") != nil
        if userPicked { return }
        // We DID auto-select the most-recently-seen device in AppState.init,
        // but with multiple devices the user should still get a choice up front.

        let alert = NSAlert()
        alert.messageText = "Pick your primary device"
        alert.informativeText = """
            GarminDisconnect found \(devices.count) Garmin devices in your archive. \
            Pick the one you wear most often — you can switch between devices later \
            in the toolbar.
            """
        alert.alertStyle = .informational
        for device in devices {
            alert.addButton(withTitle: device.displayName)
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            // NSAlert returns .alertFirstButtonReturn, .alertSecondButtonReturn, etc.
            let raw = response.rawValue
            let idx = raw - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard idx >= 0 && idx < devices.count else { return }
            AppState.shared.selectDevice(devices[idx].id)
            self?.toolbarBuilder.refreshDevicePicker()
        }
    }

    // MARK: - WebChartViewDelegate

    func webChartView(_ view: WebChartView, didReceiveEvent event: String, payload: [String: Any]) {
        switch event {
        case "pageReady":
            // First chart payloads after page-ready will be flushed by
            // WebChartView's own queue, so this is just informational.
            print("WebChartView: page ready")
        case "syncRequested":
            SyncCoordinator.shared.requestSync()
        case "activitySelected":
            guard let aid = payload["activity_id"] as? Int else { return }
            selectedActivityID = aid
            guard let db = AppState.shared.database else { return }
            webChartView.render(TabLoaders.loadActivityDetail(db: db, activityID: aid))
        case "activityTrimChanged":
            handleActivityTrimChanged(payload)
        case "activityTrimReset":
            handleActivityTrimReset(payload)
        case "chartWindowChanged":
            handleChartWindowChanged(payload)
        case "chartWindowShifted":
            handleChartWindowShifted(payload)
        case "renderError":
            print("WebChartView: render error: \(payload["error"] ?? "<unknown>")")
        case "chartClicked":
            handleChartClicked(payload)
        case "sleepNightSelected":
            handleSleepNightSelected(payload)
        default:
            print("WebChartView: unhandled event \(event)")
        }
    }

    /// Plotly click events are routed here. The sleep regularity heatmap
    /// carries a `customdata` of sleep_id per cell so the user can click
    /// any night in the grid to load its hero detail. Other charts can be
    /// added here as their click semantics are defined.
    private func handleChartClicked(_ payload: [String: Any]) {
        let chartID = payload["chart"] as? String ?? ""
        if chartID == "sleep-regularity-heatmap" {
            handleSleepNightSelected(payload)
        }
    }

    /// User clicked a cell in the sleep regularity heatmap. The cell carries
    /// `customdata` = sleep_id; reload the hero (hypnogram + donut + summary)
    /// for that night.
    private func handleSleepNightSelected(_ payload: [String: Any]) {
        let raw = payload["customdata"] ?? payload["sleep_id"] ?? NSNull()
        var sleepID: Int?
        if let n = raw as? Int { sleepID = n }
        else if let d = raw as? Double { sleepID = Int(d) }
        else if let s = raw as? String { sleepID = Int(s) }
        guard let sleepID = sleepID, let db = AppState.shared.database else { return }
        webChartView.render(TabLoaders.loadSleepNight(db: db, sleepID: sleepID))
    }

    /// User picked a new interval (Day/Week/Month/Year/All) on a chart's
    /// tab strip. Update the store and re-render just that chart.
    private func handleChartWindowChanged(_ payload: [String: Any]) {
        guard
            let chartID = payload["chart"] as? String,
            let intervalStr = payload["interval"] as? String,
            let interval = ChartInterval(rawValue: intervalStr)
        else { return }
        ChartWindowStore.shared.setInterval(chartID, interval: interval)
        rerenderWindowedChart(chartID)
    }

    /// User clicked ◀ or ▶ on a chart's interval-picker strip. Shift the
    /// window and re-render just that chart.
    private func handleChartWindowShifted(_ payload: [String: Any]) {
        guard
            let chartID = payload["chart"] as? String,
            let delta = payload["delta"] as? Int
        else { return }
        ChartWindowStore.shared.shift(chartID, by: delta)
        rerenderWindowedChart(chartID)
    }

    /// User finished dragging a trim handle. Persist the new ranges and
    /// re-render every activity-detail chart so the trim is reflected
    /// everywhere (map, pace/altitude, HR zones, timeline).
    private func handleActivityTrimChanged(_ payload: [String: Any]) {
        guard
            let aid = payload["activity_id"] as? Int,
            let rangesRaw = payload["ranges"] as? [[String: Any]],
            let db = AppState.shared.database
        else { return }
        let ranges: [TrimRange] = rangesRaw.compactMap { dict in
            guard let s = dict["startS"] as? Int, let e = dict["endS"] as? Int else { return nil }
            return TrimRange(startElapsedS: s, endElapsedS: e)
        }
        // Empty ranges = the user collapsed everything. Save it as such (so
        // every chart shows "no records") rather than treating it as a
        // reset.
        let state = TrimState(ranges: ranges, auto: false, reason: nil)
        ActivityTrim.save(db: db, activityID: aid, state: state)
        webChartView.render(TabLoaders.loadActivityDetail(db: db, activityID: aid))
    }

    /// User clicked the Reset button next to the timeline. Save an
    /// explicit "kept everything" trim so the auto-trim heuristic doesn't
    /// re-fire on the next view; otherwise resetting an auto-trimmed
    /// activity would just bring the trim right back.
    private func handleActivityTrimReset(_ payload: [String: Any]) {
        guard
            let aid = payload["activity_id"] as? Int,
            let db = AppState.shared.database
        else { return }
        // Compute the activity's full elapsed range so we can record a
        // single TrimRange covering everything. Uses the same elapsed-from-
        // timestamp fallback as Queries.activityRecords because the raw
        // `elapsed_s` column is often NULL.
        var full: TrimRange?
        do {
            let row = try db.queryOne("""
                SELECT
                    0 AS lo,
                    CAST(ROUND((julianday(MAX(timestamp_utc))
                               - julianday(MIN(timestamp_utc))) * 86400.0) AS INTEGER) AS hi
                FROM activity_records WHERE activity_id = ?
                """,
                bind: [.int(Int64(aid))]
            )
            if let lo = row?.int("lo"), let hi = row?.int("hi") {
                full = TrimRange(startElapsedS: lo, endElapsedS: hi)
            }
        } catch {
            print("MainWindowController: trim reset bounds query failed: \(error)")
        }
        if let full = full {
            ActivityTrim.save(db: db, activityID: aid,
                              state: TrimState(ranges: [full], auto: false, reason: nil))
        } else {
            // Couldn't determine bounds — fall back to deleting the row.
            ActivityTrim.save(db: db, activityID: aid, state: nil)
        }
        webChartView.render(TabLoaders.loadActivityDetail(db: db, activityID: aid))
    }

    /// Rebuild a single windowed chart's payload and ship it back to the
    /// WebChartView. Dispatches per chart-id because each one calls a
    /// different PlotlyEncoder builder. The user can change the interval on
    /// any of these charts and only that one chart re-renders — the rest of
    /// the tab keeps its existing canvases.
    private func rerenderWindowedChart(_ chartID: String) {
        guard
            let db = AppState.shared.database,
            let deviceID = AppState.shared.selectedDeviceID
        else { return }
        do {
            let payload: [String: Any]
            switch chartID {
            case "daily-steps-bar":
                payload = try PlotlyEncoder.dailyStepsBar(from: db, deviceID: deviceID)
            case "resting-hr-trendline":
                payload = try PlotlyEncoder.restingHRTrendline(from: db, deviceID: deviceID)
            case "recent-activities-timeline":
                payload = try PlotlyEncoder.recentActivitiesTimeline(from: db, deviceID: deviceID)
            case "weekly-distance-bar":
                payload = try PlotlyEncoder.weeklyDistanceBar(from: db, deviceID: deviceID)
            case "stress-body-battery-ts":
                payload = try PlotlyEncoder.stressBodyBatteryTS(from: db, deviceID: deviceID)
            case "daily-intensity-minutes-bar":
                payload = try PlotlyEncoder.dailyIntensityMinutesBar(from: db, deviceID: deviceID)
            case "steps-hourly-heatmap":
                payload = try PlotlyEncoder.hourlyHRHeatmap(from: db, deviceID: deviceID)
            case "hrv-daily-trend":
                payload = try PlotlyEncoder.hrvDailyTrend(from: db, deviceID: deviceID)
            case "hr-range-band":
                payload = try PlotlyEncoder.hrRangeBand(from: db, deviceID: deviceID)
            case "daily-steps-distance-combo":
                payload = try PlotlyEncoder.dailyStepsDistanceCombo(from: db, deviceID: deviceID)
            case "respiration-spo2-ts":
                payload = try PlotlyEncoder.respirationSpo2TS(from: db, deviceID: deviceID)
            case "sleep-score-trend":
                payload = try PlotlyEncoder.sleepScoreTrend(from: db, deviceID: deviceID)
            case "sleep-duration-bar":
                payload = try PlotlyEncoder.sleepDurationBar(from: db, deviceID: deviceID)
            case "sleep-stage-stacked":
                payload = try PlotlyEncoder.sleepStageStacked(from: db, deviceID: deviceID)
            case "sleep-bed-wake-scatter":
                payload = try PlotlyEncoder.sleepBedWakeScatter(from: db, deviceID: deviceID)
            case "sleep-regularity-heatmap":
                payload = try PlotlyEncoder.sleepRegularityHeatmap(from: db, deviceID: deviceID)
            default:
                print("MainWindowController: no rerender path for \(chartID)")
                return
            }
            webChartView.render(payload)
        } catch {
            print("MainWindowController: rerender \(chartID) failed: \(error)")
        }
    }
}

// MARK: - Welcome view (shown when DB is missing or has no devices)

final class WelcomeView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 32, weight: .light)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        bodyLabel.font = NSFont.systemFont(ofSize: 14)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.preferredMaxLayoutWidth = 600

        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.alignment = .left
        pathLabel.maximumNumberOfLines = 0
        pathLabel.preferredMaxLayoutWidth = 600

        let stack = NSStackView(views: [titleLabel, bodyLabel, pathLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80),
        ])
    }

    func update(databasePath: URL, error: Error?) {
        let envRaw = ProcessInfo.processInfo.environment["GARMIN_DISCONNECT_DB"] ?? "(unset)"
        let cwd = FileManager.default.currentDirectoryPath
        if let error = error {
            titleLabel.stringValue = "Can't read your archive"
            bodyLabel.stringValue = """
                GarminDisconnect couldn't open the garmin-dump archive. Make sure
                garmin-dump is installed and you've run a successful pull at least
                once.

                \(error)
                """
        } else {
            titleLabel.stringValue = "No data yet"
            bodyLabel.stringValue = """
                Plug your Garmin watch in over USB, install garmin-dump, and run
                `garmin-dump pull`. Then come back here and click Sync.
                """
        }
        pathLabel.stringValue = """
            resolved: \(databasePath.path)
            GARMIN_DISCONNECT_DB: \(envRaw)
            cwd: \(cwd)
            """
    }
}

// MARK: - Tab id mapping

extension Tab {
    /// String id used by JS `showTab()`. Matches the part after `tab-` in
    /// the section element's id (e.g. `overview`, `activities`).
    var id: String {
        switch self {
        case .overview:   return "overview"
        case .activities: return "activities"
        case .wellness:   return "wellness"
        case .sleep:      return "sleep"
        case .sync:       return "sync"
        }
    }
}
