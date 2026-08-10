import SwiftUI

struct MenuView: View {
    let snapshot: Snapshot?
    let isRefreshing: Bool
    var update: ReleaseInfo?
    /// Zero means no target set, which is the default and draws nothing. Passed
    /// in rather than read from `@AppStorage` here so the snapshot tests can
    /// render both states without a defaults domain.
    var dailyBudget: Double = 0
    var monthlyBudget: Double = 0
    var refresh: () -> Void = {}
    /// False renders the informational content only. ImageRenderer draws
    /// interactive controls as unavailable and reads the version from whatever
    /// bundle it's hosted in, so the marketing shots would otherwise show
    /// prohibition badges and the test runner's version number.
    var showsActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot {
                // Only present when the machine has more than one profile — the
                // ordinary case gets no extra chrome.
                if let label = snapshot.profileLabel {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle")
                        Text(label).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
                }
                gauges(snapshot)
                burn(snapshot)
                perModel(snapshot)
                Divider().padding(.vertical, 10)
                stats(snapshot)
                budgets(snapshot)

                // Only worth a section when there is more than one to compare —
                // a single-model week is the week total said twice.
                if snapshot.stats.models.count > 1 {
                    Divider().padding(.vertical, 10)
                    SectionLabel(text: "BY MODEL")
                        .padding(.bottom, 5)
                    VStack(spacing: 5) {
                        ForEach(snapshot.stats.models) { model in
                            StatRow(label: model.name, tokens: model.tokens, cost: model.cost)
                        }
                    }
                }

                // Hidden rather than shown empty: before the first scan there is
                // no history, and a heading over blank space reads as broken.
                if !snapshot.stats.days.isEmpty {
                    Divider().padding(.vertical, 10)
                    SectionLabel(text: "LAST 13 WEEKS")
                        .padding(.bottom, 5)
                    // The heatmap's last two columns are the fortnight of bars
                    // this used to draw, in less width — so it replaces rather
                    // than joins them, and the popover doesn't grow a second chart.
                    Heatmap(days: Array(snapshot.stats.days.suffix(91)))
                }

                Divider().padding(.vertical, 10)
                SectionLabel(text: "BUSIEST PROJECTS")
                    .padding(.bottom, 5)
                ProjectList(projects: snapshot.stats.projects)

                if let message = snapshot.errorMessage {
                    Divider().padding(.vertical, 10)
                    banner(message, stale: snapshot.stale)
                }
                Divider().padding(.vertical, 10)
                footer(snapshot)
            } else {
                loading
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func gauges(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 18) {
            MetricGauge(snapshot: snapshot, metric: .session, lineWidth: 9)
            MetricGauge(snapshot: snapshot, metric: .weekly, lineWidth: 9)
        }
        .frame(height: 118)
    }

    /// The projection, when there is one. Two polls of active use before it says
    /// anything, and silent again the moment the window resets first.
    @ViewBuilder
    private func burn(_ snapshot: Snapshot) -> some View {
        if let summary = snapshot.burnSummary() {
            HStack(spacing: 4) {
                Image(systemName: "flame")
                Text(summary)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    /// Per-model weekly windows, on the plans that report them.
    @ViewBuilder
    private func perModel(_ snapshot: Snapshot) -> some View {
        let limits = snapshot.perModelLimits
        if !limits.isEmpty {
            VStack(spacing: 5) {
                ForEach(limits, id: \.self) { metric in
                    LimitRow(snapshot: snapshot, metric: metric)
                }
            }
            .padding(.top, 10)
        }
    }

    /// Only the targets that were actually set. Both unset is the default, and
    /// draws nothing at all.
    @ViewBuilder
    private func budgets(_ snapshot: Snapshot) -> some View {
        if dailyBudget > 0 || monthlyBudget > 0 {
            VStack(spacing: 7) {
                if dailyBudget > 0 {
                    BudgetRow(label: "Today's budget", spent: snapshot.stats.todayCost,
                              target: dailyBudget,
                              warn: snapshot.warn, critical: snapshot.critical)
                }
                if monthlyBudget > 0 {
                    BudgetRow(label: "This month", spent: snapshot.monthToDateCost(),
                              target: monthlyBudget,
                              warn: snapshot.warn, critical: snapshot.critical)
                }
            }
            .padding(.top, 9)
        }
    }

    private func stats(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 5) {
            StatRow(label: "Today", tokens: snapshot.stats.todayTokens,
                    cost: snapshot.stats.todayCost)
            StatRow(label: "This week", tokens: snapshot.stats.weekTokens,
                    cost: snapshot.stats.weekCost)
            StatRow(label: "Session", tokens: snapshot.stats.sessionTokens,
                    cost: snapshot.stats.sessionCost)
            if !snapshot.stats.ok {
                Text("~/.claude/projects not readable")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func banner(_ message: String, stale: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Level.warn.tint)
            Text(stale ? "\(message) — showing older numbers" : message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
    }

    // ponytail: text buttons, not an icon row — it's what menu bar apps
    // conventionally do, and it reads without a tooltip.
    private func footer(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(showsActions
                 ? "\(Self.updated(snapshot.updatedAt)) · v\(AppVersion.current)"
                 : Self.updated(snapshot.updatedAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            if let update {
                Link(destination: update.url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Version \(update.version) available")
                    }
                    .font(.system(size: 10, weight: .medium))
                }
            }

            if showsActions {
                HStack(spacing: 14) {
                    Button("Refresh", action: refresh)
                        .disabled(isRefreshing)
                    SettingsLink { Text("Settings…") }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // The first transcript scan reads everything in the 7-day window,
            // which is gigabytes on an active machine.
            Text("Reading usage…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// RelativeDateTimeFormatter renders a zero interval as "in 0 sec.", which
    /// reads as a bug on a snapshot that was just taken. Anything inside the
    /// poll interval is "just now" anyway.
    static func updated(_ date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        guard age >= 60 else { return "Updated just now" }
        return "Updated \(relative.localizedString(for: date, relativeTo: now))"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
