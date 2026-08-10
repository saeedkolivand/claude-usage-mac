import AppKit
import SwiftUI

struct UpdateSettings: View {
    @ObservedObject var poller: Poller

    @AppStorage(SettingsKey.autoCheckUpdates) private var autoCheckUpdates = true
    /// Read once when the view is first built rather than on every redraw — an
    /// install cannot change source while the app is running.
    @State private var isHomebrewCask = InstallSource.isHomebrewCask()

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppVersion.current)
                HStack {
                    // A silent success has to look like a success — without this the
                    // feature is invisible until the day an update happens to exist.
                    Text(updateStatus)
                        .font(.callout)
                        .foregroundStyle(statusColour)
                    Spacer()
                    Button("Check Now", action: poller.checkForUpdates)
                        .disabled(isInstalling)
                }
                if let release = poller.update {
                    Link("Open release notes", destination: release.url)
                        .font(.callout)
                }
                // Named for what it now does. The same switch gates the install, so
                // calling it "Check automatically" would hide half its effect.
                Toggle("Check and install automatically", isOn: $autoCheckUpdates)
                if isHomebrewCask {
                    HStack {
                        Text(Self.brewResync)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.brewResync, forType: .string)
                        }
                    }
                }
                Text(updateAdvice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Updates")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// `--force` because by the time anyone runs this the app on disk is already
    /// newer than the version brew believes it installed, and a plain upgrade
    /// baulks at replacing a bundle it didn't put there.
    private static let brewResync = "brew upgrade --cask claude-usage --force"

    private var updateAdvice: String {
        let base = "Checks GitHub four times a day, installs what it finds, and restarts."
        guard isHomebrewCask else { return base }
        return "\(base) Homebrew still records the version it installed — run the "
            + "command above whenever you want its records to agree."
    }

    private var isInstalling: Bool {
        if case .busy = poller.updateState { return true }
        return false
    }

    private var statusColour: Color {
        if case .failed = poller.updateState { return .red }
        return poller.update == nil && !isInstalling ? .secondary : .primary
    }

    private var updateStatus: String {
        // An install in flight outranks the release that started it — "0.4.0
        // available" beside a progress line reads like two separate things.
        switch poller.updateState {
        case let .busy(step): return step
        case let .failed(message): return message
        case .idle: break
        }
        if let release = poller.update {
            return "Version \(release.version) available"
        }
        guard let checked = poller.lastUpdateCheck else { return "Not checked yet" }
        let age = Int(Date().timeIntervalSince(checked))
        return age < 60 ? "Up to date — checked just now" : "Up to date"
    }
}
