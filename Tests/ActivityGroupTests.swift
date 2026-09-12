// ActivityGroupTests.swift
//
// Covers multi-activity selection (feature #252): stitching several watch
// activities into one ActivityGroup, and the five activity-detail payloads
// PlotlyEncoder builds from it.
//
// The load-bearing property here is that a group of ONE is identical to what
// the viewer did before groups existed — there is only one code path, so if
// the single case drifts, every activity detail view drifts with it. Several
// tests below assert that directly.
//
// Fixture facts these tests rely on (see Tests/build_fixture.py):
//   - activity "running": 30 records at 1 Hz, elapsed 0…29, distance 0…87 m
//   - activity "walking": 30 records at 1 Hz, elapsed 0…29, distance 0…58 m,
//     starting exactly 86400 s (24 h) after the run, continuing its route
//   - activity "swimming": no records at all

import Foundation

// MARK: - Test runner (file-local; mirrors DatabaseTests.swift)

private var passed = 0
private var failed = 0

private func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("  ok    \(name)")
    } catch {
        failed += 1
        print("  FAIL  \(name): \(error)")
    }
}

private struct AssertError: Error, CustomStringConvertible {
    let msg: String
    var description: String { msg }
}

private func expect(_ cond: Bool, _ msg: @autoclosure () -> String = "") throws {
    if !cond {
        let m = msg()
        throw AssertError(msg: m.isEmpty ? "expectation failed" : m)
    }
}

private func expectEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, _ msg: @autoclosure () -> String = ""
) throws {
    if lhs != rhs {
        throw AssertError(msg: "\(lhs) != \(rhs)\(msg().isEmpty ? "" : " — \(msg())")")
    }
}

private func expectClose(
    _ lhs: Double, _ rhs: Double, _ tol: Double = 0.001,
    _ msg: @autoclosure () -> String = ""
) throws {
    if abs(lhs - rhs) > tol {
        throw AssertError(msg: "\(lhs) !≈ \(rhs)\(msg().isEmpty ? "" : " — \(msg())")")
    }
}

// MARK: - Fixture

private let fixturePath: URL = {
    let cwd = FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: cwd)
        .appendingPathComponent("Tests/fixtures/tiny.db")
}()

private func openFixture() throws -> Database {
    return try Database(path: fixturePath)
}

private func activityID(_ db: Database, sport: String) throws -> Int {
    guard let id = try db.queryOne(
        "SELECT activity_id FROM activities WHERE sport = ?", bind: [.text(sport)]
    )?.int("activity_id") else {
        throw AssertError(msg: "no \(sport) activity in the fixture")
    }
    return id
}

/// The "data" array out of a Plotly payload.
private func traces(_ payload: [String: Any]) throws -> [[String: Any]] {
    guard let data = payload["data"] as? [[String: Any]] else {
        throw AssertError(msg: "payload has no data array: \(payload["chart"] ?? "?")")
    }
    return data
}

/// Look up a summary-card row by its label.
private func summaryValue(_ payload: [String: Any], label: String) throws -> String {
    guard let rows = payload["rows"] as? [[String: Any]] else {
        throw AssertError(msg: "summary card has no rows")
    }
    for row in rows where (row["label"] as? String) == label {
        return (row["value"] as? String) ?? ""
    }
    throw AssertError(msg: "no summary row labelled \(label)")
}

private func hasSummaryRow(_ payload: [String: Any], label: String) -> Bool {
    guard let rows = payload["rows"] as? [[String: Any]] else { return false }
    return rows.contains { ($0["label"] as? String) == label }
}

// MARK: - Grouping

private func testSingleActivityGroupIsUnchanged() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let group = try ActivityGroup.load(db: db, activityIDs: [run])

    try expectEqual(group.members.count, 1)
    try expect(!group.isMulti, "one activity is not a multi-group")
    try expectEqual(group.records.count, 30)
    try expectEqual(group.members[0].elapsedOffsetS, 0, "anchor member is never offset")
    try expectClose(group.members[0].distanceOffsetM, 0)
    // Every record keeps its own coordinates untouched.
    for rec in group.records {
        try expectEqual(rec.elapsedS, rec.memberElapsedS)
        try expectEqual(rec.memberIndex, 0)
    }
    try expectEqual(group.records.first!.elapsedS, 0)
    try expectEqual(group.records.last!.elapsedS, 29)
    try expectClose(group.records.last!.distanceM ?? -1, 87)
}

