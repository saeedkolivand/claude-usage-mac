import XCTest
@testable import UsageCore

final class ProfileDiscoveryTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeProfile(_ name: String, oauth: [String: Any]? = nil,
                             globalConfigName: String? = nil) throws -> URL {
        let dir = home.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("projects"), withIntermediateDirectories: true)
        if let oauth, let file = globalConfigName {
            try write(["oauthAccount": oauth], to: home.appendingPathComponent(file))
        }
        return dir
    }

    private func write(_ json: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func discover(env: [String: String] = [:], extra: [String] = []) -> [Profile] {
        ProfileStore.discover(extraPaths: extra, environment: env, home: home)
    }

    // MARK: - What counts as a profile

    func testADirectoryWithTranscriptsIsAProfile() throws {
        try makeProfile(".claude")
        let profiles = discover()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].isDefault)
    }

    func testCredentialsAreNotRequired() throws {
        // They can be relocated, or live in the Keychain / Credential Manager
        // with no file at all — requiring one would hide real profiles.
        try makeProfile(".claude")
        XCTAssertEqual(discover().count, 1)
    }

    func testDirectoriesWithoutTranscriptsAreIgnored() throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude-flow"), withIntermediateDirectories: true)
        try makeProfile(".claude")
        XCTAssertEqual(discover().map(\.configDir.lastPathComponent), [".claude"])
    }

    func testFindsRelocatedSiblings() throws {
        try makeProfile(".claude")
        try makeProfile(".claude-work")
        XCTAssertEqual(discover().map(\.configDir.lastPathComponent).sorted(),
                       [".claude", ".claude-work"])
    }

    func testDefaultComesFirst() throws {
        try makeProfile(".claude-aaa")
        try makeProfile(".claude")
        XCTAssertTrue(discover().first?.isDefault == true)
    }

    func testOnlyTheDefaultDirectoryIsMarkedDefault() throws {
        try makeProfile(".claude")
        try makeProfile(".claude-work")
        let work = try XCTUnwrap(discover().first { $0.configDir.lastPathComponent == ".claude-work" })
        XCTAssertFalse(work.isDefault)
    }

    func testHonoursClaudeConfigDir() throws {
        let relocated = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(
            at: relocated.appendingPathComponent("projects"), withIntermediateDirectories: true)

        let profiles = discover(env: ["CLAUDE_CONFIG_DIR": relocated.path])
        XCTAssertEqual(profiles.map(\.configDir.lastPathComponent), ["elsewhere"])
        XCTAssertFalse(profiles[0].isDefault, "a relocated dir is not the default")
    }

    func testNoDuplicatesWhenSourcesOverlap() throws {
        let dir = try makeProfile(".claude")
        let profiles = discover(env: ["CLAUDE_CONFIG_DIR": dir.path], extra: [dir.path])
        XCTAssertEqual(profiles.count, 1)
    }

    func testExtraPathsAreIncluded() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertEqual(discover(extra: [outside.path]).count, 1)
    }

    func testNothingFoundIsEmptyNotACrash() {
        XCTAssertTrue(discover().isEmpty)
    }

    // MARK: - Where identity comes from

    func testDefaultProfileReadsItsSiblingGlobalConfig() throws {
        // ~/.claude.json sits NEXT TO ~/.claude, not inside it.
        try makeProfile(".claude",
                        oauth: ["emailAddress": "me@example.com",
                                "organizationName": "Acme",
                                "organizationRateLimitTier": "default_claude_max_20x"],
                        globalConfigName: ".claude.json")

        let profile = try XCTUnwrap(discover().first)
        XCTAssertEqual(profile.email, "me@example.com")
        XCTAssertEqual(profile.organization, "Acme")
        XCTAssertEqual(profile.plan, "Max")
    }

    func testRelocatedProfileReadsTheConfigInsideItself() throws {
        let dir = try makeProfile(".claude-work")
        try write(["oauthAccount": ["emailAddress": "work@example.com"]],
                  to: dir.appendingPathComponent(".claude.json"))

        let profile = try XCTUnwrap(discover().first)
        XCTAssertEqual(profile.email, "work@example.com")
    }

    func testRelocatedProfileNeverInheritsTheDefaultAccountsIdentity() throws {
        // ~/.claude-work's parent is also ~, so an ungated sibling lookup would
        // stamp the default account's email onto every relocated profile.
        try makeProfile(".claude",
                        oauth: ["emailAddress": "personal@example.com"],
                        globalConfigName: ".claude.json")
        try makeProfile(".claude-work")

        let work = try XCTUnwrap(discover().first { !$0.isDefault })
        XCTAssertNil(work.email, "picked up the default profile's identity")
    }

    func testConfigJsonWinsOverClaudeJson() throws {
        let dir = try makeProfile(".claude-work")
        try write(["oauthAccount": ["emailAddress": "old@example.com"]],
                  to: dir.appendingPathComponent(".claude.json"))
        try write(["oauthAccount": ["emailAddress": "new@example.com"]],
                  to: dir.appendingPathComponent(".config.json"))

        XCTAssertEqual(discover().first?.email, "new@example.com")
    }

    func testMissingOrCorruptGlobalConfigStillYieldsAUsableProfile() throws {
        let dir = try makeProfile(".claude-work")
        try Data("not json".utf8).write(to: dir.appendingPathComponent(".claude.json"))

        let profile = try XCTUnwrap(discover().first)
        XCTAssertNil(profile.email)
        XCTAssertEqual(profile.displayName, ".claude-work")
    }

    func testPlanLabel() {
        XCTAssertEqual(ProfileStore.planLabel("default_claude_max_20x"), "Max")
        XCTAssertEqual(ProfileStore.planLabel("claude_pro"), "Pro")
        XCTAssertEqual(ProfileStore.planLabel("enterprise_thing"), "Enterprise")
        XCTAssertNil(ProfileStore.planLabel("something_unknown"))
        XCTAssertNil(ProfileStore.planLabel(nil))
    }

    func testDisplayName() throws {
        try makeProfile(".claude", oauth: ["emailAddress": "me@example.com"],
                        globalConfigName: ".claude.json")
        XCTAssertEqual(discover().first?.displayName, "Default — me@example.com")
    }
}

