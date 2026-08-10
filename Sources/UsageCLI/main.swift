import Foundation
import UsageCore

// Smoke test for the whole data path with no UI involved — CI runs this, and
// it's the fastest way to compare numbers against the Stream Deck plugin.
//
//   usage-cli                    the default profile, pretty
//   usage-cli --profiles         list discovered profiles and exit
//   usage-cli --profile <path>   a specific config dir
//   usage-cli --json             the snapshot as the widget will see it
//   usage-cli --write            also write it to disk

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments)

let discovered = ProfileStore.discover(extraPaths: ProfileStore.savedExtraPaths())

if flags.contains("--profiles") {
    if discovered.isEmpty {
        print("no profiles found — looked for a 'projects' folder in ~/.claude and alongside it")
        exit(1)
    }
    for profile in discovered {
        let tags = [profile.organization, profile.plan].compactMap { $0 }.joined(separator: " · ")
        print("\(profile.isDefault ? "*" : " ") \(profile.displayName)")
        print("    \(profile.configDir.path)\(tags.isEmpty ? "" : "  [\(tags)]")")
    }
    exit(0)
}

let selected: Profile? = {
    guard let index = arguments.firstIndex(of: "--profile"),
          index + 1 < arguments.count else { return discovered.first }
    let wanted = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        .standardizedFileURL.path
    return discovered.first { $0.configDir.standardizedFileURL.path == wanted }
}()

// "No profile" is a real state the app renders, not a reason to bail — a
// machine without Claude Code installed should still produce valid output.
let snapshot: Snapshot
if let profile = selected {
    snapshot = await ProfileMonitor(profile: profile).snapshot(
        force: true, label: discovered.count > 1 ? profile.displayName : nil)
} else {
    snapshot = Snapshot(usage: nil, error: "no-profile")
}

if flags.contains("--write") {
    let ok = snapshot.write()
    FileHandle.standardError.write(Data("write: \(ok ? "ok" : "failed")\n".utf8))
}

if flags.contains("--json") {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(snapshot) {
        print(String(decoding: data, as: UTF8.self))
    }
} else {
    let s = snapshot
    if let profile = selected {
        print("profile: \(profile.displayName)  (\(profile.configDir.path))")
    } else {
        print("profile: none found — looked in ~/.claude and alongside it")
    }
    if let error = s.error {
        print("error:   \(error)\(s.stale ? " (showing stale data)" : "")")
    }
    print("session: \(Format.percent(s.sessionPct))  resets \(Format.until(s.sessionResetsAt))")
    print("weekly:  \(Format.percent(s.weeklyPct))  resets \(Format.until(s.weeklyResetsAt))")
    // Only on the plans that report them, which is the fastest way to find out
    // whether yours does.
    if let opus = s.opusPct {
        print("opus:    \(Format.percent(opus))  resets \(Format.until(s.opusResetsAt))")
    }
    if let sonnet = s.sonnetPct {
        print("sonnet:  \(Format.percent(sonnet))  resets \(Format.until(s.sonnetResetsAt))")
    }
    if let extra = s.extraUsagePct {
        print("extra:   \(Format.percent(extra))")
    }
    print("today:   \(Format.tokens(s.stats.todayTokens))  \(Format.cost(s.stats.todayCost))")
    print("week:    \(Format.tokens(s.stats.weekTokens))  \(Format.cost(s.stats.weekCost))")
    print("session: \(Format.tokens(s.stats.sessionTokens))  \(Format.cost(s.stats.sessionCost))")
    print("month:   \(Format.cost(s.monthToDateCost()))")
    for model in s.stats.models {
        print("  \(model.name.padding(toLength: 8, withPad: " ", startingAt: 0))  \(Format.tokens(model.tokens))  \(Format.cost(model.cost))")
    }
    for project in s.stats.projects.prefix(5) {
        print("  \(project.name.padding(toLength: min(32, max(project.name.count, 24)), withPad: " ", startingAt: 0))  \(Format.tokens(project.tokens))")
    }
    if !s.stats.ok, let profile = selected {
        print("note:    \(profile.projectsDirectory.path) not readable")
    }
}

// Non-zero on a failed fetch so CI can assert on it.
exit(snapshot.error == nil ? 0 : 1)