private func testGroupOrdersMembersChronologically() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")
    // Clicked newest-first, as the sidebar lists them.
    let group = try ActivityGroup.load(db: db, activityIDs: [walk, run])
    try expectEqual(group.activityIDs, [run, walk],
                    "the group orders by time, not by click order")
}

private func testGroupRebasesElapsedAndDistance() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")
    let group = try ActivityGroup.load(db: db, activityIDs: [run, walk])

    try expect(group.isMulti, "two activities make a multi-group")
    try expectEqual(group.records.count, 60)
    // The walk starts a day after the run; that day is real elapsed time and
    // shows up as a hole in the group clock.
    try expectEqual(group.members[1].elapsedOffsetS, 86400)
    // ...and its route continues from where the run's ended (87 m in).
    try expectClose(group.members[1].distanceOffsetM, 87)

    let firstWalkRecord = group.records[30]
    try expectEqual(firstWalkRecord.activityID, walk)
    try expectEqual(firstWalkRecord.memberElapsedS, 0, "the member's own clock is preserved")
    try expectEqual(firstWalkRecord.elapsedS, 86400)
    try expectClose(firstWalkRecord.distanceM ?? -1, 87)
    try expectClose(group.records.last!.distanceM ?? -1, 87 + 58)

    // The group clock only ever moves forward.
    for i in 1..<group.records.count {
        try expect(group.records[i].elapsedS >= group.records[i - 1].elapsedS,
                   "group elapsed went backwards at \(i)")
    }
}

private func testGroupAppliesTrimPerMember() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")
    // Keep only run seconds 10…19; the walk is untouched.
    let trims = [run: TrimState(ranges: [TrimRange(startElapsedS: 10, endElapsedS: 19)])]
    let group = try ActivityGroup.load(db: db, activityIDs: [run, walk], trims: trims)

    try expectEqual(group.records.count, 40, "10 kept from the run + all 30 of the walk")
    try expectEqual(group.records.first!.memberElapsedS, 10)
    try expect(group.hasTrim, "a trimmed member makes the group trimmed")
    try expect(!group.trimIsAuto, "this trim was manual")
    // The walk now chains onto the run's *kept* tail (19 s × 3 m/s = 57 m),
    // not onto the distance the trimmed-away records covered.
    try expectClose(group.members[1].distanceOffsetM, 57)
    // The untrimmed view still holds everything — the trim timeline needs it.
    try expectEqual(group.allRecords.count, 60)
}

private func testGroupSkipsActivityWithNoRecords() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let swim = try activityID(db, sport: "swimming")  // no records in the fixture
    let group = try ActivityGroup.load(db: db, activityIDs: [run, swim])
    // The member is still there (it's a real activity the user selected, and
    // the summary card counts it), it just contributes no records.
    try expectEqual(group.members.count, 2)
    try expectEqual(group.records.count, 30)
}

private func testGroupCollapsesDuplicateIDs() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let group = try ActivityGroup.load(db: db, activityIDs: [run, run, run])
    try expectEqual(group.members.count, 1)
    try expectEqual(group.records.count, 30)
}

// MARK: - Detail payloads

