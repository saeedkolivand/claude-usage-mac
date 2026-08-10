import SwiftUI

// Same palette as the Stream Deck plugin, so the two products read identically.
extension Level {
    var tint: Color {
        switch self {
        case .none:     return Color(red: 0.42, green: 0.45, blue: 0.50)  // #6b7280
        case .ok:       return Color(red: 0.13, green: 0.77, blue: 0.37)  // #22c55e
        case .warn:     return Color(red: 0.96, green: 0.62, blue: 0.04)  // #f59e0b
        case .critical: return Color(red: 0.94, green: 0.27, blue: 0.27)  // #ef4444
        }
    }
}

/// Raw values are the stored setting, so a picker tag round-trips without a
/// second mapping table.
enum Metric: String, CaseIterable {
    case session
    case weekly
    case opus
    case sonnet

    var label: String {
        switch self {
        case .session: return "5 HOURS"
        case .weekly:  return "WEEKLY"
        case .opus:    return "OPUS"
        case .sonnet:  return "SONNET"
        }
    }

    /// Sentence case, for notifications and pickers — the all-caps `label` is a
    /// chart heading and reads as shouting anywhere else.
    var title: String {
        switch self {
        case .session: return "5-hour limit"
        case .weekly:  return "Weekly limit"
        case .opus:    return "Opus weekly limit"
        case .sonnet:  return "Sonnet weekly limit"
        }
    }

    /// For the menu bar, where a word costs more room than it earns.
    var initial: String {
        switch self {
        case .session: return "5H"
        case .weekly:  return "W"
        case .opus:    return "O"
        case .sonnet:  return "S"
        }
    }
}

extension Snapshot {
    func pct(_ metric: Metric) -> Double? {
        switch metric {
        case .session: return sessionPct
        case .weekly:  return weeklyPct
        case .opus:    return opusPct
        case .sonnet:  return sonnetPct
        }
    }

    func resetsAt(_ metric: Metric) -> Date? {
        switch metric {
        case .session: return sessionResetsAt
        case .weekly:  return weeklyResetsAt
        case .opus:    return opusResetsAt
        case .sonnet:  return sonnetResetsAt
        }
    }

    /// The per-model windows this account actually has. Empty on plans without
    /// them, which is why every caller renders it as a list rather than as two
    /// fixed rows with placeholders.
    var perModelLimits: [Metric] {
        [.opus, .sonnet].filter { pct($0) != nil }
    }

    /// "12%/h · full in 1h 20m", or just the rate when the window resets first.
    /// Nil whenever there is no measured rate — the ordinary case.
    func burnSummary(now: Date = Date()) -> String? {
        guard let rate = burnRatePerHour, rate > 0 else { return nil }
        let head = "\(Int(rate))%/h"
        guard let seconds = timeToFull(now: now) else { return head }
        return "\(head) · full in \(Format.until(now.addingTimeInterval(seconds), now: now))"
    }

    func level(_ metric: Metric) -> Level {
        Level.of(pct(metric), warn: warn, critical: critical)
    }

    /// Human-readable form of the error codes UsageCore reports.
    var errorMessage: String? {
        switch error {
        case nil:               return nil
        case "no-token":        return "Sign in with Claude Code"
        // Not "Claude Code will refresh it": it only refreshes the profile it is
        // running in, so on an idle config dir that promise never comes true.
        case "token-expired":   return "Token expired — use Claude Code in this profile to refresh"
        case "network":         return "No connection"
        case "bad-json":        return "Unexpected response"
        case let code?:
            return code.hasPrefix("http-") ? "API error \(code.dropFirst(5))" : code
        }
    }
}
