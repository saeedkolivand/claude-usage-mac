import Foundation

/// Every profile's snapshot in one file.
///
/// Widgets are configured individually, so any of them may be scoped to any
/// profile — which means the host has to poll them all and publish them all.
/// `Snapshot` itself is unchanged: it stays the per-profile payload the views
/// already render, and this only wraps it.
public struct SnapshotBundle: Codable, Sendable, Equatable {
    public var updatedAt: Date
    /// Keyed by `Profile.id`, which is the config directory path.
    public var profiles: [String: Snapshot]
    /// Ordered, default first — the widget's configuration picker reads this
    /// rather than enumerating directories, which its sandbox forbids.
    public var profileList: [Profile]
    public var defaultProfileID: String?

    public init(updatedAt: Date = Date(),
                profiles: [String: Snapshot] = [:],
                profileList: [Profile] = [],
                defaultProfileID: String? = nil) {
        self.updatedAt = updatedAt
        self.profiles = profiles
        self.profileList = profileList
        self.defaultProfileID = defaultProfileID
    }

    /// Fills in the rings for a profile whose own token has expired, from a
    /// profile signed in to the same account whose fetch just succeeded.
    ///
    /// The usage endpoint is account-scoped, not config-dir-scoped, so those
    /// numbers are the same numbers — two config dirs on one account report
    /// identical utilization and identical reset times. Token *expiry* is not
    /// shared, though: Claude Code only refreshes the config dir it is running
    /// in, so a directory you have stopped using sits on hours-old rings for
    /// good. Its five-hour window elapses and the ring parks at "resets 0m"
    /// while a sibling shows the real countdown.
    ///
    /// Only `token-expired` borrows. `no-token` is left alone deliberately: that
    /// is also what a denied Keychain prompt looks like, and papering over it
    /// with someone else's numbers would hide a problem the user can actually
    /// fix.
    ///
    /// ponytail: identity is `email` + `organization`, both required non-nil.
    /// Both come from `.claude.json` on disk and are never checked against the
    /// token itself, so this trusts the config file. That is the strongest
    /// signal available without decoding tokens we deliberately never decode.
    public mutating func lendUsageBetweenSameAccountProfiles() {
        let donors = profileList.filter {
            guard let snapshot = profiles[$0.id] else { return false }
            return snapshot.error == nil && snapshot.sessionPct != nil
        }
        guard !donors.isEmpty else { return }

        for profile in profileList {
            guard let stuck = profiles[profile.id], stuck.error == "token-expired",
                  let email = profile.email, let organization = profile.organization,
                  let donor = donors.first(where: {
                      $0.email == email && $0.organization == organization
                  }),
                  let source = profiles[donor.id]
            else { continue }

            var lent = stuck
            lent.sessionPct = source.sessionPct
            lent.sessionResetsAt = source.sessionResetsAt
            lent.weeklyPct = source.weeklyPct
            lent.weeklyResetsAt = source.weeklyResetsAt
            // The numbers are now current and correct for this account, so the
            // warning would be describing a problem the user can no longer see.
            lent.error = nil
            lent.stale = false
            profiles[profile.id] = lent
            // Transcript stats are genuinely per-config-dir and are left as they
            // are — the two profiles really did log different token counts.
        }
    }

    /// Whether anything the widget actually draws has moved.
    ///
    /// `updatedAt` is stamped `Date()` on every poll whether or not a fetch
    /// succeeded, so a plain `!=` is always true — and reloading on that is the
    /// 1440 requests a day that put us over WidgetKit's reload budget. Reloads
    /// from a containing app are only budget-exempt while it is foreground, and
    /// an `LSUIElement` menu bar app never is.
    ///
    /// ponytail: an active session still moves the numbers most minutes, so this
    /// buys back the idle hours rather than capping the busy ones. If the budget
    /// still bites, floor it to one reload every five minutes — measured, not
    /// guessed.
    public func draws(differentlyFrom other: SnapshotBundle?) -> Bool {
        guard let other else { return true }
        return undated() != other.undated()
    }

    private func undated() -> SnapshotBundle {
        var copy = self
        copy.updatedAt = .distantPast
        copy.profiles = copy.profiles.mapValues {
            var snapshot = $0
            snapshot.updatedAt = .distantPast
            return snapshot
        }
        return copy
    }

    /// Exactly the named profile, or nil.
    ///
    /// Deliberately does not fall back: a widget configured for one account and
    /// quietly showing another's numbers is worse than one that says it can't
    /// find the account. Callers decide, because "unconfigured" and "configured
    /// but gone" deserve different answers.
    public func snapshot(forExactly profileID: String) -> Snapshot? {
        profiles[profileID]
    }

    public func profile(forExactly profileID: String) -> Profile? {
        profileList.first { $0.id == profileID }
    }

    public var defaultProfile: Profile? {
        profileList.first { $0.id == defaultProfileID } ?? profileList.first
    }

    public var defaultSnapshot: Snapshot? {
        defaultProfile.flatMap { profiles[$0.id] }
    }
}

extension SnapshotBundle {
    private static let filename = "bundle.json"

    /// Alongside the single-profile `state.json`, which stays as it is so an
    /// older widget build keeps working after the app updates.
    public static var locations: [URL] {
        Snapshot.locations.map {
            $0.deletingLastPathComponent().appendingPathComponent(filename)
        }
    }

    static var widgetContainer: URL? {
        Snapshot.widgetContainer?
            .deletingLastPathComponent()
            .appendingPathComponent(filename)
    }

    @discardableResult
    public func write() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return false }

        var wrote = false
        for url in Self.locations + [Self.widgetContainer].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: url, options: .atomic)) != nil { wrote = true }
        }
        return wrote
    }

    public static func read() -> SnapshotBundle? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (locations + [widgetContainer].compactMap { $0 })
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(SnapshotBundle.self, from: $0) }
            .max { $0.updatedAt < $1.updatedAt }
    }
}
