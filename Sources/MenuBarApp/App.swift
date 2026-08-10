import AppKit
import SwiftUI
import UserNotifications

@main
struct ClaudeUsageApp: App {
    @StateObject private var poller = Poller()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Every setting the menu bar label depends on is read here, not in Poller.
    ///
    /// `@AppStorage` only drives invalidation for a View, App or Scene — on an
    /// ObservableObject the getter still reads UserDefaults but nothing
    /// republishes, so a label reading them from Poller would keep showing the
    /// old choice until the next poll. At a ten-minute interval that is ten
    /// minutes of a settings control appearing to do nothing.
    @AppStorage(SettingsKey.menuBarAppearance) private var appearance = MenuBarAppearance.text.rawValue
    @AppStorage(SettingsKey.menuBarMetric) private var menuBarMetric = Metric.session.rawValue
    @AppStorage(SettingsKey.menuBarStyle) private var menuBarStyle = MenuBarStyle.percentage.rawValue
    @AppStorage(SettingsKey.dailyBudget) private var dailyBudget = 0.0
    @AppStorage(SettingsKey.monthlyBudget) private var monthlyBudget = 0.0

    private var metric: Metric { Metric(rawValue: menuBarMetric) ?? .session }
    private var style: MenuBarStyle { MenuBarStyle(rawValue: menuBarStyle) ?? .percentage }

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
            if MenuBarAppearance(rawValue: appearance) == .ring,
               let image = poller.menuBarImage(metric: metric) {
                Image(nsImage: image)
            } else {
                Text(poller.menuBarTitle(metric: metric, style: style)).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(poller: poller)
        }
    }
}

/// Exists for two things that have to happen at launch rather than when a scene
/// first appears — the Settings scene isn't built until someone opens Settings.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A shortcut that only works once you have visited Settings is not a
        // shortcut.
        HotkeyManager.shared.action = { MenuBarPresenter.toggle() }
        let stored = UserDefaults.standard.string(forKey: SettingsKey.hotkey) ?? ""
        HotkeyManager.shared.apply(HotkeyChoice(rawValue: stored) ?? .off)

        // Without a delegate, macOS suppresses an alert outright whenever this
        // app is frontmost — which it is with the popover or Settings open, i.e.
        // exactly when someone is watching a number climb past their threshold.
        // The alert is consumed silently and Poller's latch has already recorded
        // the crossing, so it never comes back.
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
