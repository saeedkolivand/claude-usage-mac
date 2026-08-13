import Foundation

/// Which profile the menu bar should *show* when the selected one runs out of
/// session. Display-only by design: it never touches credentials or the stored
/// selection — Poller just renders a different member of the bundle it already
/// polled.
///
/// Pure function so it can be tested without a Poller, a filesystem, or a clock.
public enum AutoSwitch {

    /// Returns the profile id to show instead of `selectedID`, or nil to show
    /// the selection itself.
    ///
    /// Latched via `current`, the override returned last poll: once switched,
    /// it stays on that profile — whatever its own numbers do — until the
    /// selected profile's five-hour window falls below `warn`, which is what a
    /// reset looks like. Re-picking the best candidate every poll would flap
    /// between two accounts that are both busy.
    public static func shownProfile(
        in bundle: SnapshotBundle,
        selectedID: String,
        current: String?,
        warn: Double,
        critical: Double
    ) -> String? {
        guard let own = bundle.profiles[selectedID], let ownPct = own.sessionPct
        else { return nil }  // no reading to judge by — show the selection

        if let current {
            // A profile that vanished from the bundle was removed in Settings.
            guard bundle.profiles[current] != nil else { return nil }
            return ownPct < warn ? nil : current
        }

        guard ownPct >= critical else { return nil }

        // Same account means the same account-scoped limits, so switching to a
        // sibling config dir would show the identical full window. Identity is
        // email + organization, both non-nil — the same trust the bundle's
        // usage-lending already places in `.claude.json`.
        let selected = bundle.profile(forExactly: selectedID)
        func sameAccount(_ profile: Profile) -> Bool {
            guard let email = selected?.email, let org = selected?.organization
            else { return false }
            return profile.email == email && profile.organization == org
        }

        let best = bundle.profileList
            .filter { $0.id != selectedID && !sameAccount($0) }
            .compactMap { profile -> (id: String, pct: Double)? in
                guard let snapshot = bundle.profiles[profile.id],
                      snapshot.error == nil, let pct = snapshot.sessionPct
                else { return nil }
                return (profile.id, pct)
            }
            .min { $0.pct < $1.pct }

        // A candidate no better off than the selection is not headroom.
        guard let best, best.pct < ownPct else { return nil }
        return best.id
    }
}
