import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettings: View {
    @ObservedObject var poller: Poller

    @AppStorage(SettingsKey.refreshInterval) private var refreshSeconds = 60
    @AppStorage(SettingsKey.hotkey) private var hotkey = HotkeyChoice.off.rawValue
    @AppStorage(SettingsKey.userAgent) private var userAgent = UsageAPI.defaultUserAgent
    /// Read once when the view is first built rather than on every redraw — an
    /// install cannot change source while the app is running.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var exportError: String?
    @State private var statuslineInstalled = StatuslineInstaller.isInstalled()
    @State private var statuslineError: String?

    var body: some View {
        Form {
            Section {
                Picker("Check usage", selection: $refreshSeconds) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval.rawValue)
                    }
                }
                // End the current wait rather than let it run out: it is a sleep
                // of the old length, so without this a change from ten minutes
                // to one would take ten minutes to happen.
                .onChange(of: refreshSeconds) { _, _ in poller.wakeNow() }
                Text("Every profile is polled on this schedule, and each poll is what refreshes the widgets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                Picker("Global shortcut", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .onChange(of: hotkey) { _, new in
                    HotkeyManager.shared.apply(HotkeyChoice(rawValue: new) ?? .off)
                }
                Text("Opens the menu from anywhere. If another app already owns the combination, this one silently loses it — pick a different one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Export…", action: export)
                    Button("Copy Stats", action: copyStats)
                    Spacer()
                }
                .disabled(poller.snapshot == nil)
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.red)
                }
                Text("CSV of daily totals and per-model usage, or the whole snapshot as JSON — whichever extension you save under.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Install Claude Code statusline", action: installStatusline)
                        .disabled(statuslineInstalled)
                    Button("Uninstall", action: uninstallStatusline)
                        .disabled(!statuslineInstalled)
                    Spacer()
                }
                if let statuslineError {
                    Text(statuslineError).font(.caption).foregroundStyle(.red)
                }
                Text("Puts \"5h 34% | wk 70% | resets 2h 10m\" in Claude Code's statusline, updated on every poll. Writes ~/.claude/statusline-usage.sh and sets statusLine in ~/.claude/settings.json; an existing statusline is backed up first and restored on uninstall.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("User-Agent", text: $userAgent)
                Text("The usage endpoint rate-limits clients that don't identify as Claude Code. Change this only if the version string goes stale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    // MARK: - Login item

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            // Unsigned builds can't register a login item; say so rather than
            // silently flipping the toggle back.
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Statusline

    private func installStatusline() {
        do {
            try StatuslineInstaller.install()
            statuslineError = nil
        } catch {
            statuslineError = error.localizedDescription
        }
        statuslineInstalled = StatuslineInstaller.isInstalled()
    }

    private func uninstallStatusline() {
        do {
            try StatuslineInstaller.uninstall()
            statuslineError = nil
        } catch {
            statuslineError = error.localizedDescription
        }
        statuslineInstalled = StatuslineInstaller.isInstalled()
    }

    // MARK: - Export

    private func export() {
        guard let snapshot = poller.snapshot else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json]
        panel.nameFieldStringValue = "claude-usage.csv"
        panel.message = "Daily totals as CSV, or the whole snapshot as JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data: Data? = url.pathExtension.lowercased() == "json"
            ? Self.json(snapshot)
            : Data(Self.csv(snapshot).utf8)

        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private static func json(_ snapshot: Snapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(snapshot)
    }

    /// Two tables in one file, separated by a blank line: days, then models. No
    /// quoting anywhere because no field can contain a comma — dates are ISO,
    /// numbers are numbers, and model names come from a fixed four-item set.
    static func csv(_ snapshot: Snapshot) -> String {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withFullDate]

        var lines = ["date,tokens,cost_usd"]
        for day in snapshot.stats.days {
            lines.append("\(date.string(from: day.day)),\(day.tokens),\(money(day.cost))")
        }
        if !snapshot.stats.models.isEmpty {
            lines.append("")
            lines.append("model,tokens_week,cost_week_usd,tokens_today,cost_today_usd")
            for model in snapshot.stats.models {
                lines.append("\(model.name),\(model.tokens),\(money(model.cost)),"
                    + "\(model.todayTokens),\(money(model.todayCost))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Four places, not the two `Format.cost` shows — this is for arithmetic in a
    /// spreadsheet, where a rounded cent per row adds up to a wrong total.
    private static func money(_ usd: Double) -> String {
        String(format: "%.4f", usd)
    }

    private func copyStats() {
        guard let s = poller.snapshot else { return }
        var lines = [
            "Claude usage",
            "5 hours:  \(Format.percent(s.sessionPct))  resets \(Format.until(s.sessionResetsAt))",
            "Weekly:   \(Format.percent(s.weeklyPct))  resets \(Format.until(s.weeklyResetsAt))",
        ]
        for metric in s.perModelLimits {
            lines.append("\(metric.title):  \(Format.percent(s.pct(metric)))")
        }
        lines += [
            "Today:    \(Format.tokens(s.stats.todayTokens))  \(Format.cost(s.stats.todayCost))",
            "Week:     \(Format.tokens(s.stats.weekTokens))  \(Format.cost(s.stats.weekCost))",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
