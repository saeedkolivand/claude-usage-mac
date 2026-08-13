import SwiftUI

/// Thirteen weeks of daily tokens as a calendar grid — a week per column, a
/// weekday per row.
///
/// Complements `HistoryChart` rather than replacing it: bars answer "how much
/// yesterday", this answers "what does a month of my work look like". Same
/// palette, and still not Swift Charts — a grid of rectangles is the whole thing.
struct Heatmap: View {
    let days: [DayUsage]
    /// Cell height. Width stretches so the grid fills whatever row it's given.
    var box: CGFloat = 9
    var spacing: CGFloat = 2
    var tint: Color = Level.ok.tint

    /// Busiest day in range. Everything else is shaded relative to it, so a quiet
    /// quarter still shows shape instead of one bright square and twelve weeks of
    /// grey.
    private var peak: Int { max(days.map(\.tokens).max() ?? 0, 1) }

    /// Weeks, oldest first. Leading nils pad the first column so rows line up
    /// with real weekdays; trailing nils finish the last week.
    private var weeks: [[DayUsage?]] {
        guard let first = days.first else { return [] }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: first.day)
        let lead = (weekday - calendar.firstWeekday + 7) % 7

        var cells: [DayUsage?] = Array(repeating: nil, count: lead) + days.map { $0 }
        let remainder = cells.count % 7
        if remainder != 0 {
            cells += Array(repeating: nil, count: 7 - remainder)
        }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    var body: some View {
        // Built once here rather than read inside the loops — `weeks` walks the
        // whole quarter, and a nested ForEach would rebuild it 92 times.
        let grid = weeks

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: spacing) {
                ForEach(grid.indices, id: \.self) { column in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(fill(grid[column][row]))
                                .frame(maxWidth: .infinity)
                                .frame(height: box)
                        }
                    }
                }
            }
            if let first = days.first?.day, let last = days.last?.day {
                HStack {
                    Text(Self.short.string(from: first))
                    Spacer()
                    Text(Self.short.string(from: last))
                }
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            }
        }
        // One label for the grid, not 92 unreadable ones: VoiceOver reading out
        // every square in sequence would be worse than useless.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    /// Quartiles of the peak. Four steps is what reads at nine points — finer
    /// gradations are invisible, coarser ones lose the busy weeks.
    private func fill(_ day: DayUsage?) -> Color {
        guard let day, day.tokens > 0 else { return Level.none.tint.opacity(0.16) }
        let share = Double(day.tokens) / Double(peak)
        switch share {
        case ..<0.25: return tint.opacity(0.3)
        case ..<0.5:  return tint.opacity(0.5)
        case ..<0.75: return tint.opacity(0.75)
        default:      return tint
        }
    }

    private var summary: String {
        let active = days.filter { $0.tokens > 0 }.count
        let total = days.reduce(0) { $0 + $1.tokens }
        return "Activity over \(days.count) days: \(active) active, \(Format.tokens(total)) tokens"
    }

    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
