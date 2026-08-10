import SwiftUI

/// The Settings window.
///
/// Tabs rather than one long Form: macOS settings are conventionally tabbed, and
/// this app now has five distinct groups of them. Each pane is its own file and
/// owns its own `@AppStorage` — nothing is threaded down from here except the
/// poller, which the panes that act on it need.
struct SettingsView: View {
    @ObservedObject var poller: Poller

    var body: some View {
        TabView {
            GeneralSettings(poller: poller)
                .tabItem { Label("General", systemImage: "gearshape") }
            DisplaySettings()
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }
            AlertSettings()
                .tabItem { Label("Alerts", systemImage: "bell") }
            ProfileSettings(poller: poller)
                .tabItem { Label("Profiles", systemImage: "person.2") }
            UpdateSettings(poller: poller)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
    }
}
