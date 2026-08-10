import XCTest
@testable import UsageCore

/// Per-model windows, the burn rate, and the one thing that must never regress:
/// a file written by an older build still decoding.
final class PerModelPayloadTests: XCTestCase {

    private func parse(_ json: String) -> UsageData? {
        UsageAPI.parse(Data(json.utf8))
    }

    func testParsesPerModelWindows() throws {
        let data = try XCTUnwrap(parse("""
        {"five_hour":{"utilization":42,"resets_at":"2026-08-04T18:00:00Z"},
         "seven_day":{"utilization":18,"resets_at":"2026-08-09T00:00:00Z"},
         "seven_day_opus":{"utilization":61,"resets_at":"2026-08-09T00:00:00Z"},
         "seven_day_sonnet":{"utilization":12,"resets_at":null},
         "extra_usage":{"utilization":5}}
        """))
        XCTAssertEqual(data.sevenDayOpus?.utilization, 61)
        XCTAssertNotNil(data.sevenDayOpus?.resetsAt)
        XCTAssertEqual(data.sevenDaySonnet?.utilization, 12)
        XCTAssertNil(data.sevenDaySonnet?.resetsAt)
        XCTAssertEqual(data.extraUsage?.utilization, 5)
    }

    /// Most plans report these as null, and that has to stay indistinguishable
    /// from "not there" — both mean "this account has no separate Opus limit".
    func testNullPerModelWindowsAreSimplyAbsent() throws {
        let data = try XCTUnwrap(parse("""
        {"five_hour":{"utilization":42},"seven_day":{"utilization":18},
         "seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":null}
        """))
        XCTAssertNil(data.sevenDayOpus)
        XCTAssertNil(data.sevenDaySonnet)
        XCTAssertNil(data.extraUsage)
    }

    /// A body carrying only per-model windows says nothing about the account, so
    /// it is still not usable data.
    func testPerModelWindowsAloneAreNotEnough() {
        XCTAssertNil(parse(#"{"seven_day_opus":{"utilization":61}}"#))
    }

    func testSnapshotCarriesPerModelWindows() {
        let snapshot = Snapshot(usage: UsageData(
            fiveHour: UsageNode(utilization: 42, resetsAt: nil),
            sevenDay: UsageNode(utilization: 18, resetsAt: nil),
            sevenDayOpus: UsageNode(utilization: 61, resetsAt: nil),
            extraUsage: UsageNode(utilization: 5, resetsAt: nil)))
        XCTAssertEqual(snapshot.opusPct, 61)
        XCTAssertNil(snapshot.sonnetPct)
        XCTAssertEqual(snapshot.extraUsagePct, 5)
    }
}

/// The regression that blanks every placed widget: a snapshot file written before
/// a field existed must still decode. Synthesized decoding does not fall back to
/// a property's default, so this is not automatic and is worth pinning.
final class AdditiveDecodeTests: XCTestCase {

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Exactly what 0.4.0 wrote — no models, no per-model windows, no burn rate.
    private let legacySnapshot = """
    {"updatedAt":"2026-08-10T12:00:00Z","sessionPct":42,"weeklyPct":18,
     "stats":{"todayTokens":10,"todayCost":1,"weekTokens":20,"weekCost":2,
              "sessionTokens":5,"sessionCost":0.5,"projects":[],"days":[],"ok":true},
     "stale":false,"warn":50,"critical":80}
    """

    func testSnapshotWrittenBeforeTheseFieldsExistedStillDecodes() throws {
        let snapshot = try decoder.decode(Snapshot.self, from: Data(legacySnapshot.utf8))
        XCTAssertEqual(snapshot.sessionPct, 42)
        XCTAssertEqual(snapshot.stats.todayTokens, 10)
        XCTAssertNil(snapshot.opusPct)
        XCTAssertNil(snapshot.burnRatePerHour)
        XCTAssertTrue(snapshot.stats.models.isEmpty)
    }

    func testBundleWrittenBeforeRefreshSecondsExistedStillDecodes() throws {
        let json = """
        {"updatedAt":"2026-08-10T12:00:00Z","profileList":[],
         "profiles":{"/home/me/.claude":\(legacySnapshot)}}
        """
        let bundle = try decoder.decode(SnapshotBundle.self, from: Data(json.utf8))
        XCTAssertNil(bundle.refreshSeconds)
        XCTAssertEqual(bundle.profiles.count, 1)
    }

    /// `LogStats` decodes by hand precisely so a key added tomorrow doesn't break
    /// a file written today. A stats object missing nearly everything is still a
    /// valid stats object.
    func testStatsToleratesMissingKeysEntirely() throws {
        let stats = try decoder.decode(LogStats.self, from: Data("{}".utf8))
        XCTAssertEqual(stats.todayTokens, 0)
        XCTAssertTrue(stats.projects.isEmpty)
        XCTAssertTrue(stats.models.isEmpty)
        // Defaults to readable — "no key" must not read as "directory missing".
        XCTAssertTrue(stats.ok)
    }

    func testRoundTripKeepsTheNewFields() throws {
        var original = Snapshot(usage: UsageData(
            fiveHour: UsageNode(utilization: 42, resetsAt: nil),
            sevenDay: UsageNode(utilization: 18, resetsAt: nil),
            sevenDayOpus: UsageNode(utilization: 61, resetsAt: nil)))
        original.burnRatePerHour = 12
        original.stats.models = [ModelUsage(name: "Opus", tokens: 5, cost: 1)]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restored = try decoder.decode(Snapshot.self, from: encoder.encode(original))
        XCTAssertEqual(restored, original)
    }
}

final class BurnRateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func monitor() -> ProfileMonitor {
        ProfileMonitor(profile: Profile(
            configDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("burn-\(UUID().uuidString)"),
            isDefault: false))
    }

    func testNeedsTwoSamplesFarEnoughApart() async {
        let m = monitor()
        XCTAssertNil(await m.burnRate(for: 10, now: now))
        // A minute apart is inside the two-minute floor.
        XCTAssertNil(await m.burnRate(for: 20, now: now.addingTimeInterval(60)))
    }

    func testMeasuresPointsPerHour() async {
        let m = monitor()
        _ = await m.burnRate(for: 10, now: now)
        // Ten points in six minutes is a hundred an hour.
        let rate = await m.burnRate(for: 20, now: now.addingTimeInterval(360))
        XCTAssertEqual(rate, 100)
    }

    /// A window resetting drops the percentage. That is not usage falling, and
    /// projecting a negative rate from it would be nonsense.
    func testWindowResetYieldsNoRate() async {
        let m = monitor()
        _ = await m.burnRate(for: 90, now: now)
        let rate = await m.burnRate(for: 3, now: now.addingTimeInterval(300))
        XCTAssertNil(rate)
    }

    func testIdleAccountHasNoRate() async {
        let m = monitor()
        _ = await m.burnRate(for: 42, now: now)
        XCTAssertNil(await m.burnRate(for: 42, now: now.addingTimeInterval(600)))
    }

    /// The tail after a burst is the case that matters for the widget reload
    /// budget: once usage stops moving the rate must go quiet immediately, not
    /// decay through a different number every poll for half an hour.
    func testRateStopsTheMomentUsageStops() async {
        let m = monitor()
        _ = await m.burnRate(for: 10, now: now)
        XCTAssertNotNil(await m.burnRate(for: 40, now: now.addingTimeInterval(300)))
        // Same reading a minute later — still well inside the 30-minute window,
        // and the slope against the oldest sample is still steeply positive.
        XCTAssertNil(await m.burnRate(for: 40, now: now.addingTimeInterval(360)))
        XCTAssertNil(await m.burnRate(for: 40, now: now.addingTimeInterval(420)))
    }

    /// Under a point an hour rounds to zero, so there is nothing to say.
    func testTooSlowToMatterYieldsNoRate() async {
        let m = monitor()
        _ = await m.burnRate(for: 10, now: now)
        XCTAssertNil(await m.burnRate(for: 10.4, now: now.addingTimeInterval(1800)))
    }

    func testNoUtilizationAtAllYieldsNoRate() async {
        XCTAssertNil(await monitor().burnRate(for: nil, now: now))
    }
}

final class TimeToFullTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func snapshot(pct: Double, rate: Double?, resetsIn: TimeInterval?) -> Snapshot {
        var s = Snapshot(usage: UsageData(
            fiveHour: UsageNode(utilization: pct,
                                resetsAt: resetsIn.map { now.addingTimeInterval($0) }),
            sevenDay: nil))
        s.burnRatePerHour = rate
        return s
    }

