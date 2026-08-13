import AppKit
import SwiftUI

/// The menu bar label drawn as an image instead of set as text.
///
/// A SwiftUI shape used directly as a `MenuBarExtra` label is rendered as a
/// template image — every colour flattened to the menu bar's own, which is why
/// `Poller.menuBarTitle` has always been text and why the critical state is a
/// bang rather than red. Rendering it here and clearing `isTemplate` is what
/// keeps the tint — except in `mono` mode, where the flattening is exactly what
/// was asked for and `isTemplate` stays on.
///
/// ponytail: opt-in, and text stays the default. macOS menu extras are
/// monochrome by convention, and if a future system tints these back to grey
/// the fallback is the label that already works.
@MainActor
enum MenuBarIcon {
    /// Nil for `.text` and when rendering fails — callers fall back to the text
    /// label rather than showing an empty menu bar slot.
    static func image(appearance: MenuBarAppearance, pct: Double?, level: Level,
                      colorMode: MenuBarColorMode = .threshold,
                      customHex: String = "") -> NSImage? {
        guard appearance.isDrawn else { return nil }

        let tint: Color
        switch colorMode {
        case .threshold:
            tint = level.tint
        case .mono:
            // Template rendering only reads the alpha channel; black keeps it
            // fully opaque so the system repaints it in the menu bar's tone.
            tint = .black
        case .custom:
            // A malformed hex falls back to the threshold tint rather than to
            // black-on-dark invisibility.
            tint = HexColor.rgb(customHex)
                .map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? level.tint
        }

        let fraction = pct.map { min(max($0 / 100, 0), 1) }
        let content: AnyView
        switch appearance {
        case .text:
            return nil
        case .ring:
            content = AnyView(
                RingGauge(pct: pct, level: level, lineWidth: 3, showsPercent: false,
                          tint: colorMode == .threshold ? nil : tint)
                    .frame(width: 16, height: 16))
        case .ringPercent:
            content = AnyView(HStack(spacing: 3) {
                RingGauge(pct: pct, level: level, lineWidth: 2.5, showsPercent: false,
                          tint: colorMode == .threshold ? nil : tint)
                    .frame(width: 13, height: 13)
                Text(Format.percent(pct))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            })
        case .battery:
            content = AnyView(BatteryIcon(fraction: fraction, tint: tint))
        case .bar:
            content = AnyView(BarIcon(fraction: fraction, tint: tint))
        }

        let renderer = ImageRenderer(content: content)
        // The menu bar is drawn at the screen's scale; 2 covers every Mac
        // display Sonoma still supports.
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }

        let size = CGSize(width: CGFloat(cgImage.width) / 2,
                          height: CGFloat(cgImage.height) / 2)
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = colorMode == .mono
        return image
    }
}

/// A rounded-rect battery with a proportional fill and a terminal nub. No data
/// draws the empty case at reduced opacity, so "no reading" and "0%" differ.
private struct BatteryIcon: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(tint, lineWidth: 1)
                    .opacity(fraction == nil ? 0.4 : 1)
                if let fraction {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(tint)
                        .frame(width: max(1, 14 * fraction), height: 6)
                        .padding(.leading, 2)
                }
            }
            .frame(width: 18, height: 10)
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 2, height: 4)
        }
        .padding(1)
    }
}

/// The menu bar cousin of `MiniBar`: a capsule fill over its own faded track.
private struct BarIcon: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(tint.opacity(0.25))
            if let fraction {
                Capsule().fill(tint)
                    .frame(width: max(3, 20 * fraction))
            }
        }
        .frame(width: 20, height: 6)
        .padding(1)
    }
}
