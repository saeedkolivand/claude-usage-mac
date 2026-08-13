import SwiftUI

/// The percentage ring. Same shape at every size — only `lineWidth` and the
/// font scale change between the menu bar popover and the three widget families.
struct RingGauge: View {
    let pct: Double?
    let level: Level
    var lineWidth: CGFloat = 8
    var showsPercent = true
    /// Overrides the threshold tint — the menu bar's mono and custom colour
    /// modes. Nil, the only value anything else passes, keeps `level.tint`.
    var tint: Color?

    private var color: Color { tint ?? level.tint }

    private var fraction: CGFloat {
        guard let pct else { return 0 }
        return CGFloat(min(max(pct / 100, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Apple's widget rings run ~8-10% of their diameter. `lineWidth` is
            // a ceiling, not a promise: when a layout squeezes the ring (the
            // large face after the THIS MAC label landed), the stroke thins
            // with it instead of turning the ring into a donut.
            let stroke = min(lineWidth, side * 0.09)
            ZStack {
                // Strokes straddle the path, so without this inset the outer half
                // spills past the frame and gets clipped by the container.
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: stroke)
                    .padding(stroke / 2)
                if pct != nil {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(color,
                                style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(stroke / 2)
                }
                if showsPercent {
                    Text(Format.percent(pct))
                        // Scales with the ring so one view serves every widget family.
                        .font(.system(size: side * 0.28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(pct == nil ? Level.none.tint : .primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A ring with its metric name and reset countdown underneath.
struct MetricGauge: View {
    let snapshot: Snapshot
    let metric: Metric
    var lineWidth: CGFloat = 8

    var body: some View {
        VStack(spacing: 6) {
            RingGauge(pct: snapshot.pct(metric),
                      level: snapshot.level(metric),
                      lineWidth: lineWidth)
            VStack(spacing: 1) {
                Text(metric.label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(resets)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var resets: String {
        let text = Format.until(snapshot.resetsAt(metric))
        return text.isEmpty ? "—" : "resets \(text)"
    }
}

/// The one bar shape in the app: a tinted capsule over its own faded track.
/// Three views drew this separately before it was worth naming.
struct MiniBar: View {
    let fraction: Double
    var tint: Color = Level.ok.tint
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// A per-model weekly window as one line.
///
/// Not a ring: these only exist on some plans, so the layout has to survive them
/// being absent, and two more rings would not fit the popover or any widget
/// family below large.
struct LimitRow: View {
    let snapshot: Snapshot
    let metric: Metric

    var body: some View {
        HStack(spacing: 8) {
            Text(metric.label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            MiniBar(fraction: (snapshot.pct(metric) ?? 0) / 100,
                    tint: snapshot.level(metric).tint, height: 4)
            Text(Format.percent(snapshot.pct(metric)))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
            Text(Format.until(snapshot.resetsAt(metric)))
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

/// Spend against a target the user set. Only ever drawn when there is one — a
/// budget row reading "$3.40 of $0" would be worse than no row.
struct BudgetRow: View {
    let label: String
    let spent: Double
    let target: Double
    var warn: Double = 50
    var critical: Double = 80

    private var fraction: Double { target > 0 ? spent / target : 0 }
    private var level: Level {
        Level.of(fraction * 100, warn: warn, critical: critical)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Format.cost(spent)) of \(Format.cost(target))")
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .lineLimit(1)
            MiniBar(fraction: fraction, tint: level.tint, height: 4)
        }
    }
}

/// One "Today  1.2M  $3.40" line.
struct StatRow: View {
    let label: String
    let tokens: Int
    let cost: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(Format.tokens(tokens))
                .monospacedDigit()
            Text(Format.cost(cost))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // Fixed width keeps the cost column aligned across rows.
                .frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

extension Snapshot {
    /// Placeholder for widget galleries and snapshot tests.
    static var preview: Snapshot {
        var stats = LogStats()
        stats.todayTokens = 1_240_000
        stats.todayCost = 3.40
        stats.weekTokens = 8_430_000
        stats.weekCost = 24.10
        stats.sessionTokens = 341_000
        stats.sessionCost = 1.02
        let today = Calendar.current.startOfDay(for: Date())
        func recentDays(_ peak: Int) -> [DayUsage] {
            (0..<7).reversed().compactMap { offset in
                guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: today)
                else { return nil }
                let scale = [0.4, 0.9, 0.2, 1.0, 0.55, 0.0, 0.7][offset]
                return DayUsage(day: day, tokens: Int(Double(peak) * scale),
                                cost: Double(peak) * scale / 1e6 * 3)
            }
        }
        stats.projects = [
            ProjectUsage(name: "ai-job-hunter-assistant-app", tokens: 4_100_000, cost: 11.80,
                         todayTokens: 720_000, todayCost: 2.05, days: recentDays(900_000)),
            ProjectUsage(name: "claude-usage-streamdeck-plugin", tokens: 2_600_000, cost: 7.40,
                         todayTokens: 310_000, todayCost: 0.90, days: recentDays(600_000)),
            ProjectUsage(name: "tokensaver-streamdeck-plugin", tokens: 1_100_000, cost: 3.10,
                         todayTokens: 140_000, todayCost: 0.40, days: recentDays(300_000)),
            ProjectUsage(name: "dotfiles", tokens: 630_000, cost: 1.80),
        ]
        stats.models = [
            ModelUsage(name: "Opus", tokens: 6_100_000, cost: 19.40,
                       todayTokens: 910_000, todayCost: 2.70),
            ModelUsage(name: "Sonnet", tokens: 2_050_000, cost: 4.30,
                       todayTokens: 300_000, todayCost: 0.65),
            ModelUsage(name: "Haiku", tokens: 280_000, cost: 0.40,
                       todayTokens: 30_000, todayCost: 0.05),
        ]
        // Uneven, with idle days, so charts get reviewed against realistic shape
        // rather than a smooth ramp. Ninety-two days for the heatmap's quarter;
        // the final fortnight is byte-for-byte what it was before the heatmap
        // existed, so the bar chart's already-reviewed shape doesn't move.
        let older = (0..<78).map {
            [0, 310, 0, 1_900, 640, 2_400, 120, 0, 980, 1_500, 0, 2_100, 760][$0 % 13]
        }
        let daily = older
            + [820, 0, 1_400, 2_050, 640, 0, 0, 1_180, 3_400, 2_900, 410, 1_760, 2_240, 1_240]
        stats.days = daily.enumerated().compactMap { offset, thousands in
            guard let day = Calendar.current.date(
                byAdding: .day, value: offset - (daily.count - 1), to: today) else { return nil }
            return DayUsage(day: day, tokens: thousands * 1_000,
                            cost: Double(thousands) * 0.0029)
        }
        var snapshot = Snapshot(
            usage: UsageData(
                fiveHour: UsageNode(utilization: 42,
                                    resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
                sevenDay: UsageNode(utilization: 18,
                                    resetsAt: Date().addingTimeInterval(4 * 86400 + 6 * 3600)),
                sevenDayOpus: UsageNode(utilization: 61,
                                        resetsAt: Date().addingTimeInterval(4 * 86400 + 6 * 3600)),
                sevenDaySonnet: UsageNode(utilization: 12,
                                          resetsAt: Date().addingTimeInterval(4 * 86400 + 6 * 3600))),
            stats: stats)
        snapshot.burnRatePerHour = 9
        return snapshot
    }

    /// The same account on a plan with no per-model windows and no measured burn
    /// rate — the majority case, and the one the layout has to survive.
    static var previewPlain: Snapshot {
        var snapshot = preview
        snapshot.opusPct = nil
        snapshot.opusResetsAt = nil
        snapshot.sonnetPct = nil
        snapshot.sonnetResetsAt = nil
        snapshot.burnRatePerHour = nil
        return snapshot
    }
}
