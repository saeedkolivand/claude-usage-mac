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

    @AppStorage(SettingsKey.warn) private var warn = 50.0
    @AppStorage(SettingsKey.critical) private var critical = 80.0
    @AppStorage(SettingsKey.userAgent) private var userAgent = UsageAPI.defaultUserAgent
    @AppStorage(SettingsKey.menuBarMetric) private var menuBarMetric = "session"
    @AppStorage(SettingsKey.selectedProfile) private var selectedProfile = ""
    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheckUpdates = true

    private static let interval: Duration = .seconds(60)
    private var loop: Task<Void, Never>?

    /// One per profile, keyed by `Profile.id`. Every profile is polled, not just
    /// the selected one, because each widget can be scoped to a different
    /// account and the sandboxed widget cannot fetch anything itself.
    private var monitors: [String: ProfileMonitor] = [:]

    /// What the menu bar itself shows. Deliberately text-only: menu bar items
    /// are rendered as template images, so a coloured dot would come out grey.
    /// The bang is the one signal that survives monochrome.
    var menuBarTitle: String {
        guard let snapshot else { return "··" }
        let metric: Metric = menuBarMetric == "weekly" ? .weekly : .session
        guard let pct = snapshot.pct(metric) else { return "--" }
        let text = Format.percent(pct)
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
        refreshNow()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
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
            defaultProfileID: profiles.first { $0.isDefault }?.id ?? profiles.first?.id)

        for profile in profiles {
            guard let monitor = monitors[profile.id] else { continue }
            bundle.profiles[profile.id] = await monitor.snapshot(
                userAgent: userAgent, force: force, warn: warn, critical: critical,
                label: labelled ? profile.displayName : nil)
        }
        bundle.lendUsageBetweenSameAccountProfiles()
        bundle.updatedAt = Date()

        snapshot = activeProfile.flatMap { bundle.profiles[$0.id] }
        bundle.write()
        // Kept alongside the bundle so a widget built before per-widget scoping
        // still finds what it expects.
        snapshot?.write()
        WidgetCenter.shared.reloadAllTimelines()

        guard autoCheckUpdates else { return }
        // Rate-limited internally to four times a day, so calling it every poll
        // costs nothing.
        update = await UpdateChecker.shared.check(currentVersion: AppVersion.current)
        lastUpdateCheck = Date()
        await installIfFound()
    }
}
