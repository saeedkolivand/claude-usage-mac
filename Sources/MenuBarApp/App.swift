import AppKit
import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var poller = Poller()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Read here rather than inside Poller so flipping either redraws at once —
    /// `@AppStorage` on an ObservableObject doesn't publish a change.
    @AppStorage(SettingsKey.menuBarAppearance) private var appearance = MenuBarAppearance.text.rawValue
    @AppStorage(SettingsKey.dailyBudget) private var dailyBudget = 0.0
    @AppStorage(SettingsKey.monthlyBudget) private var monthlyBudget = 0.0

    var body: some Scene {
        MenuBarExtra {
            MenuView(snapshot: poller.snapshot,
                     isRefreshing: poller.isRefreshing,
                     update: poller.update,
                     dailyBudget: dailyBudget,
                     monthlyBudget: monthlyBudget,
                     refresh: poller.refreshNow)
        } label: {
            // One or the other, never both: a MenuBarExtra label is happiest as a
            // single Text or a single Image, and the ring already says what the
            // number says. Text is also the fallback when rendering fails, so the
            // status item can never end up empty and unclickable.
            if MenuBarAppearance(rawValue: appearance) == .ring, let image = poller.menuBarImage {
                Image(nsImage: image)
            } else {
                Text(poller.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(poller: poller)
        }
    }
}

/// Exists for one thing: registering the global shortcut at launch.
///
/// Not in a scene's `onAppear` — the Settings scene isn't built until someone
/// opens Settings, and a shortcut that only works after you've visited Settings
/// is not a shortcut.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotkeyManager.shared.action = { MenuBarPresenter.toggle() }
        let stored = UserDefaults.standard.string(forKey: SettingsKey.hotkey) ?? ""
        HotkeyManager.shared.apply(HotkeyChoice(rawValue: stored) ?? .off)
    }
}
