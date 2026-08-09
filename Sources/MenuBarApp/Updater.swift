import AppKit
import Foundation

enum UpdateState: Equatable {
    case idle
    case busy(String)
    case failed(String)
}

/// Downloads a release and swaps it in over the running app.
///
/// One path for every install, Homebrew included. A cask install is replaced
/// exactly like a DMG one, which leaves brew still recording the version it put
/// there — `brew list --cask --versions` reads stale until someone runs
/// `brew upgrade --cask claude-usage --force`. That is the accepted cost of
/// having one updater instead of two; the Settings caption says so on machines
/// where it applies.
///
/// Sparkle would bring an appcast, an EdDSA keypair and an updater that expects
/// a properly signed app. This is a download, a checksum and a rename.
enum Updater {

    enum Failure: LocalizedError {
        case noAsset
        case noChecksum
        case checksumMismatch
        case noAppInImage
        case download(String)
        case command(String, Int32)

        var errorDescription: String? {
            switch self {
            case .noAsset:
                return "That release publishes no disk image to install."
            case .noChecksum:
                return "That release publishes no checksum, so the download can't be verified."
            case .checksumMismatch:
                return "The download didn't match its published checksum."
            case .noAppInImage:
                return "The disk image contained no app."
            case let .download(name):
                return "Couldn't download \(name)."
            case let .command(tool, status):
                return "\(tool) failed (\(status))."
            }
        }
    }

    /// Reports each step through `progress` rather than owning published state,
    /// so the one object the views already observe stays the only one.
    static func install(_ release: ReleaseInfo,
                        over bundle: URL,
                        progress: @escaping @Sendable (String) -> Void) async throws {
        guard let dmg = release.dmg else { throw Failure.noAsset }

        progress("Downloading \(release.version)…")
        let image = try await fetch(dmg)

        progress("Verifying \(release.version)…")
        try await verify(image, named: dmg.lastPathComponent, against: release.checksums)

        progress("Installing \(release.version)…")
        // hdiutil and ditto are blocking, and several seconds of frozen menu bar
        // is exactly what a background update must not cost.
        let staged = try await Task.detached(priority: .userInitiated) {
            try stage(image, appropriateFor: bundle)
        }.value
        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: staged)

        // The appex inside was swapped underneath its registration. Ad-hoc
        // signing means the extension's identity *is* its cdhash, so every build
        // is a new one and chronod can no longer launch the widget it has on
        // file: placed widgets freeze on their last render, and a fresh one
        // never gets past its placeholder. 0.3.9 shipped that way. build.sh
        // dodges it by rm -rf'ing first; an atomic replace has to say so out
        // loud. Both `try?` — a failed re-registration must not abort an
        // otherwise-good update, and killall exits non-zero on no match.
        // Detached for the same reason the staging above is: these block, and
        // the menu bar must not.
        await Task.detached(priority: .userInitiated) {
            try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                     + "LaunchServices.framework/Support/lsregister", ["-f", bundle.path])
            // ponytail: restarting the widget host is the blunt version of what
            // re-adding a widget does by hand. launchd brings it straight back.
            // If it ever proves too heavy, drop it and document the manual
            // remove-and-re-add instead.
            try? run("/usr/bin/killall", ["chronod"])
        }.value

        progress("Restarting…")
        await relaunch(bundle)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue("claude-usage-mac", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
        else { throw Failure.download(url.lastPathComponent) }
        return data
    }

    /// Not a signature, and not pretending to be one: the image and the checksum
    /// come from the same release over the same TLS connection, so anything able
    /// to replace one could replace the other. What it does catch is the failure
    /// that actually happens — a truncated or corrupted download being unpacked
    /// over a working install. Provenance needs notarization, which an ad-hoc
    /// signed build doesn't have.
    private static func verify(_ image: Data, named filename: String,
                               against checksums: URL?) async throws {
        guard let checksums else { throw Failure.noChecksum }
        let text = String(decoding: try await fetch(checksums), as: UTF8.self)
        guard let expected = Checksums.expected(for: filename, in: text)
        else { throw Failure.noChecksum }
        guard Checksums.sha256(image) == expected else { throw Failure.checksumMismatch }
    }

    /// Mounts the image, copies the app out, unmounts. The copy lands in a
    /// replacement directory on the same volume as the installed app, which is
    /// what lets the swap that follows be a rename rather than a slow recursive
    /// copy over a bundle that is currently running.
    private static func stage(_ image: Data, appropriateFor bundle: URL) throws -> URL {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let dmg = scratch.appendingPathComponent("update.dmg")
        try image.write(to: dmg)

        let mount = scratch.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil",
                ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        // Found by extension rather than by name, so a renamed install still
        // recognises what is inside its own image.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" })
        else { throw Failure.noAppInImage }

        let staged = try FileManager.default
            .url(for: .itemReplacementDirectory, in: .userDomainMask,
                 appropriateFor: bundle, create: true)
            .appendingPathComponent(bundle.lastPathComponent)

        // ditto, not copyItem: it is the tool that carries an app bundle's
        // symlinks, permissions and extended attributes across intact.
        try run("/usr/bin/ditto", [app.path, staged.path])
        // URLSession doesn't quarantine what it downloads, so this is usually a
        // no-op — but the cask clears the same flag in its postflight, and one
        // exec is cheaper than the "damaged, move to Trash" dialog it prevents.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Reopened by a detached shell rather than NSWorkspace. The new app sits at
    /// the same path this process is running from, so asking macOS to open it
    /// while we still exist just activates the instance being replaced. The
    /// child outlives us and opens the one that took its place.
    @MainActor
    private static func relaunch(_ bundle: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(bundle.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        // Drained before waiting: a tool that fills the pipe buffer while we sit
        // in waitUntilExit deadlocks against us.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw Failure.command((tool as NSString).lastPathComponent, task.terminationStatus)
        }
        return String(decoding: output, as: UTF8.self)
    }
}