final class ProfileCredentialsTests: XCTestCase {

    private func profile(_ dir: URL, isDefault: Bool) -> Profile {
        Profile(configDir: dir, isDefault: isDefault)
    }

    func testReadsTheProfilesOwnCredentialsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("creds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let future = (Date().timeIntervalSince1970 + 3600) * 1000
        try JSONSerialization
            .data(withJSONObject: ["claudeAiOauth": ["accessToken": "tok", "expiresAt": future]])
            .write(to: dir.appendingPathComponent(".credentials.json"))

        let creds = CredentialStore.read(for: profile(dir, isDefault: false))
        XCTAssertEqual(creds.token, "tok")
        XCTAssertFalse(creds.expired)
    }

    /// An expired file must not be mistaken for being signed out, and must not
    /// swallow the search either — the Keychain candidates behind it still get
    /// tried, and only when they all miss does the expired one come back.
    func testExpiredCredentialsFileReportsExpiredRatherThanSignedOut() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("creds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let past = (Date().timeIntervalSince1970 - 3600) * 1000
        try JSONSerialization
            .data(withJSONObject: ["claudeAiOauth": ["accessToken": "stale", "expiresAt": past]])
            .write(to: dir.appendingPathComponent(".credentials.json"))

        // Non-default and outside the home directory, so its hashed service
        // names own no Keychain item and the fallback is the only way out.
        let creds = CredentialStore.read(for: profile(dir, isDefault: false))
        XCTAssertEqual(creds.token, "stale")
        XCTAssertTrue(creds.expired)
    }

    func testNonDefaultProfileNeverReadsTheDefaultsKeychainItem() {
        // A relocated profile must never fall back to the bare service name:
        // that would show another account's percentages under this profile's
        // name — wrong, and invisibly so. Its hashed names are fine, because the
        // hash *is* the per-profile key.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString)", isDirectory: true)
        let services = CredentialStore.keychainServices(for: profile(missing, isDefault: false))

        XCTAssertFalse(services.contains("Claude Code-credentials"))
        XCTAssertTrue(services.allSatisfy { $0.hasPrefix("Claude Code-credentials-") })
        XCTAssertNil(CredentialStore.read(for: profile(missing, isDefault: false)).token)
    }

