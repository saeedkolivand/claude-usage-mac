import XCTest
@testable import UsageCore

final class HexColorTests: XCTestCase {

    func testParsesSixDigitHex() throws {
        let rgb = try XCTUnwrap(HexColor.rgb("#22c55e"))
        XCTAssertEqual(rgb.red, Double(0x22) / 255, accuracy: 1e-9)
        XCTAssertEqual(rgb.green, Double(0xc5) / 255, accuracy: 1e-9)
        XCTAssertEqual(rgb.blue, Double(0x5e) / 255, accuracy: 1e-9)
    }

    func testHashIsOptionalAndShorthandExpands() throws {
        XCTAssertNotNil(HexColor.rgb("22c55e"))
        let short = try XCTUnwrap(HexColor.rgb("#f0a"))
        XCTAssertEqual(short.red, 1, accuracy: 1e-9)
        XCTAssertEqual(short.green, 0, accuracy: 1e-9)
        XCTAssertEqual(short.blue, Double(0xaa) / 255, accuracy: 1e-9)
    }

    func testGarbageIsNil() {
        // "+2c55e" would sail through UInt32(_:radix:), which accepts a sign.
        for bad in ["", "#", "red", "#22c5", "#22c55g", "+2c55e", "#22c55e00"] {
            XCTAssertNil(HexColor.rgb(bad), bad)
        }
    }
}

final class AutoSwitchTests: XCTestCase {

    // MARK: - Fixtures

    private func profile(_ path: String, email: String?, org: String?) -> Profile {
        Profile(configDir: URL(fileURLWithPath: path), isDefault: path == "/a",
                email: email, organization: org)
    }

    private func snapshot(session: Double?, error: String? = nil) -> Snapshot {
        var s = Snapshot(usage: session.map {
            UsageData(fiveHour: UsageNode(utilization: $0, resetsAt: nil), sevenDay: nil)
        })
        s.error = error
        return s
    }

    private func bundle(_ entries: [(Profile, Snapshot)]) -> SnapshotBundle {
        SnapshotBundle(
            profiles: Dictionary(uniqueKeysWithValues: entries.map { ($0.0.id, $0.1) }),
            profileList: entries.map(\.0))
    }

    /// Two accounts: /a (selected) and /b, plus whatever the test adds.
    private func twoAccounts(a: Double?, b: Double?) -> SnapshotBundle {
        bundle([
            (profile("/a", email: "a@x.com", org: "A"), snapshot(session: a)),
            (profile("/b", email: "b@x.com", org: "B"), snapshot(session: b)),
        ])
    }

    private func shown(_ bundle: SnapshotBundle, current: String? = nil) -> String? {
        AutoSwitch.shownProfile(in: bundle, selectedID: "/a", current: current,
                                warn: 50, critical: 80)
    }

    // MARK: - Switching out

    func testBelowCriticalStaysPut() {
        XCTAssertNil(shown(twoAccounts(a: 79, b: 5)))
    }

    func testAtCriticalSwitchesToTheMostHeadroom() {
        let bundle = self.bundle([
            (profile("/a", email: "a@x.com", org: "A"), snapshot(session: 95)),
            (profile("/b", email: "b@x.com", org: "B"), snapshot(session: 40)),
            (profile("/c", email: "c@x.com", org: "C"), snapshot(session: 10)),
        ])
        XCTAssertEqual(shown(bundle), "/c")
    }

    func testSameAccountIsNotHeadroom() {
        // /b is the same account as /a — same email and organization — so its
        // "free" window is the same full window under another name.
        let bundle = self.bundle([
            (profile("/a", email: "a@x.com", org: "A"), snapshot(session: 95)),
            (profile("/b", email: "a@x.com", org: "A"), snapshot(session: 10)),
        ])
        XCTAssertNil(shown(bundle))
    }

    func testErroredAndEmptyCandidatesAreSkipped() {
        let bundle = self.bundle([
            (profile("/a", email: "a@x.com", org: "A"), snapshot(session: 95)),
            (profile("/b", email: "b@x.com", org: "B"), snapshot(session: 5, error: "token-expired")),
            (profile("/c", email: "c@x.com", org: "C"), snapshot(session: nil)),
        ])
        XCTAssertNil(shown(bundle))
    }

    func testACandidateNoBetterOffIsNotASwitch() {
        XCTAssertNil(shown(twoAccounts(a: 90, b: 96)))
    }

    func testNoReadingForTheSelectionMeansNoSwitch() {
        XCTAssertNil(shown(twoAccounts(a: nil, b: 5)))
    }

    // MARK: - The latch

    func testStaysLatchedWhileTheWindowIsStillUp() {
        // Fallen out of critical but not yet below warn: no flapping home.
        XCTAssertEqual(shown(twoAccounts(a: 65, b: 5), current: "/b"), "/b")
    }

    func testLatchIgnoresABetterCandidateAppearing() {
        let bundle = self.bundle([
            (profile("/a", email: "a@x.com", org: "A"), snapshot(session: 95)),
            (profile("/b", email: "b@x.com", org: "B"), snapshot(session: 40)),
            (profile("/c", email: "c@x.com", org: "C"), snapshot(session: 10)),
        ])
        XCTAssertEqual(shown(bundle, current: "/b"), "/b")
    }

    func testReturnsHomeWhenTheWindowResets() {
        XCTAssertNil(shown(twoAccounts(a: 3, b: 60), current: "/b"))
    }

    func testReturnsHomeWhenTheLatchedProfileVanishes() {
        XCTAssertNil(shown(twoAccounts(a: 95, b: 40), current: "/gone"))
    }
}

final class StatuslineTextTests: XCTestCase {