    func testProjectsFromTheRate() throws {
        // Sixty points to go at twenty an hour is three hours, and the window
        // does not reset for four.
        let s = snapshot(pct: 40, rate: 20, resetsIn: 4 * 3600)
        XCTAssertEqual(try XCTUnwrap(s.timeToFull(now: now)), 3 * 3600, accuracy: 1)
    }

    /// The common case by a wide margin: the window empties before it fills, so
    /// there is nothing to warn about.
    func testResetBeforeFullIsNoProjection() {
        XCTAssertNil(snapshot(pct: 40, rate: 20, resetsIn: 3600).timeToFull(now: now))
    }

    func testNoRateAndAlreadyFullBothYieldNothing() {
        XCTAssertNil(snapshot(pct: 40, rate: nil, resetsIn: 4 * 3600).timeToFull(now: now))
        XCTAssertNil(snapshot(pct: 100, rate: 20, resetsIn: 4 * 3600).timeToFull(now: now))
    }

    /// No reset time at all still projects — an unknown reset is not a reason to
    /// withhold the only number we do have.
    func testMissingResetStillProjects() {
        XCTAssertNotNil(snapshot(pct: 40, rate: 20, resetsIn: nil).timeToFull(now: now))
    }
}

final class MonthToDateTests: XCTestCase {

    func testSumsOnlyThisMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10)))

        func day(_ month: Int, _ day: Int, cost: Double) throws -> DayUsage {
            DayUsage(day: try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day))), tokens: 0, cost: cost)
        }

        var snapshot = Snapshot()
        snapshot.stats.days = [
            try day(7, 30, cost: 100),   // last month, excluded
            try day(8, 1, cost: 1),
            try day(8, 10, cost: 2),
        ]
        XCTAssertEqual(snapshot.monthToDateCost(now: now, calendar: calendar), 3, accuracy: 1e-9)
    }
}