    /// Vectors computed against the algorithm read out of the Claude Code binary
    /// (v2.1.223): `Claude Code-credentials-<sha256(configDir)[0..<8]>`, where the
    /// hash is over the raw `CLAUDE_CONFIG_DIR` string, NFC-normalised.
    func testKeychainServiceIsHashedPerConfigDir() {
        let ruby = profile(URL(fileURLWithPath: "/Users/mohammad/.claude-ruby"), isDefault: false)
        XCTAssertEqual(CredentialStore.keychainServices(for: ruby).first,
                       "Claude Code-credentials-a7edb27d")
        // A trailing slash is a different string, so it hashes differently — hence
        // trying both spellings rather than picking one.
        XCTAssertTrue(CredentialStore.keychainServices(for: ruby)
            .contains("Claude Code-credentials-2fedf0e7"))
    }

    func testDefaultProfileTriesTheBareNameFirstThenHashedFallbacks() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let services = CredentialStore.keychainServices(for: profile(dir, isDefault: true))

        XCTAssertEqual(services.first, "Claude Code-credentials")
        // A user who exports CLAUDE_CONFIG_DIR at ~/.claude anyway gets a hashed
        // item, so the tilde spelling must still be reachable.
        XCTAssertTrue(services.contains("Claude Code-credentials-\(CredentialStore.sha8("~/.claude"))"))
    }
}

final class ProfileHistoryTests: XCTestCase {

    func testDefaultProfileKeepsTheOriginalFilename() {
        // The file shipped in v0.2.0 must not need migrating.
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let url = History.url(for: Profile(configDir: dir, isDefault: true))
        XCTAssertEqual(url.lastPathComponent, "history.json")
    }

    func testOtherProfilesGetTheirOwnFile() {
        let a = History.url(for: Profile(configDir: URL(fileURLWithPath: "/Users/x/.claude-work"),
                                         isDefault: false))
        let b = History.url(for: Profile(configDir: URL(fileURLWithPath: "/Users/x/.claude-side"),
                                         isDefault: false))
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.lastPathComponent.hasPrefix("history-"))
    }

    func testTwoProfilesDoNotClobberEachOther() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let today = Calendar.current.startOfDay(for: Date())
        let a = History(fileURL: root.appendingPathComponent("a.json"))
        let b = History(fileURL: root.appendingPathComponent("b.json"))

        a.merge([DayUsage(day: today, tokens: 100, cost: 1)])
        b.merge([DayUsage(day: today, tokens: 900, cost: 9)])

        XCTAssertEqual(a.recent(1).first?.tokens, 100)
        XCTAssertEqual(b.recent(1).first?.tokens, 900)
    }

    func testSlugIsReadable() {
        XCTAssertEqual(History.slug("/Users/saeed/.claude-work"), "users-saeed-claude-work")
    }
}

/// Claude Code only refreshes the config dir it runs in, so a profile you have
/// stopped using parks on a dead token and hours-old rings. The usage endpoint
/// is account-scoped, so a live sibling on the same account has the real numbers.
final class SnapshotBundleLendingTests: XCTestCase {

    private func profile(_ name: String, email: String?, organization: String?) -> Profile {
        Profile(configDir: URL(fileURLWithPath: "/Users/tester/\(name)"),
                isDefault: name == ".claude", email: email, organization: organization)
    }

    private var liveSnapshot: Snapshot {
        Snapshot(usage: UsageData(
            fiveHour: UsageNode(utilization: 2, resetsAt: Date().addingTimeInterval(4 * 3600)),
            sevenDay: UsageNode(utilization: 9, resetsAt: Date().addingTimeInterval(3 * 86400))))
    }

    /// What the screenshots showed: a frozen payload whose five-hour window has
    /// already elapsed, so the ring renders "resets 0m".
    private var expiredSnapshot: Snapshot {
        Snapshot(usage: UsageData(
            fiveHour: UsageNode(utilization: 2, resetsAt: Date().addingTimeInterval(-3600)),
            sevenDay: nil),
            error: "token-expired", stale: true)
    }

    private func bundle(_ entries: [(Profile, Snapshot)]) -> SnapshotBundle {
        var built = SnapshotBundle(profileList: entries.map(\.0))
        for (profile, snapshot) in entries { built.profiles[profile.id] = snapshot }
        return built
    }

