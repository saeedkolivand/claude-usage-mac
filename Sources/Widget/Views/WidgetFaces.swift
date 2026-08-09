import SwiftUI

/// Deliberately not `WidgetFamily`: keeping WidgetKit out of these views lets the
/// snapshot tests render them without linking an app extension.
enum Face: String, CaseIterable {
    case small, medium, large

    /// Points, at 1x. WidgetKit's macOS system family sizes.
    var size: CGSize {
        switch self {
        case .small:  return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 364, height: 170)
        case .large:  return CGSize(width: 364, height: 382)
        }
    }
}

/// The widget body for every family. Split out from the `@main` entry point so
/// the snapshot tests can render these without linking an app extension.
/// Why a widget can't show what it was configured to show.
enum WidgetProblem {
    case noData
    case profileMissing

    var headline: String {
        switch self {
        case .noData:         return "Open Claude Usage"
        case .profileMissing: return "Profile not found"
        }
    }

    var detail: String {
        switch self {
        case .noData:
            return "The menu bar app supplies the data"
        case .profileMissing:
            return "Pick another in Edit Widget"
        }
    }
}

struct UsageWidgetView: View {
    let snapshot: Snapshot?
    /// Set when this widget is scoped to a single project.
    var project: ProjectUsage?
    var scopeLabel: String?
    var problem: WidgetProblem?
    let face: Face

    var body: some View {
        Group {
            if let problem {
                unavailable(problem)
            } else if let project {
                projectFace(project)
            } else if let snapshot {
                VStack(spacing: face == .small ? 6 : 10) {
                    scopeHeader
                    switch face {
                    case .small:  small(snapshot)
                    case .medium: medium(snapshot)
                    case .large:  large(snapshot)
                    }
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only drawn when the widget is scoped to something — a single-profile,
    /// whole-account widget gets no extra chrome.
    @ViewBuilder
    private var scopeHeader: some View {
        if let scopeLabel {
            Text(scopeLabel)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Project scope

    /// No gauges here on purpose: the 5-hour and weekly percentages are
    /// account-level, so there is no such thing as a project's limit.
    private func projectFace(_ project: ProjectUsage) -> some View {
        VStack(alignment: .leading, spacing: face == .small ? 6 : 10) {
            scopeHeader

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.tokens(project.todayTokens))
                    .font(.system(size: face == .small ? 30 : 36,
                                  weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(Format.cost(project.todayCost))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("TODAY")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            if face != .small {
                Divider()
                StatRow(label: "This week", tokens: project.tokens, cost: project.cost)
            }

            if face == .large {
                share(project)
                Spacer(minLength: 0)
                if !project.days.isEmpty {
                    SectionLabel(text: "LAST 7 DAYS")
                    // Seven, not fourteen: per-project days are recomputed from
                    // the scan window rather than persisted like account history.
                    HistoryChart(days: project.days, height: 56)
                }
            } else if face != .small {
                Spacer(minLength: 0)
            }
        }
    }

    /// How much of the account's week went here. Only meaningful alongside the
    /// account total, which is why it is large-only.
    @ViewBuilder
    private func share(_ project: ProjectUsage) -> some View {
        if let total = snapshot?.stats.weekTokens, total > 0 {
            let fraction = min(Double(project.tokens) / Double(total), 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("SHARE OF THIS WEEK")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Level.ok.tint.opacity(0.15))
                        Capsule().fill(Level.ok.tint)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 5)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Families

    private func small(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 8) {
            RingGauge(pct: snapshot.sessionPct,
                      level: snapshot.level(.session),
                      lineWidth: 11)
            VStack(spacing: 2) {
                Text(Metric.session.label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(resets(snapshot, .session))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            staleMark(snapshot)
        }
    }

    private func medium(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 20) {
            MetricGauge(snapshot: snapshot, metric: .session, lineWidth: 10)
            MetricGauge(snapshot: snapshot, metric: .weekly, lineWidth: 10)
            VStack(alignment: .leading, spacing: 7) {
                stat("TODAY", snapshot.stats.todayTokens, snapshot.stats.todayCost)
                stat("WEEK", snapshot.stats.weekTokens, snapshot.stats.weekCost)
                staleMark(snapshot)
                age(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func large(_ snapshot: Snapshot) -> some View {
        VStack(spacing: 16) {
            // Expands to whatever is left after the stats, so the rings grow to
            // fill the family rather than leaving dead space above and below.
            HStack(spacing: 26) {
                MetricGauge(snapshot: snapshot, metric: .session, lineWidth: 12)
                MetricGauge(snapshot: snapshot, metric: .weekly, lineWidth: 12)
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 9) {
                StatRow(label: "Today", tokens: snapshot.stats.todayTokens,
                        cost: snapshot.stats.todayCost)
                Divider()
                StatRow(label: "This week", tokens: snapshot.stats.weekTokens,
                        cost: snapshot.stats.weekCost)
                Divider()
                StatRow(label: "Session", tokens: snapshot.stats.sessionTokens,
                        cost: snapshot.stats.sessionCost)
            }

            if !snapshot.stats.days.isEmpty {
                HistoryChart(days: Array(snapshot.stats.days.suffix(14)), height: 30)
            }
            staleMark(snapshot)
            age(snapshot)
        }
    }

    // MARK: - Pieces

    private func stat(_ label: String, _ tokens: Int, _ cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text(Format.tokens(tokens))
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(Format.cost(cost))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func resets(_ snapshot: Snapshot, _ metric: Metric) -> String {
        let text = Format.until(snapshot.resetsAt(metric))
        return text.isEmpty ? "—" : "resets \(text)"
    }

    /// The widget can't fix a failed refresh itself — the host app owns that — so
    /// this says the numbers are old rather than offering an action.
    @ViewBuilder
    private func staleMark(_ snapshot: Snapshot) -> some View {
        if snapshot.error != nil {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(snapshot.stale ? "outdated" : "no update")
            }
            .font(.system(size: 9))
            .foregroundStyle(Level.warn.tint)
        }
    }

    /// How old these numbers are.
    ///
    /// `Text(_:style:)` keeps counting inside an already-rendered widget with no
    /// timeline reload, so this is the one thing on the face that stays true when
    /// everything around it has frozen. Without it, 0.3.9's dead widget spent two
    /// days showing confident percentages and a countdown stopped mid-air, with
    /// nothing on screen to say so.
    private func age(_ snapshot: Snapshot) -> some View {
        // Two views, not one concatenated Text: only a Text that *is* the date
        // is guaranteed to keep ticking on its own.
        HStack(spacing: 3) {
            Text("updated")
            Text(snapshot.updatedAt, style: .relative)
                .monospacedDigit()
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private var empty: some View {
        unavailable(.noData)
    }

    /// Says what went wrong rather than rendering another account's numbers,
    /// which would look like the widget working and be wrong.
    private func unavailable(_ problem: WidgetProblem) -> some View {
        VStack(spacing: 6) {
            Image(systemName: problem == .profileMissing
                  ? "questionmark.folder" : "chart.pie")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(problem.headline)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
            if let scopeLabel {
                Text(scopeLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(problem.detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }
}
