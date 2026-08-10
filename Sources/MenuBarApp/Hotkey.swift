import AppKit
import Carbon.HIToolbox

/// The shortcuts on offer.
///
/// ponytail: four presets and a Picker, not a key recorder. A recorder is a
/// focus-stealing custom control plus conflict detection, for a feature whose
/// whole job is "open this popover". Build it if someone asks for a combination
/// that isn't here.
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case off
    case optionShiftC
    case controlOptionU
    case commandShiftU

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:            return "Off"
        case .optionShiftC:   return "⌥⇧C"
        case .controlOptionU: return "⌃⌥U"
        case .commandShiftU:  return "⌘⇧U"
        }
    }

    /// Virtual key code and Carbon modifier mask.
    var combo: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .off:            return nil
        case .optionShiftC:   return (UInt32(kVK_ANSI_C), UInt32(optionKey | shiftKey))
        case .controlOptionU: return (UInt32(kVK_ANSI_U), UInt32(controlKey | optionKey))
        case .commandShiftU:  return (UInt32(kVK_ANSI_U), UInt32(cmdKey | shiftKey))
        }
    }
}

/// Registers one system-wide hotkey.
///
/// Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`:
/// the monitor route needs Accessibility permission, and opening a permissions
/// prompt to add a keyboard shortcut costs more trust than the shortcut is worth.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Run when the hotkey fires. Set by the app at launch.
    var action: () -> Void = {}

    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false

    /// Swapping choices is register-over-unregister; `.off` just unregisters.
    func apply(_ choice: HotkeyChoice) {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let combo = choice.combo else { return }

        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.key, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        // Another app owning the combination is the ordinary failure here, and
        // there is nothing useful to say about it beyond not having the shortcut.
        hotKey = status == noErr ? ref : nil
    }

    /// Installed once and left in place — the handler dispatches on whatever is
    /// registered at the time, so re-installing per choice would only stack
    /// duplicate callbacks.
    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyFired, 1, &spec, nil, nil)
    }

    /// 'CUSG'. Only has to be distinct from other signatures in this process.
    private static let signature = OSType(0x4355_5347)
}

/// Carbon calls this on its own event thread, and it is a C function pointer so
/// it captures nothing — hence the singleton it hops back to the main actor for.
private func hotkeyFired(_ call: EventHandlerCallRef?, _ event: EventRef?,
                         _ context: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in HotkeyManager.shared.action() }
    return noErr
}

/// Opens the menu bar popover from somewhere other than a click on it.
///
/// SwiftUI's `MenuBarExtra` publishes no presentation binding, so this reaches
/// the status item through the window AppKit puts it in and clicks its button.
/// The search is over public view types only — no KVC on private classes, which
/// would raise an Objective-C exception Swift cannot catch.
///
/// ponytail: if that view class is ever renamed, the shortcut quietly stops
/// working and nothing else changes. The upgrade path is an AppKit
/// `NSStatusItem` plus `NSPopover`, which is a rewrite of App.swift for one
/// shortcut — worth it only if this actually breaks.
enum MenuBarPresenter {
    @MainActor
    static func toggle() {
        for window in NSApp.windows {
            guard let root = window.contentView, let button = statusButton(in: root) else {
                continue
            }
            button.performClick(nil)
            return
        }
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = statusButton(in: subview) { return found }
        }
        return nil
    }
}
