import Foundation

extension Snapshot {
    /// One preformatted line for the Claude Code statusline, e.g.
    /// "5h 34% | wk 70% | resets 2h 10m".
    ///
    /// Formatted here rather than in the shell script on purpose: parsing JSON
    /// with /bin/sh built-ins is exactly the fragility the script avoids by
    /// being a `cat`.
    public var statuslineText: String {
        var parts = ["5h \(Format.percent(sessionPct))",
                     "wk \(Format.percent(weeklyPct))"]
        let resets = Format.until(sessionResetsAt)
        if !resets.isEmpty { parts.append("resets \(resets)") }
        return parts.joined(separator: " | ")
    }
}

/// The plain-text sibling of `bundle.json`, rewritten on every poll so the
/// statusline script never has to parse anything.
public enum Statusline {
    /// Only the Application Support copy: it is the one stable, sandbox-free
    /// path a shell script can hardcode.
    public static var location: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClaudeUsage/statusline.txt")
    }

    @discardableResult
    public static func write(_ text: String) -> Bool {
        guard let url = location else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data((text + "\n").utf8).write(to: url, options: .atomic)) != nil
    }
}

/// Installs a statusline into Claude Code's `~/.claude/settings.json`: a tiny
/// shell script that prints the file above, wired in as the `statusLine` command.
///
/// The merge is JSONSerialization on the whole object — every unrelated key is
/// read and written back — and atomic. A statusLine that is already someone
/// else's is backed up whole to `settings.json.claude-usage-backup` before
/// being replaced; if that backup slot is already taken by an earlier install,
/// this refuses rather than silently discarding a configuration.
public enum StatuslineInstaller {

    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let scriptName = "statusline-usage.sh"
    static let backupName = "settings.json.claude-usage-backup"
    /// What settings.json points at. Tilde on purpose — Claude Code expands it,
    /// and the literal string is what install and uninstall match on.
    static let command = "~/.claude/statusline-usage.sh"

    static let script = """
    #!/bin/sh
    # Installed by Claude Usage.app; its Uninstall button removes this.
    # The app rewrites the file below on every poll — this only prints it.
    f="$HOME/Library/Application Support/ClaudeUsage/statusline.txt"
    [ -r "$f" ] && cat "$f" || echo "claude usage: no data (is Claude Usage running?)"
    """

    /// Public because it seeds the public entry points' default arguments —
    /// Swift requires a default argument's pieces to be at least as visible.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Whether the script is on disk — enough to label the buttons truthfully.
    public static func isInstalled(in claudeDir: URL = defaultDirectory) -> Bool {
        FileManager.default.fileExists(
            atPath: claudeDir.appendingPathComponent(scriptName).path)
    }

    public static func install(in claudeDir: URL = defaultDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let backupURL = claudeDir.appendingPathComponent(backupName)
        let original = try? Data(contentsOf: settingsURL)
        let (merged, foreign) = try merged(original)

        if foreign {
            guard !fm.fileExists(atPath: backupURL.path) else {
                throw Failure("A different statusLine is configured and a backup "
                    + "already exists at \(backupURL.path) — resolve that first.")
            }
            try (original ?? Data()).write(to: backupURL, options: .atomic)
        }
        try merged.write(to: settingsURL, options: .atomic)

        let scriptURL = claudeDir.appendingPathComponent(scriptName)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    public static func uninstall(in claudeDir: URL = defaultDirectory) throws {
        let fm = FileManager.default
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let backupURL = claudeDir.appendingPathComponent(backupName)

        if fm.fileExists(atPath: backupURL.path) {
            // The backup is the pre-install settings.json, whole. Restoring it
            // both removes our key and brings back the statusline it replaced.
            try? fm.removeItem(at: settingsURL)
            try fm.moveItem(at: backupURL, to: settingsURL)
        } else if let data = try? Data(contentsOf: settingsURL) {
            try unmerged(data).write(to: settingsURL, options: .atomic)
        }
        try? fm.removeItem(at: claudeDir.appendingPathComponent(scriptName))
    }

    // MARK: - Pure merge / unmerge

    /// `foreign` is true when a statusLine other than ours was already there —
    /// the caller's cue to back the file up before writing.
    static func merged(_ original: Data?) throws -> (data: Data, foreign: Bool) {
        var root: [String: Any] = [:]
        if let original, !original.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: original),
                  let object = parsed as? [String: Any] else {
                throw Failure("~/.claude/settings.json is not a JSON object — not touching it.")
            }
            root = object
        }
        let existing = root["statusLine"] as? [String: Any]
        let foreign = root["statusLine"] != nil
            && existing?["command"] as? String != command
        root["statusLine"] = ["type": "command", "command": command]
        return (try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), foreign)
    }

    static func unmerged(_ original: Data) throws -> Data {
        guard let parsed = try? JSONSerialization.jsonObject(with: original),
              var root = parsed as? [String: Any] else {
            throw Failure("~/.claude/settings.json is not a JSON object — not touching it.")
        }
        root.removeValue(forKey: "statusLine")
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
