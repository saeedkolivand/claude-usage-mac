import AppIntents
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    /// Non-nil when this widget is scoped to one project.
    let project: ProjectUsage?
    let scopeLabel: String?
    /// Set when the widget's configuration could not be honoured. Rendered
    /// instead of numbers, because showing some other account's figures under
    /// this widget's name is worse than showing nothing.
    var problem: WidgetProblem?
    /// The configured look. A property default rather than an init parameter:
    /// every entry gets it stamped in one place, `entry(for:)`.
    var style: FaceStyle = .standard

    init(date: Date, snapshot: Snapshot?, project: ProjectUsage?,
         scopeLabel: String?, problem: WidgetProblem? = nil) {
        self.date = date
        self.snapshot = snapshot
        self.project = project
        self.scopeLabel = scopeLabel
        self.problem = problem
    }
}

struct UsageProvider: AppIntentTimelineProvider {
    /// The face this widget kind renders when Edit Widget hasn't picked one —
    /// each gallery entry carries its own, so its preview and a freshly added
    /// widget both wear the advertised look.
    var style: FaceStyle = .standard

    func placeholder(in context: Context) -> UsageEntry {
        var entry = UsageEntry(date: Date(), snapshot: .preview, project: nil, scopeLabel: nil)
        entry.style = style
        return entry
    }

    func snapshot(for configuration: UsageConfigIntent, in context: Context) async -> UsageEntry {
        // The widget gallery shows this, and it must look populated there even
        // when the host app has never run.
        context.isPreview ? placeholder(in: context) : entry(for: configuration)
    }

    func timeline(for configuration: UsageConfigIntent, in context: Context) async -> Timeline<UsageEntry> {
        // The host app pushes reloads as it polls, which is the real update path.
        // This is only the fallback for when it isn't running.
        Timeline(entries: [entry(for: configuration)],
                 policy: .after(Date().addingTimeInterval(delay(for: configuration))))
    }

    /// This widget's own choice, else whatever the app says it polls at, else the
    /// fifteen minutes this was fixed at before either existed.
    ///
    /// ponytail: floored at five minutes, and that floor is why the picker starts
    /// there. WidgetKit budgets macOS reloads and quietly ignores anything
    /// tighter, so offering a minute would be a control that lies.
    private func delay(for configuration: UsageConfigIntent) -> TimeInterval {
        let chosen = RefreshOptions.choices
            .first { $0.label == configuration.refresh }?.seconds ?? 0
        guard chosen == 0 else { return chosen }

        let app = SnapshotBundle.read()?.refreshSeconds
        return max(300, TimeInterval(app ?? 900))
    }

    private func entry(for configuration: UsageConfigIntent) -> UsageEntry {
        var entry = scoped(for: configuration)
        // Same empty-as-unset treatment as the pickers in scoped(for:) — a
        // cleared Style falls back to this kind's own face, not to Default.
        let chosen = configuration.style.flatMap { $0.isEmpty ? nil : $0 }
        entry.style = chosen.map { FaceStyle(label: $0) } ?? style
        return entry
    }

    private func scoped(for configuration: UsageConfigIntent) -> UsageEntry {
        // Empty strings can come back from a cleared picker; treat them as unset.
        let wantedProfile = configuration.profile.flatMap { $0.isEmpty ? nil : $0 }
        let wantedProject = configuration.project.flatMap { $0.isEmpty ? nil : $0 }

        guard let bundle = SnapshotBundle.read() else {
            // An older host writes only state.json. Honouring that for an
            // unconfigured widget is right; doing it for a configured one would
            // render the wrong account under the right label.
            guard wantedProfile == nil, wantedProject == nil else {
                return UsageEntry(date: Date(), snapshot: nil, project: nil,
                                  scopeLabel: nil, problem: .noData)
            }
            return UsageEntry(date: Date(), snapshot: Snapshot.read(),
                              project: nil, scopeLabel: nil)
        }

        let profile: Profile?
        let snapshot: Snapshot?
        if let wantedProfile {
            guard let match = bundle.snapshot(forExactly: wantedProfile) else {
                // Configured for an account this bundle doesn't have — the
                // folder moved, or was removed in Settings.
                return UsageEntry(date: Date(), snapshot: nil, project: nil,
                                  scopeLabel: bundle.profile(forExactly: wantedProfile)?.displayName
                                      ?? (wantedProfile as NSString).lastPathComponent,
                                  problem: .profileMissing)
            }
            profile = bundle.profile(forExactly: wantedProfile)
            snapshot = match
        } else {
            profile = bundle.defaultProfile
            snapshot = bundle.defaultSnapshot
        }

        let showsProfile = bundle.profileList.count > 1

        guard let wantedProject else {
            return UsageEntry(date: Date(), snapshot: snapshot, project: nil,
                              scopeLabel: showsProfile ? profile?.displayName : nil)
        }

        // A project with no activity this week is a real answer — zero — so
        // long as the account it belongs to did resolve.
        let project = snapshot?.stats.projects.first { $0.name == wantedProject }
            ?? ProjectUsage(name: wantedProject)
        let scope = showsProfile
            ? "\(profile?.displayName ?? "") · \(wantedProject)"
            : wantedProject
        return UsageEntry(date: Date(), snapshot: snapshot, project: project, scopeLabel: scope)
    }
}