private func testSummaryCardAggregatesTheGroup() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")

    let single = try PlotlyEncoder.activitySummaryCard(
        from: db, group: try ActivityGroup.load(db: db, activityIDs: [run])
    )
    try expectEqual(single["title"] as? String ?? "", "Running · Generic")
    try expectEqual(try summaryValue(single, label: "Distance"), "5.23 km")
    try expect(!hasSummaryRow(single, label: "Activities"),
               "a single activity doesn't need an Activities count")

    let group = try PlotlyEncoder.activitySummaryCard(
        from: db, group: try ActivityGroup.load(db: db, activityIDs: [run, walk])
    )
    try expectEqual(group["title"] as? String ?? "", "Running + Walking")
    // 5230 m + 1100 m
    try expectEqual(try summaryValue(group, label: "Distance"), "6.33 km")
    // 1820 s + 720 s = 2540 s
    try expectEqual(try summaryValue(group, label: "Duration"), "42m 20s")
    try expectEqual(try summaryValue(group, label: "Activities"), "2")
    // Both members are 145 bpm in the fixture, so any weighting gives 145.
    try expectEqual(try summaryValue(group, label: "Avg HR"), "145 bpm")
    try expect((group["subtitle"] as? String ?? "").contains("2 activities"),
               "the subtitle should say how many activities are combined")
}

private func testSummaryCardWeightsAveragesByDuration() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")   // 1820 s
    let walk = try activityID(db, sport: "walking")  // 720 s
    // Both fixture activities carry avg_hr 145, so a plain mean and a weighted
    // mean agree — which would let a regression through. Pace is the
    // discriminator: it's computed from the summed distance and time, so it
    // can't be the mean of the two per-activity paces.
    let group = try PlotlyEncoder.activitySummaryCard(
        from: db, group: try ActivityGroup.load(db: db, activityIDs: [run, walk])
    )
    // 2540 s / 6.33 km = 6.685 min/km → 6:41
    try expectEqual(try summaryValue(group, label: "Avg pace"), "6:41 /km")
}

private func testPaceAltitudeBreaksAtMemberBoundary() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")

    let single = PlotlyEncoder.activityPaceAltitude(
        group: try ActivityGroup.load(db: db, activityIDs: [run])
    )
    let singleX = try traces(single)[0]["x"] as? [Any] ?? []
    try expectEqual(singleX.count, 30)
    try expect((single["layout"] as? [String: Any])?["shapes"] == nil,
               "a single activity has no handover rules")

    let group = PlotlyEncoder.activityPaceAltitude(
        group: try ActivityGroup.load(db: db, activityIDs: [run, walk])
    )
    for trace in try traces(group) {
        let xs = trace["x"] as? [Any] ?? []
        let ys = trace["y"] as? [Any] ?? []
        try expectEqual(xs.count, 61, "30 + null + 30")
        try expectEqual(ys.count, 61, "y must line up with x")
        try expect(xs[30] is NSNull, "the boundary sample must be null in x")
        try expect(ys[30] is NSNull, "the boundary sample must be null in y")
    }
    let shapes = (group["layout"] as? [String: Any])?["shapes"] as? [[String: Any]] ?? []
    try expectEqual(shapes.count, 1, "one dotted rule per handover")
    try expectClose(shapes[0]["x0"] as? Double ?? -1, 0.087, 0.0001)
}

private func testHRZonesSumsAcrossMembers() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")

    func minutes(_ ids: [Int]) throws -> [Double] {
        let payload = PlotlyEncoder.activityHRZones(
            group: try ActivityGroup.load(db: db, activityIDs: ids)
        )
        return try traces(payload)[0]["y"] as? [Double] ?? []
    }
    let runZones = try minutes([run])
    let walkZones = try minutes([walk])
    let groupZones = try minutes([run, walk])

    try expectEqual(groupZones.count, 5)
    for i in 0..<5 {
        try expectClose(groupZones[i], runZones[i] + walkZones[i], 0.0001,
                        "zone \(i + 1) should be the sum of its members")
    }
    // The day between the two activities must not be counted as time in a
    // zone — the total is minutes of recording, not minutes of wall clock.
    let total = groupZones.reduce(0, +)
    try expect(total < 2.0, "group zone total \(total) min should be ~1, not a day")
}

