import Foundation

public struct LogStats: Codable, Sendable, Equatable {
    public var todayTokens: Int = 0
    public var todayCost: Double = 0
    public var weekTokens: Int = 0
    public var weekCost: Double = 0
    public var sessionTokens: Int = 0
    public var sessionCost: Double = 0
    /// Busiest projects over the same rolling week, most tokens first.
    public var projects: [ProjectUsage] = []
    /// Where the week's tokens and cost went by model, most tokens first.
    public var models: [ModelUsage] = []
    /// Daily totals, oldest first. Outlives the transcripts themselves — see History.
    public var days: [DayUsage] = []
    /// False when ~/.claude/projects is missing or unreadable.
    public var ok: Bool = true

    public init() {}
}

extension LogStats {
    /// Hand-written so a missing key falls back to the property's default
    /// instead of throwing.
    ///
    /// Synthesized decoding calls `decode` for every non-optional property, so a
    /// `state.json` written before a field existed fails to decode *entirely* —
    /// and a snapshot that won't decode is a widget showing a grey placeholder.
    /// This project has shipped that failure twice already (0.3, then 0.3.2), so
    /// the format is additive by construction from here on: add a property with
    /// a default, and old files keep working.
    ///
    /// `CodingKeys` is spelled out rather than left to synthesis, so the manual
    /// decoder and the synthesized encoder are provably reading the same names.
    enum CodingKeys: String, CodingKey {
        case todayTokens, todayCost, weekTokens, weekCost, sessionTokens, sessionCost
        case projects, models, days, ok
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        todayTokens = try c.decodeIfPresent(Int.self, forKey: .todayTokens) ?? 0
        todayCost = try c.decodeIfPresent(Double.self, forKey: .todayCost) ?? 0
        weekTokens = try c.decodeIfPresent(Int.self, forKey: .weekTokens) ?? 0
        weekCost = try c.decodeIfPresent(Double.self, forKey: .weekCost) ?? 0
        sessionTokens = try c.decodeIfPresent(Int.self, forKey: .sessionTokens) ?? 0
        sessionCost = try c.decodeIfPresent(Double.self, forKey: .sessionCost) ?? 0
        projects = try c.decodeIfPresent([ProjectUsage].self, forKey: .projects) ?? []
        models = try c.decodeIfPresent([ModelUsage].self, forKey: .models) ?? []
        days = try c.decodeIfPresent([DayUsage].self, forKey: .days) ?? []
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
    }
}

/// One model family's share of the week. Families are collapsed to what a reader
/// recognises — Opus 4.1 and Opus 5 bill differently but share a row.
public struct ModelUsage: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// Rolling week, matching the scanner's window.
    public var tokens: Int
    public var cost: Double
    public var todayTokens: Int
    public var todayCost: Double

    public var id: String { name }

    public init(name: String, tokens: Int = 0, cost: Double = 0,
                todayTokens: Int = 0, todayCost: Double = 0) {
        self.name = name
        self.tokens = tokens
        self.cost = cost
        self.todayTokens = todayTokens
        self.todayCost = todayCost
    }
}

public struct ProjectUsage: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// Rolling week, matching the scanner's window.
    public var tokens: Int
    public var cost: Double
    public var todayTokens: Int
    public var todayCost: Double
    /// Only as far back as the scan window — unlike whole-account history, which
    /// is persisted, per-project days are recomputed each scan and so stop at
    /// seven. Long enough for a widget's sparkline, and it keeps the history
    /// file from growing by a factor of twenty.
    public var days: [DayUsage]

    public var id: String { name }

    public init(name: String, tokens: Int = 0, cost: Double = 0,
                todayTokens: Int = 0, todayCost: Double = 0, days: [DayUsage] = []) {
        self.name = name
        self.tokens = tokens
        self.cost = cost
        self.todayTokens = todayTokens
        self.todayCost = todayCost
        self.days = days
    }
}

public struct DayUsage: Codable, Sendable, Equatable, Identifiable {
    public var day: Date  // start of day, local time
    public var tokens: Int
    public var cost: Double
    public var id: Date { day }

    public init(day: Date, tokens: Int, cost: Double) {
        self.day = day
        self.tokens = tokens
        self.cost = cost
    }
}

/// Accumulator for one project while a scan is in flight. Days live in a
/// dictionary here and become a sorted array only once, at the end.
struct ProjectAccumulator {
    var tokens = 0
    var cost = 0.0
    var todayTokens = 0
    var todayCost = 0.0
    var days: [Date: DayUsage] = [:]

    mutating func add(_ entry: LogEntry, day: Date, isToday: Bool) {
        tokens += entry.tokens
        cost += entry.cost
        if isToday {
            todayTokens += entry.tokens
            todayCost += entry.cost
        }
        days[day, default: DayUsage(day: day, tokens: 0, cost: 0)].add(entry)
    }

