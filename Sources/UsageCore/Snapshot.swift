import Foundation

/// Everything the widget needs, in one small file the host app writes.
///
/// The widget extension is sandboxed: it cannot read ~/.claude, cannot reach the
/// Keychain, and has no timer of its own. So it never fetches or parses anything
/// — it reads this and renders it.
public struct Snapshot: Codable, Sendable, Equatable {
    public var updatedAt: Date
    public var sessionPct: Double?
    public var sessionResetsAt: Date?
    public var weeklyPct: Double?
    public var weeklyResetsAt: Date?
    /// Per-model weekly windows, on the plans that have them. Every field added
    /// from here on is Optional for a reason: synthesized decoding treats a
    /// missing non-optional key as an error, so a `state.json` written by an
    /// older build would stop decoding entirely and the widget would go grey.
    public var opusPct: Double?
    public var opusResetsAt: Date?
    public var sonnetPct: Double?
    public var sonnetResetsAt: Date?
    /// Purchased extra usage, when the account has any.
    public var extraUsagePct: Double?
    /// Percentage points per hour on the five-hour window, whole points.
    ///
    /// Rounded at the source, not in the view: `SnapshotBundle.draws(
    /// differentlyFrom:)` compares published bundles to decide whether to spend a
    /// WidgetKit reload, and an unrounded rate would differ on every single poll
    /// — which is exactly the budget problem that comparison exists to solve.
    public var burnRatePerHour: Double?
    public var stats: LogStats
    /// Non-nil when the last refresh failed: "no-token", "token-expired",
    /// "http-401", "network", "bad-json".
    public var error: String?
    public var stale: Bool
    /// Carried here rather than read from UserDefaults, because the widget is
    /// sandboxed and cannot see the app's defaults without an App Group.
    public var warn: Double
    public var critical: Double
    /// Which profile these numbers belong to. Set only when the machine has more
    /// than one, so the ordinary single-profile case shows no extra chrome.
    public var profileLabel: String?

    public init(
        updatedAt: Date = Date(),
        usage: UsageData? = nil,
        stats: LogStats = LogStats(),
        error: String? = nil,
        stale: Bool = false,
        warn: Double = 50,
        critical: Double = 80
    ) {
        self.updatedAt = updatedAt
        self.warn = warn
        self.critical = critical
        self.sessionPct = usage?.fiveHour?.utilization
        self.sessionResetsAt = usage?.fiveHour?.resetsAt
        self.weeklyPct = usage?.sevenDay?.utilization
        self.weeklyResetsAt = usage?.sevenDay?.resetsAt
        self.opusPct = usage?.sevenDayOpus?.utilization
        self.opusResetsAt = usage?.sevenDayOpus?.resetsAt
        self.sonnetPct = usage?.sevenDaySonnet?.utilization
        self.sonnetResetsAt = usage?.sevenDaySonnet?.resetsAt
        self.extraUsagePct = usage?.extraUsage?.utilization
        self.stats = stats
        self.error = error
        self.stale = stale
    }

    public var sessionLevel: Level { Level.of(sessionPct, warn: warn, critical: critical) }
    public var weeklyLevel: Level { Level.of(weeklyPct, warn: warn, critical: critical) }

    /// Cost recorded since the first of this month.
    ///
    /// Summed from stored history rather than tracked separately — the snapshot
    /// already carries a quarter of daily totals, so a month is always in there
    /// and there is nothing new to persist or reset at midnight on the 1st.
    public func monthToDateCost(now: Date = Date(), calendar: Calendar = .current) -> Double {
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        else { return stats.todayCost }
        return stats.days.filter { $0.day >= start }.reduce(0) { $0 + $1.cost }
    }

    /// How long until the five-hour window fills at the current burn rate.
    ///
    /// Nil is the ordinary answer, and deliberately so: no measured rate yet, no
    /// room left, or — most often — the window resets before it could fill.
    /// Announcing "full in 6h" about a window that empties in two would be worse
    /// than saying nothing, so that case returns nil rather than a number.
    public func timeToFull(now: Date = Date()) -> TimeInterval? {
        guard let rate = burnRatePerHour, rate > 0,
              let pct = sessionPct, pct < 100 else { return nil }
        let seconds = (100 - pct) / rate * 3600
        if let reset = sessionResetsAt, now.addingTimeInterval(seconds) >= reset {
            return nil
        }
        return seconds
    }
}

extension Snapshot {

    public static let appGroup = "group.com.saeedkolivand.claude-usage"
    public static let widgetBundleID = "com.saeedkolivand.claude-usage.widget"

    private static let relativePath = "ClaudeUsage/state.json"

    /// Where a reader looks, freshest wins.
    ///
    /// Inside the widget's sandbox `.applicationSupportDirectory` already
    /// resolves to its own container, which is the path the host writes to —
    /// so the widget needs no entitlement, no App Group, and no special case.
    public static var locations: [URL] {
        var urls: [URL] = []
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            urls.append(group.appendingPathComponent(relativePath))
        }
        if let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appendingPathComponent(relativePath))
        }
        return urls
    }

    /// The widget extension is sandboxed — macOS requires that of app extensions,
    /// and an unsandboxed one is simply never registered, so it never appears in
    /// the widget gallery. That rules out reading `~/.claude` directly.
    ///
    /// App Groups would be the textbook answer, but they're a
    /// provisioning-profile capability: with ad-hoc signing and no team,
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil.
    ///
    /// The host app, though, is *not* sandboxed. So it writes straight into the
    /// widget's container, which the widget then reads as its own Application
    /// Support. No paid account, no entitlement that needs provisioning.
    static var widgetContainer: URL? {
        // Inside a sandbox this would resolve to a nested path that doesn't
        // exist; harmless, because only the unsandboxed host ever writes.
        let data = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(widgetBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)

        // Only write into a container macOS has already created. Materializing
        // one ourselves would leave it without its container metadata, which can
        // stop the extension launching at all — worse than having no data yet.
        // It appears the first time the widget runs; the next poll fills it.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: data.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        return data
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    /// Writes every location that accepts it. Succeeding at one is enough.
    @discardableResult
    public func write() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return false }

        var wrote = false
        for url in Self.locations + [Self.widgetContainer].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic so the widget can never read a half-written file.
            if (try? data.write(to: url, options: .atomic)) != nil { wrote = true }
        }
        return wrote
    }

    /// Reads the freshest snapshot available. Not simply "first that exists" —
    /// if the entitlement changes between builds, one location goes stale while
    /// the other keeps updating, and the stale one would win on ordering alone.
    public static func read() -> Snapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return locations
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(Snapshot.self, from: $0) }
            .max { $0.updatedAt < $1.updatedAt }
    }
}