private func testGPSMapMarksEveryMemberStartAndEnd() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")

    // The last two traces are always [start, end] — see activityGPSMap.
    func startEndCounts(_ ids: [Int]) throws -> (start: Int, end: Int) {
        let payload = PlotlyEncoder.activityGPSMap(
            group: try ActivityGroup.load(db: db, activityIDs: ids)
        )
        let data = try traces(payload)
        let start = data[data.count - 2]["lat"] as? [Double] ?? []
        let end = data[data.count - 1]["lat"] as? [Double] ?? []
        return (start.count, end.count)
    }
    let single = try startEndCounts([run])
    try expectEqual(single.start, 1)
    try expectEqual(single.end, 1)

    let group = try startEndCounts([run, walk])
    try expectEqual(group.start, 2, "one start icon per member, as the item asks")
    try expectEqual(group.end, 2, "one stop icon per member")
}

private func testGPSMapBreaksTheTrailBetweenMembers() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")
    let payload = PlotlyEncoder.activityGPSMap(
        group: try ActivityGroup.load(db: db, activityIDs: [run, walk])
    )
    let data = try traces(payload)
    // Trace 0 is the outline, trace 1 the plain trail. Both carry the null.
    for idx in 0...1 {
        let lats = data[idx]["lat"] as? [Any] ?? []
        try expectEqual(lats.count, 61, "30 + null + 30")
        try expect(lats[30] is NSNull, "trace \(idx) must break at the handover")
    }
    // Neither is the handover a "pause": the fixture's two activities are 1 Hz
    // throughout, so the only >10 s gap is the day between them, and it must
    // NOT produce a T badge.
    let pauseTrace = data[data.count - 3]
    try expectEqual((pauseTrace["lat"] as? [Double] ?? []).count, 0,
                    "the gap between two activities is a handover, not a pause")
}

private func testTrimControlsAreSingleActivityOnly() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")

    let single = PlotlyEncoder.activityTrimControls(
        group: try ActivityGroup.load(db: db, activityIDs: [run])
    )
    try expectEqual(single["activity_id"] as? Int ?? -1, run)
    try expectEqual(single["first_elapsed_s"] as? Int ?? -1, 0)
    try expectEqual(single["total_elapsed_s"] as? Int ?? -1, 29)
    try expectEqual((single["segments"] as? [[String: Any]] ?? []).count, 1)

    // Multi-selection drops the control entirely rather than leaving a
    // card-sized box explaining itself: `chart_hidden` tells the JS to hide
    // the slot, so the page goes straight from the map to Metrics (#261).
    let group = PlotlyEncoder.activityTrimControls(
        group: try ActivityGroup.load(db: db, activityIDs: [run, walk])
    )
    try expectEqual(group["chart_hidden"] as? Bool ?? false, true)
    try expect(group["chart_empty"] == nil, "hidden is not the same as empty")
    try expect(group["message"] == nil, "a hidden slot must carry no help text")

    // An empty selection hides it the same way.
    let none = PlotlyEncoder.activityTrimControls(
        group: try ActivityGroup.load(db: db, activityIDs: [])
    )
    try expectEqual(none["chart_hidden"] as? Bool ?? false, true)
    try expect(none["message"] == nil, "a hidden slot must carry no help text")
}

private func testTrimControlsUseTheMemberClockNotTheGroupClock() throws {
    let db = try openFixture()
    let walk = try activityID(db, sport: "walking")
    // On its own the walk is the anchor, so this would pass trivially. Select
    // it second and it carries an 86400 s group offset — the timeline must
    // still speak in the activity's own seconds, because that's what saved
    // trims are expressed in.
    let group = try ActivityGroup.load(
        db: db, activityIDs: [try activityID(db, sport: "running"), walk]
    )
    let solo = try ActivityGroup.load(db: db, activityIDs: [walk])
    let payload = PlotlyEncoder.activityTrimControls(group: solo)
    try expectEqual(payload["total_elapsed_s"] as? Int ?? -1, 29)
    // ...and the group's second member really is offset, so the check above
    // isn't vacuous.
    try expectEqual(group.members[1].elapsedOffsetS, 86400)
}

