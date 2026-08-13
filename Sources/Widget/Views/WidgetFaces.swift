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

/// The look a placed widget was configured with. Stored in the intent as its
/// `label` string — see ConfigurationIntent for why not an enum parameter.
enum FaceStyle: String, CaseIterable {
    case standard, terminal, speedometer, lcd, glass, heatmap

    /// What the Edit Widget picker shows, and therefore what it stores.
    var label: String {
        switch self {
        case .standard:    return "Default"
        case .terminal:    return "Terminal"
        case .speedometer: return "Speedometer"
        case .lcd:         return "LCD"
        case .glass:       return "Glass"
        case .heatmap:     return "Heatmap"
        }
    }

    /// Anything unrecognised — including the nil an unconfigured widget sends —
    /// is the standard face, never a blank one.
    init(label: String?) {
        self = Self.allCases.first { $0.label == label } ?? .standard
    }

    /// The container background each style sits on. The snapshot tests compose
    /// the same backdrop so the PNGs match what WidgetKit shows.
    @ViewBuilder
    var backdrop: some View {
        switch self {
        case .terminal: Color(red: 0.04, green: 0.07, blue: 0.05)
        case .lcd:      Color(red: 0.15, green: 0.16, blue: 0.17)
        case .glass:    Rectangle().fill(.ultraThinMaterial)
        default:        Rectangle().fill(.fill.tertiary)
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
    /// Which look this widget was configured with. Project scope keeps the
    /// standard face regardless — the styles are built around the account
    /// gauges a project doesn't have.
    var style: FaceStyle = .standard

    var body: some View {
        Group {
            if let problem {
                unavailable(problem)
            } else if let project {
                projectFace(project)
            } else if let snapshot {
                if style == .standard {
                    VStack(spacing: face == .small ? 6 : 10) {
                        scopeHeader
                        switch face {
                        case .small:  small(snapshot)
                        case .medium: medium(snapshot)
                        case .large:  large(snapshot)
                        }
                    }
                } else {
                    styled(snapshot)
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func styled(_ snapshot: Snapshot) -> some View {
        switch style {
        case .standard:    EmptyView()
        case .terminal:    TerminalFace(snapshot: snapshot, face: face)
        case .speedometer: SpeedometerFace(snapshot: snapshot, face: face)
        case .lcd:         LCDFace(snapshot: snapshot, face: face)
        case .glass:       GlassFace(snapshot: snapshot, face: face)
        case .heatmap:     HeatmapFace(snapshot: snapshot, face: face)
        }
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
                MiniBar(fraction: fraction)
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
        VStack(spacing: 12) {
            // Expands to whatever is left after the stats, so the rings grow to
            // fill the family rather than leaving dead space above and below.
            HStack(spacing: 26) {
                MetricGauge(snapshot: snapshot, metric: .session, lineWidth: 12)
                MetricGauge(snapshot: snapshot, metric: .weekly, lineWidth: 12)
            }
            .frame(maxHeight: .infinity)

            burn(snapshot)
            perModel(snapshot)

            VStack(spacing: 8) {
                // Machine-scoped, unlike the account-wide rings above.
                SectionLabel(text: "THIS MAC")
                StatRow(label: "Today", tokens: snapshot.stats.todayTokens,
                        cost: snapshot.stats.todayCost)
                Divider()
                StatRow(label: "This week", tokens: snapshot.stats.weekTokens,
                        cost: snapshot.stats.weekCost)
                Divider()
                StatRow(label: "Session", tokens: snapshot.stats.sessionTokens,
                        cost: snapshot.stats.sessionCost)
            }

            // A quarter rather than the fortnight this used to draw: the last two
            // columns say what the bar chart said, and the eleven before them are
            // what a desktop widget has the room to be worth placing for.
            if !snapshot.stats.days.isEmpty {
                Heatmap(days: Array(snapshot.stats.days.suffix(91)), box: 8)
            }
            staleMark(snapshot)
            age(snapshot)
        }
    }

    // MARK: - Pieces

    /// Only ever drawn once a rate has actually been measured, which takes a
    /// couple of polls of active use — so most of the time this is nothing.
    @ViewBuilder
    private func burn(_ snapshot: Snapshot) -> some View {
        if let summary = snapshot.burnSummary() {
            HStack(spacing: 4) {
                Image(systemName: "flame")
                Text(summary)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// Per-model weekly windows, on the plans that have them. Absent everywhere
    /// else, which is why nothing reserves space for it.
    @ViewBuilder
    private func perModel(_ snapshot: Snapshot) -> some View {
        let limits = snapshot.perModelLimits
        if !limits.isEmpty {
            VStack(spacing: 5) {
                ForEach(limits, id: \.self) { metric in
                    LimitRow(snapshot: snapshot, metric: metric)
                }
            }
        }
    }

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

// MARK: - Styled faces
//
// Five looks beyond the standard one, chosen per widget in Edit Widget. All
// pure SwiftUI — no assets — and all reviewed the only way this project can
// review UI: through the rendered snapshots. Absolute colours (phosphor green,
// LCD cyan) are deliberate on the two dark faces, which carry their own
// backdrop in both colour schemes; the other three stay semantic.

/// Dev-terminal: monospaced phosphor text on near-black, ASCII bars.
private struct TerminalFace: View {
    let snapshot: Snapshot
    let face: Face

    private static let phosphor = Color(red: 0.25, green: 0.94, blue: 0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: face == .small ? 3 : 5) {
            HStack(spacing: 3) {
                Text("$ claude usage")
                    .foregroundStyle(Self.phosphor.opacity(0.8))
                // ponytail: static cursor — a widget render can't blink anyway.
                Rectangle()
                    .fill(Self.phosphor.opacity(0.7))
                    .frame(width: 6, height: fontSize)
            }
            row("5h", .session)
            row("wk", .weekly)
            if face == .large {
                ForEach(snapshot.perModelLimits, id: \.self) { metric in
                    row(String(metric.rawValue.prefix(2)), metric)
                }
            }
            if face != .small {
                line("resets \(resets)")
                line("today \(Format.tokens(snapshot.stats.todayTokens)) tok  \(Format.cost(snapshot.stats.todayCost))")
            }
            if face == .large {
                line("week  \(Format.tokens(snapshot.stats.weekTokens)) tok  \(Format.cost(snapshot.stats.weekCost))")
                if let burn = snapshot.burnSummary() { line("burn  \(burn)") }
            }
        }
        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fontSize: CGFloat { face == .small ? 10 : 12 }

    private var resets: String {
        let text = Format.until(snapshot.sessionResetsAt)
        return text.isEmpty ? "--" : text
    }

    private func line(_ text: String) -> some View {
        Text(text).foregroundStyle(Self.phosphor.opacity(0.65))
    }

    private func row(_ name: String, _ metric: Metric) -> some View {
        let level = snapshot.level(metric)
        let color: Color
        switch level {
        case .critical: color = Level.critical.tint
        case .warn:     color = Level.warn.tint
        default:        color = Self.phosphor
        }
        return Text("\(name) \(Self.ascii(snapshot.pct(metric))) \(Format.percent(snapshot.pct(metric)))")
            .foregroundStyle(color)
    }

    /// "[█████░░░░░]". Middle dots for no data, so it can't read as 0%.
    static func ascii(_ pct: Double?, slots: Int = 10) -> String {
        guard let pct else {
            return "[" + String(repeating: "·", count: slots) + "]"
        }
        let filled = Int((min(max(pct, 0), 100) / 100 * Double(slots)).rounded())
        return "[" + String(repeating: "█", count: filled)
            + String(repeating: "░", count: slots - filled) + "]"
    }
}

/// Analog gauge: the session needle sweeps 240°, red zone past the critical
/// threshold, weekly as a second dial where the family has room.
private struct SpeedometerFace: View {
    let snapshot: Snapshot
    let face: Face

    var body: some View {
        switch face {
        case .small:
            VStack(spacing: 2) {
                dial(.session)
                // The one family with a single dial still reads both windows.
                HStack(spacing: 4) {
                    Text("wk \(Format.percent(snapshot.weeklyPct))")
                        .foregroundStyle(snapshot.level(.weekly).tint)
                    Text("· resets \(Format.until(snapshot.sessionResetsAt))")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            }
        case .medium:
            HStack(spacing: 16) {
                dial(.session)
                dial(.weekly)
                // Compact stacks, not StatRows — three flexible columns leave
                // each a third of the face, and a StatRow truncates there.
                VStack(alignment: .leading, spacing: 7) {
                    miniStat("TODAY", snapshot.stats.todayTokens, snapshot.stats.todayCost)
                    miniStat("WEEK", snapshot.stats.weekTokens, snapshot.stats.weekCost)
                    caption
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .large:
            VStack(spacing: 12) {
                HStack(spacing: 26) {
                    dial(.session)
                    dial(.weekly)
                }
                .frame(maxHeight: .infinity)
                VStack(spacing: 8) {
                    StatRow(label: "Today", tokens: snapshot.stats.todayTokens,
                            cost: snapshot.stats.todayCost)
                    Divider()
                    StatRow(label: "This week", tokens: snapshot.stats.weekTokens,
                            cost: snapshot.stats.weekCost)
                }
                caption
            }
        }
    }

    private func dial(_ metric: Metric) -> some View {
        Dial(pct: snapshot.pct(metric), level: snapshot.level(metric),
             criticalPct: snapshot.critical, label: metric.label)
    }

    private func miniStat(_ label: String, _ tokens: Int, _ cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text("\(Format.tokens(tokens))  \(Format.cost(cost))")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var caption: some View {
        Text("resets \(Format.until(snapshot.sessionResetsAt))")
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}

/// The gauge itself: a 240° arc open at the bottom, ticks every 12.5%, a red
/// zone from the critical threshold to the end, and a needle.
private struct Dial: View {
    let pct: Double?
    let level: Level
    let criticalPct: Double
    var label: String?

    /// Degrees to rotate something drawn pointing up so it points at `fraction`
    /// along the sweep. The arc starts at 150° (clockwise from three o'clock)
    /// and covers 240°, leaving the gap at the bottom for the readout.
    private static func angle(_ fraction: Double) -> Double {
        240 + fraction * 240
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = max(3, side * 0.05)
            ZStack {
                arc(from: 0, to: 1)
                    .stroke(Level.none.tint.opacity(0.25),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .padding(stroke / 2)
                arc(from: min(criticalPct / 100, 1), to: 1)
                    .stroke(Level.critical.tint.opacity(0.75),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .padding(stroke / 2)
                ForEach(0..<9) { tick in
                    Capsule()
                        .fill(Level.none.tint.opacity(0.7))
                        .frame(width: 1.5, height: side * 0.06)
                        .offset(y: -side / 2 + stroke + side * 0.05)
                        .rotationEffect(.degrees(Self.angle(Double(tick) / 8)))
                }
                if let pct {
                    Capsule()
                        .fill(level.tint)
                        .frame(width: max(2, side * 0.03), height: side * 0.34)
                        .offset(y: -side * 0.17)
                        .rotationEffect(.degrees(Self.angle(min(max(pct / 100, 0), 1))))
                }
                Circle()
                    .fill(pct == nil ? Level.none.tint : level.tint)
                    .frame(width: side * 0.09, height: side * 0.09)
                VStack(spacing: 0) {
                    Text(Format.percent(pct))
                        .font(.system(size: side * 0.17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let label {
                        Text(label)
                            .font(.system(size: max(6, side * 0.07), weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                    }
                }
                .offset(y: side * 0.30)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arc(from: Double, to: Double) -> some Shape {
        Circle()
            .trim(from: from * 2 / 3, to: to * 2 / 3)
            .rotation(.degrees(150))
    }
}

/// Segmented-LCD multimeter: seven-segment digits on charcoal, cyan until the
/// warn threshold, amber past it, red past critical.
private struct LCDFace: View {
    let snapshot: Snapshot
    let face: Face

    private static let cyan = Color(red: 0.35, green: 0.9, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: face == .small ? 8 : 12) {
            switch face {
            case .small:
                field("5H", .session, height: 40)
                field("WK", .weekly, height: 22)
                caption("RST \(resets)")
            case .medium:
                HStack(alignment: .top, spacing: 26) {
                    field("5H", .session, height: 48)
                    field("WK", .weekly, height: 48)
                    VStack(alignment: .leading, spacing: 8) {
                        caption("RST \(resets)")
                        caption("TOK \(Format.tokens(snapshot.stats.todayTokens))")
                        caption("USD \(Format.cost(snapshot.stats.todayCost))")
                    }
                }
            case .large:
                HStack(alignment: .top, spacing: 30) {
                    field("5H", .session, height: 64)
                    field("WK", .weekly, height: 64)
                }
                ForEach(snapshot.perModelLimits, id: \.self) { metric in
                    field(metric.label, metric, height: 26)
                }
                caption("RST \(resets)")
                caption("TOK \(Format.tokens(snapshot.stats.todayTokens))  USD \(Format.cost(snapshot.stats.todayCost))")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: face == .small ? .topLeading : .center)
    }

    private var resets: String {
        let text = Format.until(snapshot.sessionResetsAt)
        return text.isEmpty ? "--" : text
    }

    private func color(_ level: Level) -> Color {
        switch level {
        case .warn:     return Level.warn.tint
        case .critical: return Level.critical.tint
        default:        return Self.cyan
        }
    }

    private func digits(_ pct: Double?) -> String {
        guard let pct else { return "--" }
        return String(Int(min(max(pct, 0), 999).rounded()))
    }

    private func field(_ label: String, _ metric: Metric, height: CGFloat) -> some View {
        let tint = color(snapshot.level(metric))
        return VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Self.cyan.opacity(0.55))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                LCDNumber(text: digits(snapshot.pct(metric)), color: tint, height: height)
                Text("%")
                    .font(.system(size: max(9, height * 0.32), design: .monospaced))
                    .foregroundStyle(tint.opacity(0.8))
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Self.cyan.opacity(0.65))
            .lineLimit(1)
    }
}

/// A number as a row of seven-segment digits.
private struct LCDNumber: View {
    let text: String  // digits and dashes only
    let color: Color
    let height: CGFloat

    var body: some View {
        HStack(spacing: height * 0.1) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                SegmentDigit(character: character, color: color)
            }
        }
        .frame(height: height)
    }
}

/// One seven-segment digit drawn from rounded rectangles — no font involved,
/// and the unlit segments ghost at low opacity the way a real LCD does.
private struct SegmentDigit: View {
    let character: Character
    let color: Color

    /// Bits 6...0 are segments a...g: top, then clockwise, middle last.
    private static let segments: [Character: UInt8] = [
        "0": 0b1111110, "1": 0b0110000, "2": 0b1101101, "3": 0b1111001,
        "4": 0b0110011, "5": 0b1011011, "6": 0b1011111, "7": 0b1110000,
        "8": 0b1111111, "9": 0b1111011, "-": 0b0000001,
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let t = w * 0.16
            let bits = Self.segments[character] ?? 0
            let vertical = h / 2 - 1.7 * t
            ZStack {
                seg(bits, 6, w: w - 2.4 * t, h: t).position(x: w / 2, y: t / 2)
                seg(bits, 5, w: t, h: vertical).position(x: w - t / 2, y: h * 0.27)
                seg(bits, 4, w: t, h: vertical).position(x: w - t / 2, y: h * 0.73)
                seg(bits, 3, w: w - 2.4 * t, h: t).position(x: w / 2, y: h - t / 2)
                seg(bits, 2, w: t, h: vertical).position(x: t / 2, y: h * 0.73)
                seg(bits, 1, w: t, h: vertical).position(x: t / 2, y: h * 0.27)
                seg(bits, 0, w: w - 2.4 * t, h: t).position(x: w / 2, y: h / 2)
            }
        }
        .aspectRatio(0.52, contentMode: .fit)
    }

    private func seg(_ bits: UInt8, _ bit: Int, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(w, h) / 2)
            .fill(color.opacity(bits & (1 << bit) != 0 ? 1 : 0.08))
            .frame(width: w, height: h)
    }
}

/// Glassmorphism: a frosted card over soft colour blobs tinted by the levels.
private struct GlassFace: View {
    let snapshot: Snapshot
    let face: Face

    var body: some View {
        ZStack {
            Circle()
                .fill(snapshot.level(.session).tint.opacity(0.55))
                .frame(width: 140, height: 140)
                .blur(radius: 38)
                .offset(x: face == .small ? -40 : -90, y: -40)
            Circle()
                .fill(snapshot.level(.weekly).tint.opacity(0.4))
                .frame(width: 120, height: 120)
                .blur(radius: 42)
                .offset(x: face == .small ? 45 : 95, y: 50)
            card
        }
    }

    private var card: some View {
        Group {
            switch face {
            case .small:
                VStack(spacing: 8) {
                    ring(.session, side: 52)
                    airy(Metric.session.label)
                    Text(Format.percent(snapshot.weeklyPct))
                        .font(.system(size: 12, weight: .light))
                        .monospacedDigit()
                    airy(Metric.weekly.label)
                }
            case .medium:
                HStack(spacing: 28) {
                    gauge(.session, side: 68)
                    gauge(.weekly, side: 68)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Format.tokens(snapshot.stats.todayTokens))
                            .font(.system(size: 20, weight: .ultraLight))
                            .monospacedDigit()
                        airy("TODAY")
                        Text("resets \(Format.until(snapshot.sessionResetsAt))")
                            .font(.system(size: 10, weight: .light))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            case .large:
                VStack(spacing: 18) {
                    HStack(spacing: 34) {
                        gauge(.session, side: 92)
                        gauge(.weekly, side: 92)
                    }
                    VStack(spacing: 8) {
                        glassRow("Today", snapshot.stats.todayTokens, snapshot.stats.todayCost)
                        glassRow("This week", snapshot.stats.weekTokens, snapshot.stats.weekCost)
                    }
                    Text("resets \(Format.until(snapshot.sessionResetsAt))")
                        .font(.system(size: 11, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(face == .small ? 14 : 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }

    private func ring(_ metric: Metric, side: CGFloat) -> some View {
        RingGauge(pct: snapshot.pct(metric), level: snapshot.level(metric), lineWidth: 3)
            .frame(width: side, height: side)
    }

    private func gauge(_ metric: Metric, side: CGFloat) -> some View {
        VStack(spacing: 6) {
            ring(metric, side: side)
            airy(metric.label)
        }
    }

    private func airy(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .light))
            .tracking(2)
            .foregroundStyle(.secondary)
    }

    private func glassRow(_ label: String, _ tokens: Int, _ cost: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .light))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(Format.tokens(tokens))  \(Format.cost(cost))")
                .font(.system(size: 11, weight: .regular))
                .monospacedDigit()
        }
        .frame(maxWidth: 200)
    }
}

/// The 13-week heatmap as the whole face, with the two limits as corner chips.
private struct HeatmapFace: View {
    let snapshot: Snapshot
    let face: Face

    private var box: CGFloat {
        switch face {
        case .small:  return 9
        case .medium: return 14
        case .large:  return 21
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if snapshot.stats.days.isEmpty {
                    Text("No history yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Heatmap(days: Array(snapshot.stats.days.suffix(91)), box: box)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 4) {
                chip(.session)
                chip(.weekly)
            }
        }
    }

    private func chip(_ metric: Metric) -> some View {
        let level = snapshot.level(metric)
        return Text("\(metric.initial.lowercased()) \(Format.percent(snapshot.pct(metric)))")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(level.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(level.tint.opacity(0.16), in: Capsule())
    }
}
