import AppKit
import Foundation
import SwiftUI
import WidgetKit

/// Owns the refresh loop. The widget never polls anything itself — this writes
/// the snapshot files and tells WidgetKit to reload.
@MainActor
final class Poller: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var update: ReleaseInfo?
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var updateState: UpdateState = .idle

    /// Versions already tried this launch. Without it a release that fails to
    /// install is retried on every poll for as long as the app stays open.
    private var attempted: Set<String> = []

    /// Severity each metric was last seen at, for the selected profile only.
    ///
    /// ponytail: in memory, so a relaunch part-way through a window can repeat
    /// one alert. Persisting it is a single UserDefaults line if that ever grates
    /// — it isn't worth a file today.
    private var lastLevel: [Metric: Level] = [:]
    /// Period start each budget alert last fired for, keyed by budget.
    private var budgetNotified: [String: Date] = [:]

    @AppStorage(SettingsKey.warn) private var warn = 50.0
    @AppStorage(SettingsKey.critical) private var critical = 80.0
    @AppStorage(SettingsKey.userAgent) private var userAgent = UsageAPI.defaultUserAgent
    @AppStorage(SettingsKey.selectedProfile) private var selectedProfile = ""
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheckUpdates = true
    @AppStorage(SettingsKey.refreshInterval) private var refreshSeconds = 60
    @AppStorage(SettingsKey.notifyThreshold) private var notifyThreshold = true
    @AppStorage(SettingsKey.dailyBudget) private var dailyBudget = 0.0
    @AppStorage(SettingsKey.monthlyBudget) private var monthlyBudget = 0.0

    private var loop: Task<Void, Never>?
    /// Only the wait, never the poll — see wakeNow().
    private var sleeper: Task<Void, Never>?

    /// One per profile, keyed by `Profile.id`. Every profile is polled, not just
    /// the selected one, because each widget can be scoped to a different
    /// account and the sandboxed widget cannot fetch anything itself.
    private var monitors: [String: ProfileMonitor] = [:]

    /// What the widget was last told about, so an unchanged poll doesn't spend a
    /// reload from WidgetKit's budget.
    private var lastPublished: SnapshotBundle?

    /// What the menu bar itself shows as text.
    ///
    /// Text is still the default form, and menu bar items are rendered as
    /// template images — so a coloured dot would come out grey and the bang is
    /// the one severity signal that survives. The ring below is the way round
    /// that, and it is opt-in.
    ///
    /// The metric and style are arguments rather than `@AppStorage` here, and
    /// that is load-bearing: `@AppStorage` on an ObservableObject does not
    /// publish a change, so reading them from this class would leave the menu
    /// bar showing the old choice until the next poll — up to ten minutes of a
    /// settings control appearing to do nothing. They live on the App scene,
    /// which SwiftUI does invalidate.
    func menuBarTitle(metric: Metric, style: MenuBarStyle) -> String {
        guard let snapshot else { return "··" }

        switch style {
        case .percentage:
            return marked(snapshot, metric)
        case .percentageAndReset:
            let resets = Format.until(snapshot.resetsAt(metric))
            return resets.isEmpty ? marked(snapshot, metric) : "\(marked(snapshot, metric)) · \(resets)"
        case .bothLimits:
            return "\(Metric.session.initial) \(Format.percent(snapshot.sessionPct))"
                + "  \(Metric.weekly.initial) \(Format.percent(snapshot.weeklyPct))"
        }
    }

    /// The same reading as a drawn ring, for the appearance that asks for one.
    ///
    /// Computed rather than published: the label body is re-evaluated when the
    /// snapshot changes or the setting does, and a 16-point render costs less
    /// than the plumbing to keep a cached copy in step with both.
    func menuBarImage(metric: Metric) -> NSImage? {
        MenuBarIcon.ring(pct: snapshot?.pct(metric),
                         level: snapshot?.level(metric) ?? .none)
    }

    private func marked(_ snapshot: Snapshot, _ metric: Metric) -> String {
        let text = Format.percent(snapshot.pct(metric))
        return snapshot.level(metric) == .critical ? "! \(text)" : text
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == selectedProfile } ?? profiles.first
    }

    /// Starts immediately: the menu bar title must be populated before the user
    /// ever opens the menu, so this can't wait for a view's onAppear.
    ///
    /// `autostart: false` builds an inert one for previews and snapshot tests —
    /// no discovery against the real home directory, no poll loop.
    init(autostart: Bool = true, profiles: [Profile] = [], snapshot: Snapshot? = nil) {
        guard autostart else {
            self.profiles = profiles
            self.snapshot = snapshot
            return
        }
        rediscover()
        start()
    }

    /// Rebuilds the profile list and the per-profile monitors. Cheap enough to
    /// run on every settings visit — it stats a handful of directories and parses
    /// one small JSON per profile.
    func rediscover() {
        profiles = ProfileStore.discover(extraPaths: ProfileStore.savedExtraPaths())

        let live = Set(profiles.map(\.id))
        monitors = monitors.filter { live.contains($0.key) }

        for profile in profiles where monitors[profile.id] == nil {
            let monitor = ProfileMonitor(profile: profile)
            monitors[profile.id] = monitor
            // Seeds history from the full transcript archive. Runs once ever per
            // profile, behind whatever poll is already in flight.
            Task { await monitor.backfillHistory() }
        }

        if let active = activeProfile, selectedProfile != active.id {
            selectedProfile = active.id
        }
        if activeProfile == nil { snapshot = nil }
    }

    func select(_ profile: Profile) {
        selectedProfile = profile.id
        // Nothing stale must sit under a newly selected profile's name.
        snapshot = nil
        // Another account's severities would otherwise decide this one's alerts.
        lastLevel.removeAll()
        refreshNow()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.waitForNextPoll()
            }
        }
    }

    func stop() {
        sleeper?.cancel()
        sleeper = nil
        loop?.cancel()
        loop = nil
    }

    /// The wait between polls, in a task of its own so it can be cut short
    /// without touching the poll it follows. The interval is read here, on each
    /// pass, so a change is picked up without restarting anything.
    private func waitForNextPoll() async {
        let task = Task { try? await Task.sleep(for: .seconds(refreshSeconds)) }
        sleeper = task
        await task.value
        sleeper = nil
    }

    /// Called when the interval changes: end the current wait so the new one
    /// starts from now. Going from ten minutes back down to one would otherwise
    /// take ten minutes to take effect.
    ///
    /// Deliberately not stop() plus start(). Cancelling the loop cancels a poll
    /// that may be in flight, and cancellation reaches URLSession — which comes
    /// back as URLError(.cancelled), which UsageAPI cannot tell from a real
    /// network failure. Changing a setting would have put "No connection" on the
    /// popover and "no update" on every widget.
    func wakeNow() {
        sleeper?.cancel()
    }

    func refreshNow() {
        Task { await refresh(force: true) }
    }

    func checkForUpdates() {
        Task {
            update = await UpdateChecker.shared.check(
                currentVersion: AppVersion.current, force: true)
            lastUpdateCheck = Date()
            await installIfFound()
        }
    }

    /// Installs whatever the last check found, then restarts into it.
    ///
    /// Gated on `autoCheckUpdates` and nothing else: turning checks off is the
    /// opt-out, because an app that has already noticed a new version and then
    /// waits to be told to fetch it is the behaviour this replaced.
    private func installIfFound() async {
        guard autoCheckUpdates, updateState == .idle,
              let release = update, attempted.insert(release.version).inserted
        else { return }
        do {
            try await Updater.install(release, over: Bundle.main.bundleURL) { step in
                Task { @MainActor in self.updateState = .busy(step) }
            }
        } catch {
            // Left on screen rather than logged away: the app is still running
            // the old version, and the only person who can act on that is
            // looking at this pane.
            updateState = .failed(error.localizedDescription)
        }
    }

    private func refresh(force: Bool = false) async {
        // A manual tap while the first (slow) scan is still running would queue a
        // second full read of the same gigabytes.
        guard !isRefreshing, !profiles.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let labelled = profiles.count > 1
        var bundle = SnapshotBundle(
            profileList: profiles,
            defaultProfileID: profiles.first { $0.isDefault }?.id ?? profiles.first?.id,
            refreshSeconds: refreshSeconds)

        for profile in profiles {
            guard let monitor = monitors[profile.id] else { continue }
            bundle.profiles[profile.id] = await monitor.snapshot(
                userAgent: userAgent, force: force, warn: warn, critical: critical,
                label: labelled ? profile.displayName : nil,
                // Three polls, whatever the interval — otherwise picking a
                // five-minute refresh would label one-poll-old numbers outdated.
                staleAfter: Double(refreshSeconds) * 3)
        }
        bundle.lendUsageBetweenSameAccountProfiles()
        bundle.updatedAt = Date()

        snapshot = activeProfile.flatMap { bundle.profiles[$0.id] }
        bundle.write()
        // Kept alongside the bundle so a widget built before per-widget scoping
        // still finds what it expects.
        snapshot?.write()
        if bundle.draws(differentlyFrom: lastPublished) {
            lastPublished = bundle
            WidgetCenter.shared.reloadAllTimelines()
        }
        if let snapshot { alert(about: snapshot) }

        guard autoCheckUpdates else { return }
        // Rate-limited internally to four times a day, so calling it every poll
        // costs nothing.
        update = await UpdateChecker.shared.check(currentVersion: AppVersion.current)
        lastUpdateCheck = Date()
        await installIfFound()
    }

    // MARK: - Alerts

    /// Only ever about the selected profile. A machine with four config folders
    /// on one account would otherwise fire four identical notifications for the
    /// same limit.
    private func alert(about snapshot: Snapshot) {
        thresholdAlerts(snapshot)
        budgetAlerts(snapshot)
    }

    /// Fires on an upward crossing only. Falling back — which is what a window
    /// resetting looks like — clears the latch, and that is what re-arms it.
    private func thresholdAlerts(_ snapshot: Snapshot) {
        guard notifyThreshold else {
            lastLevel.removeAll()
            return
        }
        for metric in [Metric.session, .weekly] + snapshot.perModelLimits {
            guard let pct = snapshot.pct(metric) else { continue }
            let level = snapshot.level(metric)
            let previous = lastLevel[metric] ?? .ok
            lastLevel[metric] = level
            guard level == .warn || level == .critical,
                  Self.rank(level) > Self.rank(previous) else { continue }

            let resets = Format.until(snapshot.resetsAt(metric))
            Task {
                await Notifier.shared.post(
                    title: "\(metric.title) at \(Format.percent(pct))",
                    body: resets.isEmpty ? "Claude Usage" : "Resets in \(resets)")
            }
        }
    }

    /// Setting a target is the opt-in — a budget you can see a bar for but never
    /// hear about is a decoration. Once per period, latched on the period's start
    /// date so a new day or month re-arms it without any bookkeeping.
    private func budgetAlerts(_ snapshot: Snapshot) {
        let calendar = Calendar.current
        let now = Date()

        if dailyBudget > 0, snapshot.stats.todayCost >= dailyBudget {
            announce(budget: "daily", period: calendar.startOfDay(for: now),
                     title: "Daily budget reached",
                     body: "\(Format.cost(snapshot.stats.todayCost)) of \(Format.cost(dailyBudget)) today")
        }
        if monthlyBudget > 0 {
            let spent = snapshot.monthToDateCost(now: now, calendar: calendar)
            if spent >= monthlyBudget,
               let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) {
                announce(budget: "monthly", period: start,
                         title: "Monthly budget reached",
                         body: "\(Format.cost(spent)) of \(Format.cost(monthlyBudget)) this month")
            }
        }
    }

    /// Keyed by profile as well as period. The budget itself is one global
    /// setting, but the spend it is measured against is per account — so an
    /// unqualified key means whichever profile crosses first silences every
    /// other one for the rest of the day. Clearing the latch on a profile switch
    /// would be worse: it re-arms an account that has already been told, and the
    /// picker is one click.
    private func budgetKey(_ budget: String) -> String {
        "\(selectedProfile)/\(budget)"
    }

    private func announce(budget: String, period: Date, title: String, body: String) {
        let key = budgetKey(budget)
        guard budgetNotified[key] != period else { return }
        budgetNotified[key] = period
        Task { await Notifier.shared.post(title: title, body: body) }
    }

    private static func rank(_ level: Level) -> Int {
        switch level {
        case .none, .ok: return 0
        case .warn:      return 1
        case .critical:  return 2
        }
    }
}
