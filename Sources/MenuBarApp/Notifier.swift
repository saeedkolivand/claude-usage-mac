import Foundation
import UserNotifications

/// Threshold and budget alerts.
///
/// Deliberately thin: authorize once, post one notification, never schedule and
/// never repeat. Everything about *when* to fire lives in Poller, because that's
/// where the state that decides it already is.
actor Notifier {
    static let shared = Notifier()

    private var authorized: Bool?

    /// Posts immediately, or does nothing if the user said no.
    ///
    /// Silence on refusal is the whole contract — a menu bar app that nags for a
    /// permission it was already denied is worse than one that just stops.
    func post(title: String, body: String) async {
        // UNUserNotificationCenter.current() traps outright in a process with no
        // bundle identifier, which is what the CLI and a bare test runner are.
        guard Bundle.main.bundleIdentifier != nil, await allowed() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A nil trigger means "deliver now".
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Asked once per launch. macOS itself only prompts the first time ever and
    /// answers from its own record after that, so caching here just avoids a
    /// round trip per poll.
    private func allowed() async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        return granted
    }
}
