import AppKit
import SwiftUI

/// The menu bar label drawn as a ring instead of set as text.
///
/// A SwiftUI shape used directly as a `MenuBarExtra` label is rendered as a
/// template image — every colour flattened to the menu bar's own, which is why
/// `Poller.menuBarTitle` has always been text and why the critical state is a
/// bang rather than red. Rendering it here and clearing `isTemplate` is what
/// keeps the tint.
///
/// ponytail: opt-in, and text stays the default. macOS menu extras are
/// monochrome by convention, and if a future system tints this back to grey the
/// fallback is the label that already works.
@MainActor
enum MenuBarIcon {
    /// Nil if rendering fails, and callers fall back to text rather than showing
    /// an empty menu bar slot.
    static func ring(pct: Double?, level: Level, side: CGFloat = 16) -> NSImage? {
        let renderer = ImageRenderer(content:
            RingGauge(pct: pct, level: level, lineWidth: 3, showsPercent: false)
                .frame(width: side, height: side))
        // The menu bar is drawn at the screen's scale; 2 covers every Mac display
        // Sonoma still supports.
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }

        let image = NSImage(cgImage: cgImage, size: CGSize(width: side, height: side))
        image.isTemplate = false
        return image
    }
}
