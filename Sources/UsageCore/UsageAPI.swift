import Foundation

public struct UsageNode: Codable, Sendable, Equatable {
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct UsageData: Codable, Sendable, Equatable {
    public var fiveHour: UsageNode?
    public var sevenDay: UsageNode?
    /// Per-model weekly windows. Plans without them report null, so nil here
    /// means "this account has no separate Opus limit" rather than "the fetch
    /// failed" — which is why nothing renders a placeholder for them.
    public var sevenDayOpus: UsageNode?
    public var sevenDaySonnet: UsageNode?
    /// Purchased extra usage, on accounts that have any. Parsed with the same
    /// shape as the rest and simply absent when it doesn't fit — the endpoint is
    /// undocumented and this field is the newest of them.
    public var extraUsage: UsageNode?

    public init(fiveHour: UsageNode?, sevenDay: UsageNode?,
                sevenDayOpus: UsageNode? = nil, sevenDaySonnet: UsageNode? = nil,
                extraUsage: UsageNode? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
    }
}

public struct FetchResult: Sendable {
    public var data: UsageData?
    public var error: String?
    public var stale: Bool

    public init(data: UsageData?, error: String? = nil, stale: Bool = false) {
        self.data = data
        self.error = error
        self.stale = stale
    }
}

/// One per profile. Deliberately not a singleton: the cache below is
/// single-slot, so sharing one across profiles would serve whichever account
/// fetched most recently to whoever asked next.
public actor UsageAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let defaultUserAgent = "claude-code/2.0.31"

    private static let cacheTTL: TimeInterval = 55

    /// How stale on-screen numbers may get before we say so. Age-based on
    /// purpose: during an outage every consumer retries, so counting failures
    /// would scale with the number of consumers rather than elapsed time.
    ///
    /// Set per fetch from the caller's poll interval rather than fixed, because
    /// "stale" has to mean the same thing at every interval — three polls old.
    /// A fixed 180s would call one-poll-old numbers outdated the moment someone
    /// picked a five-minute refresh.
    private var staleAfter: TimeInterval = 180

    private var cached: UsageData?
    private var cachedAt: Date = .distantPast

    /// After a failure, serve the cache for a full window instead of retrying.
    /// Without this a failure *raises* the request rate — every redraw fires its
    /// own retry exactly when the API is asking for less. Manual refresh
    /// (`force`) still bypasses it.
    private var lastFailAt: Date = .distantPast
    private var lastFailError: String?

    private let profile: Profile

    public init(profile: Profile) {
        self.profile = profile
    }

    private var isStale: Bool {
        cached != nil && Date().timeIntervalSince(cachedAt) > staleAfter
    }

    public func fetch(userAgent: String = defaultUserAgent, force: Bool = false,
                      staleAfter: TimeInterval = 180) async -> FetchResult {
        let now = Date()
        self.staleAfter = staleAfter

        if !force, cached != nil, now.timeIntervalSince(cachedAt) < Self.cacheTTL {
            return FetchResult(data: cached)
        }
        if !force, let err = lastFailError, now.timeIntervalSince(lastFailAt) < Self.cacheTTL {
            return FetchResult(data: cached, error: err, stale: isStale)
        }

        let creds = CredentialStore.read(for: profile)
        guard let token = creds.token else { return fail("no-token") }
        // An already-expired token guarantees a 401 — skip the request and wait
        // for Claude Code to write a refreshed one.
        guard !creds.expired else { return fail("token-expired") }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Load-bearing: without a claude-code User-Agent the endpoint serves an
        // aggressively rate-limited bucket and returns persistent 429s.
        request.setValue(userAgent.isEmpty ? Self.defaultUserAgent : userAgent,
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return fail("http-\(status)") }
            guard let parsed = Self.parse(body) else { return fail("bad-json") }

            cached = parsed
            cachedAt = now
            lastFailError = nil
            return FetchResult(data: parsed)
        } catch {
            return fail("network")
        }
    }

    private func fail(_ error: String) -> FetchResult {
        lastFailAt = Date()
        lastFailError = error
        return FetchResult(data: cached, error: error, stale: isStale)
    }

    /// Hand-parsed rather than Codable: the endpoint is undocumented and may grow
    /// or drop fields, and a strict decoder would turn that into a hard failure.
    static func parse(_ body: Data) -> UsageData? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        func node(_ key: String) -> UsageNode? {
            guard let raw = root[key] as? [String: Any],
                  let pct = (raw["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageNode(utilization: pct, resetsAt: parseDate(raw["resets_at"]))
        }
        let data = UsageData(fiveHour: node("five_hour"), sevenDay: node("seven_day"),
                             sevenDayOpus: node("seven_day_opus"),
                             sevenDaySonnet: node("seven_day_sonnet"),
                             extraUsage: node("extra_usage"))
        // A body with neither *account* window is not usable data. Per-model
        // windows alone don't qualify: they're absent on most plans, so treating
        // them as sufficient would accept a response that says nothing.
        return (data.fiveHour == nil && data.sevenDay == nil) ? nil : data
    }
}

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain = ISO8601DateFormatter()

func parseDate(_ value: Any?) -> Date? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}