private func testActivityListPayloadCarriesEverySelectedID() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let walk = try activityID(db, sport: "walking")
    guard let deviceID = try db.queryOne(
        "SELECT device_id FROM activities WHERE activity_id = ?", bind: [.int(Int64(run))]
    )?.int("device_id") else {
        throw AssertError(msg: "no device for the run")
    }
    let payload = try PlotlyEncoder.activityListPayload(
        from: db, deviceID: deviceID, selectedActivityIDs: [run, walk]
    )
    try expectEqual(payload["selected_activity_ids"] as? [Int] ?? [], [run, walk])
}

/// The three always-on badge traces (pause / start / stop) must ask for the
/// canvas-painted MapLibre icons installed by charts.js, not for a bare
/// coloured dot. See `gpdInstallMarkerIcons` there: Plotly turns
/// `marker.symbol` into an `icon-image` of "<symbol>-15", and `marker.size`
/// into `icon-size: size / 10` — so size 10 means "draw the icon at the
/// natural size charts.js painted it".
private func testGPSMapBadgesUseThePaintedIcons() throws {
    let db = try openFixture()
    let run = try activityID(db, sport: "running")
    let payload = PlotlyEncoder.activityGPSMap(
        group: try ActivityGroup.load(db: db, activityIDs: [run])
    )
    let data = try traces(payload)
    // Trailing trace order is [pause, start, end] — see activityGPSMap.
    let expected = [
        (offset: 3, symbol: "gpd-pause"),
        (offset: 2, symbol: "gpd-start"),
        (offset: 1, symbol: "gpd-stop"),
    ]
    for (offset, symbol) in expected {
        let trace = data[data.count - offset]
        let marker = trace["marker"] as? [String: Any] ?? [:]
        try expectEqual(marker["symbol"] as? String ?? "", symbol)
        try expectEqual(marker["size"] as? Int ?? 0, 10,
                        "\(symbol) must render its icon at natural size")
        // 60% opacity so the badge never hides the map underneath it.
        try expect((marker["opacity"] as? Double ?? 0) == 0.6,
                   "\(symbol) should be drawn at 60% opacity")
        // MapLibre hides colliding symbols unless told not to, and in a
        // multi-leg group a stop badge often lands metres from the next
        // start badge.
        try expect(marker["allowoverlap"] as? Bool == true,
                   "\(symbol) must survive colliding with a neighbouring badge")
        try expect(trace["mode"] as? String == "markers",
                   "\(symbol) is an icon, not a text label")
        try expect(trace["text"] == nil,
                   "\(symbol) must not carry MapLibre text — the style has no glyph source")
    }
}

// MARK: - Entry point (called by TestsMain)

func runActivityGroupTests() -> (passed: Int, failed: Int) {
    passed = 0
    failed = 0
    test("single-activity group is unchanged",     testSingleActivityGroupIsUnchanged)
    test("group orders members chronologically",   testGroupOrdersMembersChronologically)
    test("group rebases elapsed and distance",     testGroupRebasesElapsedAndDistance)
    test("group applies trim per member",          testGroupAppliesTrimPerMember)
    test("group keeps a record-less member",       testGroupSkipsActivityWithNoRecords)
    test("group collapses duplicate ids",          testGroupCollapsesDuplicateIDs)
    test("summary card aggregates the group",      testSummaryCardAggregatesTheGroup)
    test("summary card weights by duration",       testSummaryCardWeightsAveragesByDuration)
    test("pace/altitude breaks at boundary",       testPaceAltitudeBreaksAtMemberBoundary)
    test("hr zones sum across members",            testHRZonesSumsAcrossMembers)
    test("gps map marks every start and end",      testGPSMapMarksEveryMemberStartAndEnd)
    test("gps map breaks the trail between legs",  testGPSMapBreaksTheTrailBetweenMembers)
    test("gps map badges use the painted icons",   testGPSMapBadgesUseThePaintedIcons)
    test("trim controls are single-activity only", testTrimControlsAreSingleActivityOnly)
    test("trim controls use the member clock",     testTrimControlsUseTheMemberClockNotTheGroupClock)
    test("activity list carries every selection",  testActivityListPayloadCarriesEverySelectedID)
    return (passed, failed)
}
