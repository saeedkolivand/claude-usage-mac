import XCTest
@testable import UsageCore

final class TranscriptScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One assistant line whose only usage is `output_tokens`, so tokens == output
    /// and cost == output * sonnet output rate. Keeps the assertions readable.
    private func line(_ id: String, at date: Date, output: Int, cwd: String = "/code/demo",
                      model: String = "claude-sonnet-5") -> String {
        """
        {"type":"assistant","requestId":"\(id)","timestamp":"\(Self.iso.string(from: date))",\
        "cwd":"\(cwd)","message":{"id":"msg_\(id)","model":"\(model)",\
        "usage":{"output_tokens":\(output)}}}
        """
    }

    private func cost(_ tokens: Int) -> Double { Double(tokens) * 15 / 1e6 }

    @discardableResult
    private func write(_ name: String, _ lines: [String], modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// Isolated history per instance — the default would read and write the real
    /// Application Support file and let tests leak into each other.
    private func scanner() -> TranscriptScanner {
        TranscriptScanner(
            projectsDirectory: root,
            history: History(fileURL: root.appendingPathComponent("history.json")))
    }

    // MARK: - Directory state

    func testMissingDirectoryIsReportedAsNotOk() async throws {
        try FileManager.default.removeItem(at: root)
        let stats = await scanner().scan(force: true)
        XCTAssertFalse(stats.ok)
        XCTAssertEqual(stats.weekTokens, 0)
    }

    func testEmptyDirectoryIsOkWithZeroes() async throws {
        let stats = await scanner().scan(force: true)
        XCTAssertTrue(stats.ok)
        XCTAssertEqual(stats.weekTokens, 0)
    }

    // MARK: - Aggregation

    // MARK: - Per-model breakdown

    func testSplitsTheWeekByModel() async throws {
        let now = Date()
        try write("proj/one.jsonl", [
            line("r1", at: now, output: 100, model: "claude-opus-5"),
            line("r2", at: now, output: 40, model: "claude-sonnet-5"),
            line("r3", at: now, output: 10, model: "claude-haiku-4-5"),
        ])
        let stats = await scanner().scan(force: true)

        // Most tokens first, so the busiest model heads the list.
        XCTAssertEqual(stats.models.map(\.name), ["Opus", "Sonnet", "Haiku"])
        XCTAssertEqual(stats.models.first?.tokens, 100)
        // Today's entries count in both columns off one deduplication.
        XCTAssertEqual(stats.models.first?.todayTokens, 100)
        XCTAssertEqual(stats.models.map(\.tokens).reduce(0, +), stats.weekTokens)
    }

    /// Opus 4.1 bills at the old rates but is still Opus on screen, so the two
    /// pricing families share one row.
    func testOpusGenerationsShareARow() async throws {
        try write("proj/one.jsonl", [
            line("r1", at: Date(), output: 100, model: "claude-opus-4-1"),
            line("r2", at: Date(), output: 100, model: "claude-opus-5"),
        ])
        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.models.count, 1)
        XCTAssertEqual(stats.models.first?.name, "Opus")
        XCTAssertEqual(stats.models.first?.tokens, 200)
        // Priced apart even though they are shown together.
        XCTAssertEqual(stats.models.first?.cost ?? 0,
                       Double(100) * 25 / 1e6 + Double(100) * 75 / 1e6, accuracy: 1e-12)
    }

    /// Synthetic entries are never billed, so they must not invent a model row
    /// either.
    func testSyntheticEntriesAreNotAModel() async throws {
        try write("proj/one.jsonl", [
            line("r1", at: Date(), output: 100, model: "<synthetic>"),
            line("r2", at: Date(), output: 50),
        ])
        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.models.map(\.name), ["Sonnet"])
        XCTAssertEqual(stats.models.first?.tokens, 50)
    }

    func testWalksNestedProjectDirectories() async throws {
        try write("proj-a/deep/one.jsonl", [line("r1", at: Date(), output: 100)])
        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.todayTokens, 100)
        XCTAssertEqual(stats.todayCost, cost(100), accuracy: 1e-12)
    }

    func testDedupesTheSameRequestIdAcrossFiles() async throws {
        // Subagent transcripts and resumed sessions re-log the same request.
        let now = Date()
        try write("proj-a/main.jsonl", [line("dup", at: now, output: 100)],
                  modified: now)
        try write("proj-a/subagents/child.jsonl", [line("dup", at: now, output: 100)],
                  modified: now.addingTimeInterval(-60))

        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.todayTokens, 100, "counted the duplicate twice")
        XCTAssertEqual(stats.weekTokens, 100)
    }

    func testEntriesWithoutAnIdAreNotCollapsedIntoOne() async throws {
        // Can't be deduplicated, so they must all count — dropping every entry
        // after the first would be the worse failure.
        let anonymous = """
        {"type":"assistant","timestamp":"\(Self.iso.string(from: Date()))",\
        "message":{"model":"claude-sonnet-5","usage":{"output_tokens":100}}}
        """
        try write("proj-a/one.jsonl", [anonymous, anonymous])
        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.todayTokens, 200)
    }

    func testSessionIsTheMostRecentlyModifiedTranscript() async throws {
        let now = Date()
        try write("proj-a/old.jsonl", [line("r1", at: now, output: 100)],
                  modified: now.addingTimeInterval(-3600))
        try write("proj-b/current.jsonl", [line("r2", at: now, output: 700)],
                  modified: now)

        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.sessionTokens, 700)
        XCTAssertEqual(stats.sessionCost, cost(700), accuracy: 1e-12)
        XCTAssertEqual(stats.todayTokens, 800, "both files still count toward today")
    }

    func testExcludesEntriesOlderThanSevenDays() async throws {
        let now = Date()
        try write("proj-a/session.jsonl", [line("recent", at: now, output: 100)],
                  modified: now)
        // Recent file, stale entry inside it: the window is per-entry, not per-file.
        try write("proj-a/mixed.jsonl", [
            line("old", at: now.addingTimeInterval(-10 * 86400), output: 5000),
            line("inWindow", at: now.addingTimeInterval(-3 * 86400), output: 20),
        ], modified: now.addingTimeInterval(-60))

        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.weekTokens, 120)
        XCTAssertEqual(stats.todayTokens, 100)
        XCTAssertEqual(stats.sessionTokens, 100)
    }

    func testFilesUntouchedForOverAWeekAreSkippedEntirely() async throws {
        let now = Date()
        try write("proj-a/session.jsonl", [line("recent", at: now, output: 100)],
                  modified: now)
        try write("proj-a/ancient.jsonl", [line("ancient", at: now, output: 9999)],
                  modified: now.addingTimeInterval(-30 * 86400))

        // Entry timestamp is today, but the file has not been touched in a month,
        // so it is never opened.
        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.todayTokens, 100)
    }

    // MARK: - Breakdowns

    func testGroupsTheWeekByProject() async throws {
        let now = Date()
        try write("a/one.jsonl", [
            line("r1", at: now, output: 300, cwd: "/code/alpha"),
            line("r2", at: now.addingTimeInterval(-86400), output: 200, cwd: "/code/alpha"),
        ])
        try write("b/two.jsonl", [line("r3", at: now, output: 900, cwd: "/code/beta")])

        let stats = await scanner().scan(force: true)
        // Busiest first.
        XCTAssertEqual(stats.projects.map(\.name), ["beta", "alpha"])
        XCTAssertEqual(stats.projects.map(\.tokens), [900, 500])
    }

    func testProjectComesFromCwdNotTheDirectorySlug() async throws {
        // The directory under ~/.claude/projects flattens both separators and
        // underscores to "-", so it can't be reversed into a real name.
        try write("C--Users-Saeed-js-projects-my-app/s.jsonl", [
            line("r1", at: Date(), output: 100,
                 cwd: #"C:\\Users\\Saeed\\js_projects\\my_app"#),
        ])
        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.projects.map(\.name), ["my_app"])
    }

    func testBucketsTheWeekByDay() async throws {
        let now = Date()
        try write("a/one.jsonl", [
            line("r1", at: now, output: 100),
            line("r2", at: now, output: 50),
            line("r3", at: now.addingTimeInterval(-2 * 86400), output: 700),
        ])

        let stats = await scanner().scan(force: true)
        XCTAssertEqual(stats.days.last?.tokens, 150, "today's bucket")
        XCTAssertEqual(stats.days.suffix(3).first?.tokens, 700)
        XCTAssertEqual(stats.days.suffix(2).first?.tokens, 0, "idle day kept as a gap")
    }

    // MARK: - Incremental reads

    func testPicksUpLinesAppendedSinceTheLastScan() async throws {
        let scanner = self.scanner()
        let url = try write("proj-a/live.jsonl", [line("r1", at: Date(), output: 100)])

        var stats = await scanner.scan(force: true)
        XCTAssertEqual(stats.todayTokens, 100)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("r2", at: Date(), output: 50) + "\n").utf8))
        try handle.close()

        stats = await scanner.scan(force: true)
        XCTAssertEqual(stats.todayTokens, 150)
        XCTAssertEqual(stats.todayCost, cost(150), accuracy: 1e-12)
    }

    func testAPartialFinalLineIsCompletedOnTheNextScan() async throws {
        let scanner = self.scanner()
        let url = try write("proj-a/live.jsonl", [line("r1", at: Date(), output: 100)])
        let second = line("r2", at: Date(), output: 50)

        // Simulate catching Claude Code mid-write: half a line, no newline yet.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.prefix(30).utf8))
        try handle.close()

        var stats = await scanner.scan(force: true)
        XCTAssertEqual(stats.todayTokens, 100, "a torn line must not be parsed")

        let finish = try FileHandle(forWritingTo: url)
        try finish.seekToEnd()
        try finish.write(contentsOf: Data((second.dropFirst(30) + "\n").utf8))
        try finish.close()

        stats = await scanner.scan(force: true)
        XCTAssertEqual(stats.todayTokens, 150, "the completed line was lost")
    }

    func testTruncatedFileIsReReadFromScratch() async throws {
        let scanner = self.scanner()
        try write("proj-a/live.jsonl", [
            line("r1", at: Date(), output: 100),
            line("r2", at: Date(), output: 100),
        ])
        var stats = await scanner.scan(force: true)
        XCTAssertEqual(stats.todayTokens, 200)

        try write("proj-a/live.jsonl", [line("r3", at: Date(), output: 7)])

        stats = await scanner.scan(force: true)
        XCTAssertEqual(stats.todayTokens, 7, "stale entries survived a truncation")
    }

    func testCachedResultIsReusedWithinTheTtl() async throws {
        let scanner = self.scanner()
        try write("proj-a/live.jsonl", [line("r1", at: Date(), output: 100)])
        _ = await scanner.scan(force: true)

        try write("proj-a/other.jsonl", [line("r2", at: Date(), output: 100)])
        let cached = await scanner.scan()
        XCTAssertEqual(cached.todayTokens, 100, "TTL was ignored")

        let fresh = await scanner.scan(force: true)
        XCTAssertEqual(fresh.todayTokens, 200)
    }
}