struct UsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        UsageWidgetView(snapshot: entry.snapshot,
                        project: entry.project,
                        scopeLabel: entry.scopeLabel,
                        problem: entry.problem,
                        face: Face(family),
                        style: entry.style)
            .containerBackground(for: .widget) { entry.style.backdrop }
    }
}

/// One gallery entry. Every kind shares the same intent and provider — see
/// docs/adr/0001 — so a placed widget of any kind survives updates the same way,
/// and the Style picker can still override the kind's default face.
private func usageConfiguration(kind: String, style: FaceStyle, name: String,
                                description: String) -> some WidgetConfiguration {
    AppIntentConfiguration(kind: kind,
                           intent: UsageConfigIntent.self,
                           provider: UsageProvider(style: style)) { entry in
        UsageWidgetEntryView(entry: entry)
    }
    .configurationDisplayName(name)
    .description(description)
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
}

// Every kind below is frozen the moment a user places one: neither the kind
// string nor the configuration type can change again. The original was a
// StaticConfiguration until 0.3, and every widget placed before then is
// permanently dead — WidgetKit answers its timeline request with "Intent
// configuration is required but was not provided" instead of rendering, and
// there is no supported migration. Parameter *types* are equally one-way: the
// 0.3.1 → 0.3.2 ProfileEntity → String change made old selections unreadable,
// so they silently came back nil.

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        usageConfiguration(kind: "com.saeedkolivand.claude-usage.widget",
                           style: .standard, name: "Claude Usage",
                           description: "Session and weekly limits, tokens, and estimated cost.")
    }
}

// One struct per style rather than one parameterized struct: `Widget` requires
// a parameterless `init()`, so the style can't be passed in.

struct TerminalWidget: Widget {
    var body: some WidgetConfiguration {
        usageConfiguration(kind: "com.saeedkolivand.claude-usage.widget.terminal",
                           style: .terminal, name: "Terminal",
                           description: "Phosphor terminal readout of your Claude limits.")
    }
}

struct SpeedometerWidget: Widget {
    var body: some WidgetConfiguration {
        usageConfiguration(kind: "com.saeedkolivand.claude-usage.widget.speedometer",
                           style: .speedometer, name: "Speedometer",
                           description: "Analog dials for the session and weekly windows.")
    }
}

struct LCDWidget: Widget {
    var body: some WidgetConfiguration {
        usageConfiguration(kind: "com.saeedkolivand.claude-usage.widget.lcd",
                           style: .lcd, name: "LCD",
                           description: "Seven-segment readout of your Claude limits.")
    }
}

struct GlassWidget: Widget {
    var body: some WidgetConfiguration {
        usageConfiguration(kind: "com.saeedkolivand.claude-usage.widget.glass",
                           style: .glass, name: "Glass",
                           description: "Frosted card with your limit rings.")
    }
}

struct HeatmapWidget: Widget {
    var body: some WidgetConfiguration {
        usageConfiguration(kind: "com.saeedkolivand.claude-usage.widget.heatmap",
                           style: .heatmap, name: "Heatmap",
                           description: "Thirteen weeks of daily usage as a calendar grid.")
    }
}

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        TerminalWidget()
        SpeedometerWidget()
        LCDWidget()
        GlassWidget()
        HeatmapWidget()
    }
}

extension Face {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemLarge: self = .large
        default:           self = .medium
        }
    }
}