    func finish(name: String) -> ProjectUsage {
        ProjectUsage(name: name, tokens: tokens, cost: cost,
                     todayTokens: todayTokens, todayCost: todayCost,
                     days: days.values.sorted { $0.day < $1.day })
    }
}

extension DayUsage {
    mutating func add(_ entry: LogEntry) {
        tokens += entry.tokens
        cost += entry.cost
    }
}

extension ModelUsage {
    mutating func add(_ entry: LogEntry, isToday: Bool) {
        tokens += entry.tokens
        cost += entry.cost
        if isToday {
            todayTokens += entry.tokens
            todayCost += entry.cost
        }
    }
}

struct LogEntry {
    let id: String
    let timestamp: Date?
    let tokens: Int
    let cost: Double
    /// Classified once at parse time. The scanner reads this model string over
    /// every entry of a multi-gigabyte archive, so it is not re-derived later.
    let family: ModelFamily
    /// From the entry's `cwd`. The directory name under ~/.claude/projects is a
    /// slug with separators and underscores both flattened to "-", so it can't be
    /// reversed into a real name; cwd is exact.
    let project: String?
}

/// Walks ~/.claude/projects and totals token usage and cost.
///
/// Re-reading every recent transcript on each poll is fine for a one-shot CLI
/// and not fine for a process that polls every 60s — this machine has ~2.7 GB
/// of transcripts with a single 75 MB file in it. So each file's parsed entries
/// are cached and only bytes appended since the last read are parsed.
public actor TranscriptScanner {
    private static let ttl: TimeInterval = 30
    private static let window: TimeInterval = 7 * 86400
    /// How much history travels in the snapshot. More than any view shows, so the
    /// charts can change range without a new snapshot format. Thirteen weeks plus
    /// today is what the heatmap draws; at roughly 60 bytes a day that is about
    /// 5 KB per profile, which the widget reads from disk once a poll.
    private static let historyDays = 92
    /// How many projects travel in the snapshot, busiest first.
    private static let maxProjects = 20

    private struct FileState {
        var parsedOffset: UInt64 = 0
        var entries: [LogEntry] = []
        /// One transcript belongs to one project, so this is read once and kept.
        var project: String?
    }

    private var files: [String: FileState] = [:]
    private var cached: LogStats?
    private var cachedAt: Date = .distantPast
    private let root: URL
    private let history: History

    public init(projectsDirectory: URL? = nil, history: History? = nil) {
        self.root = projectsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        self.history = history ?? History()
    }

    public init(profile: Profile) {
        self.root = profile.projectsDirectory
        self.history = History(profile: profile)
    }

    public func scan(force: Bool = false) -> LogStats {
        let now = Date()
        if !force, let cached, now.timeIntervalSince(cachedAt) < Self.ttl {
            return cached
        }

        var stats = LogStats()
        let found = listTranscripts()

        guard !found.isEmpty else {
            // Empty could mean "no logs yet" or "no such directory" — only the
            // latter is a problem worth surfacing.
            stats.ok = FileManager.default.fileExists(atPath: root.path)
            files.removeAll()
            cached = stats
            cachedAt = now
            return stats
        }

        // Newest-first; the most recently touched transcript is "the session".
        let sorted = found.sorted { $0.modified > $1.modified }
        let sessionPath = sorted[0].url.path
        let cutoff = now.addingTimeInterval(-Self.window)

        // Anything outside the window (and not the session file) is dropped from
        // the cache entirely, so memory tracks the window rather than growing.
        let live = sorted.filter { $0.modified >= cutoff || $0.url.path == sessionPath }
        let livePaths = Set(live.map(\.url.path))
        files = files.filter { livePaths.contains($0.key) }

        for file in live {
            refresh(file)
        }

        let calendar = Calendar.current
        var seenToday = Set<String>()
        var seenWeek = Set<String>()
        var seenSession = Set<String>()
        var byProject: [String: ProjectAccumulator] = [:]
        var byModel: [String: ModelUsage] = [:]
        var byDay: [Date: DayUsage] = [:]

        for file in live {
            guard let state = files[file.url.path] else { continue }
            let isSession = file.url.path == sessionPath
            let project = state.project ?? "unknown"

            for entry in state.entries {
                if isSession, claim(entry.id, in: &seenSession) {
                    stats.sessionTokens += entry.tokens
                    stats.sessionCost += entry.cost
                }
                guard let ts = entry.timestamp else { continue }
                let isToday = calendar.isDateInToday(ts)

                if ts >= cutoff, claim(entry.id, in: &seenWeek) {
                    stats.weekTokens += entry.tokens
                    stats.weekCost += entry.cost

                    let day = calendar.startOfDay(for: ts)
                    byProject[project, default: ProjectAccumulator()]
                        .add(entry, day: day, isToday: isToday)
                    // Inside the week claim rather than beside the today one:
                    // today is always within the window, so this counts both
                    // buckets off a single deduplication.
                    let model = entry.family.label
                    byModel[model, default: ModelUsage(name: model)]
                        .add(entry, isToday: isToday)
                    byDay[day, default: DayUsage(day: day, tokens: 0, cost: 0)].add(entry)
                }
                if isToday, claim(entry.id, in: &seenToday) {
                    stats.todayTokens += entry.tokens
                    stats.todayCost += entry.cost
                }
            }
        }

        stats.projects = byProject
            .map { $0.value.finish(name: $0.key) }
            .sorted { $0.tokens > $1.tokens }
            // Bounded so the snapshot file stays small; nobody scopes a widget to
            // their 40th-busiest directory.
            .prefix(Self.maxProjects)
            .map { $0 }
        stats.models = byModel.values.sorted { $0.tokens > $1.tokens }
        // Only the scanned window is recomputed; older days come from the store,
        // which is why history survives Claude Code pruning its transcripts.
        history.merge(Array(byDay.values))
        stats.days = history.recent(Self.historyDays)

        cached = stats
        cachedAt = now
        return stats
    }

    /// Reads every transcript, not just the scan window, to seed history on a
    /// fresh install. Runs inside the actor so it can't race an ordinary scan;
    /// callers fire it after the first refresh so the UI isn't waiting on it.
    public func backfillHistory() {
        history.backfill(from: root)
        cached = nil  // next scan re-reads history rather than serving pre-backfill days
    }

    /// Entries without an id can't be deduplicated, so they always count —
    /// double-counting a rare id-less entry beats dropping every one after the first.
    private func claim(_ id: String, in seen: inout Set<String>) -> Bool {
        id.isEmpty ? true : seen.insert(id).inserted
    }

    // MARK: - Incremental read

    private struct Transcript {
        let url: URL
        let modified: Date
        let size: UInt64
    }

    private func listTranscripts() -> [Transcript] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Transcript] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            out.append(Transcript(url: url, modified: modified,
                                  size: UInt64(values.fileSize ?? 0)))
        }
        return out
    }

    private func refresh(_ file: Transcript) {
        var state = files[file.url.path] ?? FileState()

        // Truncated or rotated — the cached entries no longer describe this file.
        if file.size < state.parsedOffset {
            state = FileState()
        }
        guard file.size > state.parsedOffset else {
            files[file.url.path] = state
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: state.parsedOffset)
            guard let chunk = try handle.readToEnd(), !chunk.isEmpty else {
                files[file.url.path] = state
                return
            }
            let before = state.entries.count
            state.parsedOffset += UInt64(Self.append(chunk, to: &state.entries))
            if state.project == nil {
                state.project = state.entries[before...].lazy.compactMap(\.project).first
            }
        } catch {
            return  // leave the offset untouched; retry on the next poll
        }

        files[file.url.path] = state
    }

    /// Parses whole lines out of `chunk` and returns how many bytes were consumed.
    /// A trailing partial line is left unconsumed so the next read picks it up
    /// from the start — the offset only ever advances past a newline.
    static func append(_ chunk: Data, to entries: inout [LogEntry]) -> Int {
        guard let lastNewline = chunk.lastIndex(of: 0x0A) else { return 0 }
        let complete = chunk[chunk.startIndex...lastNewline]

        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = parseLine(Data(line)) { entries.append(entry) }
        }
        return chunk.distance(from: chunk.startIndex, to: lastNewline) + 1
    }

    /// Only assistant messages carry usage, and they are a minority of lines.
    /// A substring test costs a fraction of a full JSON parse, which matters when
    /// the cold-start read is hundreds of megabytes.
    /// ponytail: false positives (the word appearing in message text) just pay
    /// for a parse that then rejects them; only a false negative would lose data,
    /// and every usage-bearing line contains this by construction.
    private static let usageMarker = Data("\"usage\":".utf8)

    static func parseLine(_ line: Data) -> LogEntry? {
        guard line.range(of: usageMarker) != nil else { return nil }
        guard
            let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            obj["type"] as? String == "assistant",
            let message = obj["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = message["model"] as? String ?? ""
        // Locally generated on API errors and interrupts — never billed.
        guard model != "<synthetic>" else { return nil }

        // Top-level fields are the totals; `usage.iterations` breaks the same
        // numbers down per iteration, so summing both would double-count.
        let tokens =
            intValue(usage["input_tokens"])
            + intValue(usage["output_tokens"])
            + intValue(usage["cache_creation_input_tokens"])
            + intValue(usage["cache_read_input_tokens"])

        let family = Pricing.family(model)
        return LogEntry(
            id: (obj["requestId"] as? String) ?? (message["id"] as? String) ?? "",
            timestamp: parseDate(obj["timestamp"]),
            tokens: tokens,
            cost: Pricing.cost(usage: usage, family: family),
            family: family,
            project: projectName(obj["cwd"]))
    }

    /// Last path component of the working directory, handling both separators
    /// since transcripts are written on Windows as well as macOS.
    static func projectName(_ cwd: Any?) -> String? {
        guard let path = cwd as? String, !path.isEmpty else { return nil }
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
        return name.map(String.init)
    }
}