    func testFormatsBothWindowsAndTheReset() {
        let s = Snapshot(usage: UsageData(
            fiveHour: UsageNode(utilization: 34.4,
                                resetsAt: Date().addingTimeInterval(2 * 3600 + 10 * 60 + 30)),
            sevenDay: UsageNode(utilization: 70, resetsAt: nil)))
        XCTAssertEqual(s.statuslineText, "5h 34% | wk 70% | resets 2h 10m")
    }

    func testNoResetDateDropsThatPart() {
        let s = Snapshot(usage: UsageData(
            fiveHour: UsageNode(utilization: 34, resetsAt: nil),
            sevenDay: UsageNode(utilization: 70, resetsAt: nil)))
        XCTAssertEqual(s.statuslineText, "5h 34% | wk 70%")
    }

    func testNoDataStillPrintsSomethingHonest() {
        // Format.percent renders nil as "--" with no unit, and that's right
        // here too: a percent sign on a missing reading would claim a number.
        XCTAssertEqual(Snapshot().statuslineText, "5h -- | wk --")
    }
}

final class StatuslineInstallerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    private var backupURL: URL { dir.appendingPathComponent(StatuslineInstaller.backupName) }
    private var scriptURL: URL { dir.appendingPathComponent(StatuslineInstaller.scriptName) }

    private func settings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as? [String: Any])
    }

    private func write(_ json: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: settingsURL)
    }

    // MARK: - Pure merge

    func testMergeIntoNothingCreatesJustOurKey() throws {
        let (data, foreign) = try StatuslineInstaller.merged(nil)
        XCTAssertFalse(foreign)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statusLine = try XCTUnwrap(root["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, StatuslineInstaller.command)
        XCTAssertEqual(root.count, 1)
    }

    func testMergePreservesEveryOtherKey() throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "model": "opus", "permissions": ["allow": ["Bash"]], "env": ["A": "1"],
        ])
        let (data, foreign) = try StatuslineInstaller.merged(original)
        XCTAssertFalse(foreign)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
        XCTAssertEqual((root["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash"])
        XCTAssertEqual(root["env"] as? [String: String], ["A": "1"])
        XCTAssertNotNil(root["statusLine"])
    }

    func testMergeFlagsAForeignStatusline() throws {
        let original = try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": "/usr/local/bin/mine.sh"],
        ])
        let (_, foreign) = try StatuslineInstaller.merged(original)
        XCTAssertTrue(foreign)
    }

    func testMergingOurOwnAgainIsNotForeign() throws {
        let (first, _) = try StatuslineInstaller.merged(nil)
        let (_, foreign) = try StatuslineInstaller.merged(first)
        XCTAssertFalse(foreign)
    }

    func testNonObjectSettingsRefuses() {
        XCTAssertThrowsError(try StatuslineInstaller.merged(Data("[1,2]".utf8)))
        XCTAssertThrowsError(try StatuslineInstaller.unmerged(Data("not json".utf8)))
    }

    func testUnmergeRemovesOnlyOurKey() throws {
        let (merged, _) = try StatuslineInstaller.merged(
            try JSONSerialization.data(withJSONObject: ["model": "opus"]))
        let data = try StatuslineInstaller.unmerged(merged)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["statusLine"])
        XCTAssertEqual(root["model"] as? String, "opus")
    }

    // MARK: - Install / uninstall on disk

    func testInstallWritesAnExecutableScriptAndTheSetting() throws {
        try StatuslineInstaller.install(in: dir)

        XCTAssertTrue(StatuslineInstaller.isInstalled(in: dir))
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: scriptURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertNotEqual(permissions.uint16Value & 0o111, 0, "script is not executable")

        let statusLine = try XCTUnwrap(try settings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, StatuslineInstaller.command)
        // Nothing foreign was replaced, so nothing was backed up.
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testReinstallIsIdempotent() throws {
        try StatuslineInstaller.install(in: dir)
        try StatuslineInstaller.install(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testForeignStatuslineIsBackedUpAndRestored() throws {
        try write(["statusLine": ["type": "command", "command": "other.sh"], "model": "opus"])
        try StatuslineInstaller.install(in: dir)

        // Backed up whole, replaced in place.
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        var statusLine = try XCTUnwrap(try settings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, StatuslineInstaller.command)

        try StatuslineInstaller.uninstall(in: dir)
        // The pre-install file came back exactly, script and backup are gone.
        statusLine = try XCTUnwrap(try settings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "other.sh")
        XCTAssertEqual(try settings()["model"] as? String, "opus")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(StatuslineInstaller.isInstalled(in: dir))
    }

    func testRefusesToClobberAForeignStatuslineWhenTheBackupSlotIsTaken() throws {
        try Data("earlier backup".utf8).write(to: backupURL)
        try write(["statusLine": ["type": "command", "command": "other.sh"]])
        XCTAssertThrowsError(try StatuslineInstaller.install(in: dir))
        // And it really did refuse: the foreign statusline is untouched.
        let statusLine = try XCTUnwrap(try settings()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "other.sh")
    }

    func testUninstallWithoutBackupJustRemovesTheKey() throws {
        try write(["model": "opus"])
        try StatuslineInstaller.install(in: dir)
        try StatuslineInstaller.uninstall(in: dir)
        XCTAssertNil(try settings()["statusLine"])
        XCTAssertEqual(try settings()["model"] as? String, "opus")
        XCTAssertFalse(StatuslineInstaller.isInstalled(in: dir))
    }

    func testUninstallWhenNothingWasInstalledIsANoOp() throws {
        XCTAssertNoThrow(try StatuslineInstaller.uninstall(in: dir))
    }
}
