import Foundation

enum SettingsKey {
    static let warn = "warnThreshold"
    static let critical = "criticalThreshold"
    static let userAgent = "userAgent"
    static let menuBarMetric = "menuBarMetric"
    static let menuBarStyle = "menuBarStyle"
    static let menuBarAppearance = "menuBarAppearance"
    static let menuBarColorMode = "menuBarColorMode"
    static let menuBarCustomColor = "menuBarCustomColor"
    static let selectedProfile = "selectedProfile"
    static let autoSwitchProfile = "autoSwitchProfile"
    static let autoCheckUpdates = "autoCheckUpdates"
    static let refreshInterval = "refreshInterval"
    static let notifyThreshold = "notifyThreshold"
    static let dailyBudget = "dailyBudget"
    static let monthlyBudget = "monthlyBudget"
    static let hotkey = "hotkey"
}

/// How often the app polls. Seconds, because that is what the sleep takes.
///
/// A minute is the default and the floor: the usage endpoint is cached for 55
/// seconds anyway, so a tighter interval would re-read transcripts to redraw the
/// same numbers.
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case minute = 60
    case twoMinutes = 120
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }

    var label: String {
        rawValue == 60 ? "Every minute" : "Every \(rawValue / 60) minutes"
    }
}

/// What the menu bar's text says. The metric it says it about is a separate
/// setting, because the two are independent choices.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percentage
    case percentageAndReset
    case bothLimits

    var id: String { rawValue }

    var label: String {
        switch self {
        case .percentage:        return "Percentage"
        case .percentageAndReset: return "Percentage and reset"
        case .bothLimits:        return "Both limits"
        }
    }

    /// Shown under the picker so the choice is legible without applying it.
    var example: String {
        switch self {
        case .percentage:         return "42%"
        case .percentageAndReset: return "42% · 2h14m"
        case .bothLimits:         return "5H 42%  W 18%"
        }
    }
}

/// Text or a drawn form. Text is the default because macOS menu extras are
/// monochrome by convention — see MenuBarIcon for what the drawn ones cost.
enum MenuBarAppearance: String, CaseIterable, Identifiable {
    case text
    case ring
    case ringPercent
    case battery
    case bar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text:        return "Text"
        case .ring:        return "Ring"
        case .ringPercent: return "Ring + %"
        case .battery:     return "Battery"
        case .bar:         return "Bar"
        }
    }

    /// Everything but the text label is rendered as an NSImage.
    var isDrawn: Bool { self != .text }
}

/// How a drawn menu bar form is coloured. Text has no choice to make — a text
/// label is always a template.
enum MenuBarColorMode: String, CaseIterable, Identifiable {
    /// The existing green/amber/red bands.
    case threshold
    /// A template image, recoloured by the system like every other status item.
    case mono
    /// One fixed hex colour, whatever the number says.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .threshold: return "By usage"
        case .mono:      return "Match menu bar"
        case .custom:    return "Custom"
        }
    }
}
