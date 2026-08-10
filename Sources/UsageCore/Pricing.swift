import Foundation

/// Dollars per single token (Anthropic list price / 1e6).
///
/// Cache multipliers relative to the input rate: read 0.1x, 5-minute write
/// 1.25x, 1-hour write 2x. The 1h rate matters — Claude Code writes almost
/// exclusively 1h cache entries, so collapsing both into the 5m rate (as the
/// Stream Deck plugin does) understates cache cost substantially.
public struct Rate: Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite5m: Double
    public let cacheWrite1h: Double
}

public enum ModelFamily: String, Sendable {
    case opus
    case opusLegacy
    case sonnet
    case haiku
    case unknown

    /// What a reader calls it. Opus 4.0/4.1 bill at the old rates but are still
    /// "Opus" on screen, so the two families share one row in the breakdown.
    public var label: String {
        switch self {
        case .opus, .opusLegacy: return "Opus"
        case .sonnet:            return "Sonnet"
        case .haiku:             return "Haiku"
        case .unknown:           return "Other"
        }
    }
}

public enum Pricing {
    public static let opus = Rate(
        input: 5 / 1e6, output: 25 / 1e6,
        cacheRead: 0.5 / 1e6, cacheWrite5m: 6.25 / 1e6, cacheWrite1h: 10 / 1e6)

    public static let opusLegacy = Rate(
        input: 15 / 1e6, output: 75 / 1e6,
        cacheRead: 1.5 / 1e6, cacheWrite5m: 18.75 / 1e6, cacheWrite1h: 30 / 1e6)

    public static let sonnet = Rate(
        input: 3 / 1e6, output: 15 / 1e6,
        cacheRead: 0.3 / 1e6, cacheWrite5m: 3.75 / 1e6, cacheWrite1h: 6 / 1e6)

    public static let haiku = Rate(
        input: 1 / 1e6, output: 5 / 1e6,
        cacheRead: 0.1 / 1e6, cacheWrite5m: 1.25 / 1e6, cacheWrite1h: 2 / 1e6)

    /// Reduce a logged model id to its pricing family.
    ///
    /// Version-agnostic on purpose so new releases within a family are picked up
    /// without a code change. Only Opus 4.0/4.1 carry the old, higher rates.
    public static func family(_ model: String) -> ModelFamily {
        let m = model.lowercased()
        if m.contains("opus") {
            // ponytail: literal digit classes, not version parsing. Breaks on a
            // hypothetical "opus-4-10"; Anthropic went 4.5 -> 4.8 -> 5, so the
            // day a two-digit minor ships, add it here.
            if m.matches("opus-4-[5-9]") { return .opus }
            if m.matches("opus-[5-9]") { return .opus }
            if m.matches("opus-[0-9]") { return .opusLegacy }
            return .opus  // bare "opus" alias -> whatever is current
        }
        if m.contains("sonnet") { return .sonnet }
        if m.contains("haiku") { return .haiku }
        return .unknown
    }

    public static func rate(for model: String) -> Rate {
        rate(family(model))
    }

    public static func rate(_ family: ModelFamily) -> Rate {
        switch family {
        case .opus: return opus
        case .opusLegacy: return opusLegacy
        case .haiku: return haiku
        case .sonnet: return sonnet
        case .unknown: return sonnet  // future family -> assume Sonnet-class
        }
    }

    /// Cost of one `message.usage` object.
    ///
    /// Claude Code no longer records a `costUSD` field, so this is the only
    /// source of cost. On Pro/Max plans it is notional equivalent API spend.
    public static func cost(usage: [String: Any], model: String) -> Double {
        cost(usage: usage, family: family(model))
    }

    /// Takes the family directly, so a caller that already classified the model
    /// doesn't pay for the regex twice — the scanner runs this over every entry
    /// of a multi-gigabyte archive.
    public static func cost(usage: [String: Any], family: ModelFamily) -> Double {
        let r = rate(family)
        var total =
            Double(intValue(usage["input_tokens"])) * r.input
            + Double(intValue(usage["output_tokens"])) * r.output
            + Double(intValue(usage["cache_read_input_tokens"])) * r.cacheRead

        // Prefer the TTL breakdown when present; fall back to the flat total at
        // the 5m rate for older logs that lack `cache_creation`.
        if let split = usage["cache_creation"] as? [String: Any] {
            total += Double(intValue(split["ephemeral_5m_input_tokens"])) * r.cacheWrite5m
            total += Double(intValue(split["ephemeral_1h_input_tokens"])) * r.cacheWrite1h
        } else {
            total += Double(intValue(usage["cache_creation_input_tokens"])) * r.cacheWrite5m
        }
        return total
    }
}

/// Tolerant number coercion — these fields are occasionally absent or doubles.
func intValue(_ v: Any?) -> Int {
    if let i = v as? Int { return i }
    if let d = v as? Double, d.isFinite { return Int(d) }
    if let n = v as? NSNumber { return n.intValue }
    return 0
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
