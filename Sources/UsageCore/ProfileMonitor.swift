import Foundation

/// Everything needed to watch one profile: its API client, its transcript
/// scanner, and its history file.
///
/// Grouping them is what keeps profiles from leaking into each other — the API
/// cache and the scanner's per-file offsets are both single-profile state, and a
/// shared instance would serve whichever account touched it last.
public actor ProfileMonitor {
    public let profile: Profile

    private let api: UsageAPI
    private let scanner: TranscriptScanner

    /// Recent five-hour readings, oldest first, for the burn rate.
    ///
    /// ponytail: in memory only. A relaunch starts over and the rate reappears
    /// two polls later; persisting it would mean writing a file every minute to
    /// preserve a number that is meaningless once it is five minutes old.
    private var samples: [(at: Date, pct: Double)] = []
    private static let burnWindow: TimeInterval = 30 * 60
    /// The shortest gap worth measuring a slope across. Below this, a single
    /// large turn reads as an implausible rate.
    private static let minGap: TimeInterval = 120

    public init(profile: Profile) {
        self.profile = profile
        self.api = UsageAPI(profile: profile)
        self.scanner = TranscriptScanner(profile: profile)
    }

    /// One poll. The API call and the transcript scan run concurrently, since one
    /// is network-bound and the other disk-bound.
    public func snapshot(
        userAgent: String = UsageAPI.defaultUserAgent,
        force: Bool = false,
        warn: Double = 50,
        critical: Double = 80,
        label: String? = nil,
        staleAfter: TimeInterval = 180
    ) async -> Snapshot {
        async let usage = api.fetch(userAgent: userAgent, force: force, staleAfter: staleAfter)
        let stats = await scanner.scan(force: force)
        let result = await usage

        // The snapshot's clock is when its numbers were fetched, not when this
        // poll ran — during an outage "updated 2s ago" next to hours-old
        // percentages was a lie the stale flag then had to contradict.
        var snapshot = Snapshot(updatedAt: result.fetchedAt ?? Date(),
                                usage: result.data, stats: stats,
                                error: result.error, stale: result.stale,
                                warn: warn, critical: critical)
        snapshot.profileLabel = label
        snapshot.burnRatePerHour = burnRate(for: result.data?.fiveHour?.utilization)
        return snapshot
    }

    /// Percentage points per hour on the five-hour window, measured across this
    /// process's own readings.
    ///
    /// A falling percentage means the window turned over, not that usage is
    /// dropping — so a non-positive slope yields nil rather than a negative rate.
    /// Rounded to whole points, which `Snapshot.burnRatePerHour` explains.
    func burnRate(for pct: Double?, now: Date = Date()) -> Double? {
        guard let pct else { return nil }
        let previous = samples.last

        // A falling reading is the window turning over, and everything before it
        // describes a window that no longer exists. Ageing those out instead of
        // dropping them would mean measuring across the reset for a further half
        // hour — every one of those slopes negative — so a fresh window would
        // report nothing precisely when a projection is worth having.
        if let previous, pct < previous.pct { samples.removeAll() }

        samples.append((now, pct))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.burnWindow }

        // Nothing since the last poll means nothing is burning right now.
        //
        // Load-bearing, not tidiness: without it the slope keeps decaying for
        // half an hour after a session ends — 180/h, then 120, then 90 — and
        // every one of those is a different published snapshot. That is exactly
        // the per-poll churn `SnapshotBundle.draws(differentlyFrom:)` exists to
        // keep out of WidgetKit's reload budget.
        guard let previous, pct > previous.pct else { return nil }

        guard let oldest = samples.first(where: { now.timeIntervalSince($0.at) >= Self.minGap })
        else { return nil }
        let elapsed = now.timeIntervalSince(oldest.at)
        let delta = pct - oldest.pct
        guard elapsed > 0, delta > 0 else { return nil }

        let rate = delta / (elapsed / 3600)
        // Under a point an hour there is nothing to project, and rounding would
        // make it zero regardless.
        return rate < 1 ? nil : rate.rounded()
    }

    /// Reads every transcript, not just the scan window, to seed history on a
    /// fresh install. Runs once ever, and callers fire it after the first refresh
    /// so the UI isn't waiting on gigabytes.
    public func backfillHistory() async {
        await scanner.backfillHistory()
    }
}
