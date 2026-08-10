import AppKit
import SwiftUI

struct ProfileSettings: View {
    @ObservedObject var poller: Poller

    @AppStorage(SettingsKey.selectedProfile) private var selectedProfile = ""
    @State private var extraPaths = ProfileStore.savedExtraPaths()

    var body: some View {
        Form {
            Section {
                if poller.profiles.isEmpty {
                    Text("No Claude Code data found")
                        .font(.callout)
                    Text("Looked in ~/.claude and alongside it. If your config lives elsewhere — CLAUDE_CONFIG_DIR — add the folder below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Profile", selection: $selectedProfile) {
                        ForEach(poller.profiles) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .onChange(of: selectedProfile) { _, id in
                        guard let picked = poller.profiles.first(where: { $0.id == id }) else { return }
                        poller.select(picked)
                    }
                    if let active = poller.profiles.first(where: { $0.id == selectedProfile }) {
                        LabeledContent("Folder", value: active.configDir.path)
                            .font(.caption)
                        // Claude Code names this item after the config dir it was
                        // authenticated from. Showing it turns "Sign in with Claude
                        // Code" on an account that *is* signed in into something the
                        // user can actually check against their Keychain.
                        LabeledContent("Keychain",
                                       value: CredentialStore.keychainServices(for: active).first ?? "—")
                            .font(.caption)
                            .textSelection(.enabled)
                        if let organization = active.organization {
                            LabeledContent("Organization",
                                           value: [organization, active.plan].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                        }
                    }
                }

                // Folders added by hand are the only removable ones — the rest are
                // discovered, so "removing" them would just mean finding them again
                // on the next rescan.
                ForEach(extraPaths, id: \.self) { path in
                    HStack {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove") { removeFolder(path) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }

                HStack {
                    Button("Add Folder…", action: addFolder)
                    Spacer()
                    Button("Rescan") { poller.rediscover() }
                }

                if poller.profiles.count > 1 {
                    Text("Each profile is a separate Claude account. Limits, tokens and history are tracked independently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Profile")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear(perform: reload)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Claude Code config folder — the one containing a “projects” folder."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProfileStore.addExtraPath(url.path)
        reload()
    }

    private func removeFolder(_ path: String) {
        ProfileStore.removeExtraPath(path)
        reload()
    }

    private func reload() {
        extraPaths = ProfileStore.savedExtraPaths()
        poller.rediscover()
    }
}
