import CryptoKit
import Foundation

public struct Credentials: Sendable, Equatable {
    public let token: String?
    public let expired: Bool

    public static let none = Credentials(token: nil, expired: false)
}

/// Reads the OAuth access token Claude Code already stored on this machine.
/// We never authenticate ourselves and never write credentials anywhere.
public enum CredentialStore {

    static let keychainBase = "Claude Code-credentials"

    /// File first, Keychain second — but an expired credential never wins over a
    /// live one behind it.
    ///
    /// The file branch used to return unconditionally, so a `.credentials.json`
    /// left behind from before Claude Code moved to the Keychain pinned that
    /// profile to `token-expired` for good: the live Keychain item was never
    /// reached. Same shape one level down, where the first service name that
    /// matched won even if the item under it was dead.
    ///
    /// ponytail: a profile whose credentials really have all expired now walks
    /// every candidate on each poll instead of stopping at the first. It only
    /// costs anything when something is already broken, and a `security` miss
    /// exits immediately without a dialog.
    public static func read(for profile: Profile) -> Credentials {
        var expiredFallback: Credentials?

        // Remembering the first expired candidate keeps the banner saying
        // "expired", which is true and actionable. Falling through to `.none`
        // would say "Sign in with Claude Code" at someone who already is.
        func usable(_ candidate: Credentials?) -> Credentials? {
            guard let candidate, candidate.token != nil else { return nil }
            if !candidate.expired { return candidate }
            if expiredFallback == nil { expiredFallback = candidate }
            return nil
        }

        if let live = usable(readFile(at: profile.credentialsFile)) { return live }
        for service in keychainServices(for: profile) {
            if let live = usable(readKeychain(service: service)) { return live }
        }
        return expiredFallback ?? .none
    }

    /// Keychain service names to try for a profile, most likely first.
    ///
    /// Claude Code namespaces its Keychain item per config dir —
    /// `Claude Code-credentials-<sha256(dir)[0..<8]>`, account `claude-code-user` —
    /// and only the default dir gets the bare, unsuffixed name. The hash is taken
    /// over the raw `CLAUDE_CONFIG_DIR` string with no resolving, no symlink
    /// following and no trailing-slash trimming, so the exact spelling the user
    /// exported is what got hashed. We can't know that spelling, so we try the
    /// plausible ones; a miss costs one `security` exit and pops no dialog.
    ///
    /// This can't misattribute an account the way a bare fallback would: the hash
    /// *is* the per-profile key, so a profile that owns no item finds nothing.
    public static func keychainServices(for profile: Profile) -> [String] {
        let path = profile.configDir.path
        var spellings = [path, path + "/"]

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") {
            spellings.append("~" + String(path.dropFirst(home.count)))
        }

        // The default dir normally has the unsuffixed item — but a user who
        // exported CLAUDE_CONFIG_DIR pointing at ~/.claude anyway gets a hashed
        // one, so keep the hashed forms as fallbacks for it too.
        var services: [String] = profile.isDefault ? [keychainBase] : []
        services += spellings.map { "\(keychainBase)-\(sha8($0))" }
        return services
    }

    static func sha8(_ string: String) -> String {
        let nfc = Data(string.precomposedStringWithCanonicalMapping.utf8)
        return String(SHA256.hash(data: nfc)
            .map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    static func readFile(at url: URL) -> Credentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func readKeychain(service: String, timeout: TimeInterval = 60) -> Credentials? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // Service only, no `-a`, and do not be tempted back. 85b3af6 read
        // `claude-code-user` out of the Claude Code binary and pinned it; on a
        // real three-profile machine every item's account is the macOS short
        // username instead, so the pin matched nothing and 0.3.7 shipped a
        // default profile that could not find its own token. The service name is
        // the per-profile key and is specific enough alone — that same machine
        // had exactly one item per config dir, no duplicates to disambiguate.
        //
        // ponytail: a value over 2400B is stored chunked across `<account>#0`,
        // `#1`, … and this would return one base64 chunk, which `parse` rejects
        // as non-JSON. Reassemble if tokens ever outgrow 2400B.
        task.arguments = ["find-generic-password", "-w", "-s", service]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        guard (try? task.run()) != nil else { return nil }

        // The very first read pops a Keychain consent dialog and blocks until the
        // user answers, so the timeout is generous. It exists only so a wedged
        // `security` can't hold the poller forever.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !task.isRunning else {
            task.terminate()
            return nil
        }
        // Safe to read after exit: the token is a few KB, well under the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard task.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Credentials? {
        // `security -w` appends a newline; JSONSerialization is happier without it.
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let bytes = trimmed.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }

        let token = oauth["accessToken"] as? String
        let expiresAtMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let nowMs = Date().timeIntervalSince1970 * 1000
        return Credentials(token: token, expired: expiresAtMs > 0 && nowMs > expiresAtMs)
    }
}
