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

enum Metric {
    case session
    case weekly

    var label: String {
        switch self {
        case .session: return "5 HOURS"
        case .weekly:  return "WEEKLY"
        }
    }
}

extension Snapshot {
    func pct(_ metric: Metric) -> Double? {
        switch metric {
        case .session: return sessionPct
        case .weekly:  return weeklyPct
        }
    }

    func resetsAt(_ metric: Metric) -> Date? {
        switch metric {
        case .session: return sessionResetsAt
        case .weekly:  return weeklyResetsAt
        }
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