    func testExpiredProfileTakesTheRingsOfASameAccountSibling() throws {
        let dead = profile(".claude", email: "me@corp.com", organization: "Corp")
        let alive = profile(".claude-intellij", email: "me@corp.com", organization: "Corp")
        var subject = bundle([(dead, expiredSnapshot), (alive, liveSnapshot)])

        subject.lendUsageBetweenSameAccountProfiles()

        let healed = try XCTUnwrap(subject.profiles[dead.id])
        let donor = try XCTUnwrap(subject.profiles[alive.id])
        XCTAssertNil(healed.error)
        XCTAssertFalse(healed.stale)
        XCTAssertEqual(healed.sessionResetsAt, donor.sessionResetsAt)
        XCTAssertEqual(healed.weeklyResetsAt, donor.weeklyResetsAt)
        XCTAssertEqual(healed.weeklyPct, 9)
        // A future reset is the whole point: this is what stops "resets 0m".
        XCTAssertGreaterThan(try XCTUnwrap(healed.sessionResetsAt), Date())
    }

    func testADifferentAccountNeverLendsItsNumbers() throws {
        let dead = profile(".claude", email: "me@corp.com", organization: "Corp")
        let other = profile(".claude-ruby", email: "me@corp.com", organization: "Other Org")
        var subject = bundle([(dead, expiredSnapshot), (other, liveSnapshot)])

        subject.lendUsageBetweenSameAccountProfiles()

        XCTAssertEqual(subject.profiles[dead.id]?.error, "token-expired")
        XCTAssertLessThan(try XCTUnwrap(subject.profiles[dead.id]?.sessionResetsAt), Date())
    }

    /// An unidentified profile must not inherit an identity by proximity.
    func testAProfileWithNoAccountOnDiskBorrowsNothing() {
        let dead = profile(".claude", email: nil, organization: nil)
        let alive = profile(".claude-intellij", email: nil, organization: nil)
        var subject = bundle([(dead, expiredSnapshot), (alive, liveSnapshot)])

        subject.lendUsageBetweenSameAccountProfiles()

        XCTAssertEqual(subject.profiles[dead.id]?.error, "token-expired")
    }

    /// "no-token" is also what a denied Keychain prompt looks like. Hiding it
    /// behind a sibling's numbers would bury something the user can fix.
    func testSignedOutProfileIsLeftSayingSo() {
        let out = profile(".claude", email: "me@corp.com", organization: "Corp")
        let alive = profile(".claude-intellij", email: "me@corp.com", organization: "Corp")
        var subject = bundle([(out, Snapshot(usage: nil, error: "no-token")),
                              (alive, liveSnapshot)])

        subject.lendUsageBetweenSameAccountProfiles()

        XCTAssertEqual(subject.profiles[out.id]?.error, "no-token")
        XCTAssertNil(subject.profiles[out.id]?.sessionPct)
    }

    // MARK: - Reload gating

    /// Every poll restamps `updatedAt` whether or not a fetch succeeded, so
    /// reloading on inequality alone asked WidgetKit for 1440 reloads a day
    /// against a budget of a few dozen — and got throttled for it.
    func testAPollThatOnlyRestampedTheClockAsksForNoReload() {
        let only = profile(".claude", email: "me@corp.com", organization: "Corp")
        let before = bundle([(only, liveSnapshot)])

        var after = before
        after.updatedAt = before.updatedAt.addingTimeInterval(60)
        after.profiles = after.profiles.mapValues {
            var snapshot = $0
            snapshot.updatedAt = $0.updatedAt.addingTimeInterval(60)
            return snapshot
        }

        XCTAssertFalse(after.draws(differentlyFrom: before))
    }

    func testMovedNumbersANewErrorAndAChangedProfileListAllAskForAReload() {
        let only = profile(".claude", email: "me@corp.com", organization: "Corp")
        let before = bundle([(only, liveSnapshot)])

        var moved = before
        moved.profiles[only.id]?.sessionPct = 3
        XCTAssertTrue(moved.draws(differentlyFrom: before))

        var failed = before
        failed.profiles[only.id]?.error = "network"
        XCTAssertTrue(failed.draws(differentlyFrom: before))

        let added = profile(".claude-intellij", email: "me@corp.com", organization: "Corp")
        let grown = bundle([(only, liveSnapshot), (added, liveSnapshot)])
        XCTAssertTrue(grown.draws(differentlyFrom: before))

        // First poll of a launch has nothing to compare against.
        XCTAssertTrue(before.draws(differentlyFrom: nil))
    }
}
