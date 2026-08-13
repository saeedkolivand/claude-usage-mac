import SwiftUI
import XCTest

/// Renders the images used by the README and the landing page into `docs/gallery`.
///
/// Same `ImageRenderer` pipeline as the snapshot tests, so these cannot drift
/// from the real UI — they *are* the real UI, with a backdrop and a shadow.
/// That's the whole reason this isn't a separate compositing script.
///
/// Run in CI, downloaded, and committed when they change (rarely).
@MainActor
final class MarketingRenders: XCTestCase {

    private let outputDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/SnapshotTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("docs/gallery", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Pieces

    /// Widgets sit on a rounded rect on the desktop; matching it here keeps the
    /// gallery honest about how they actually look.
    private func widget(_ face: Face, project: ProjectUsage? = nil,
                        scope: String? = nil) -> some View {
        plate(UsageWidgetView(snapshot: .preview, project: project, scopeLabel: scope, face: face)
            .padding(face == .small ? 12 : 16)
            .frame(width: face.size.width, height: face.size.height))
    }

    /// Same plate, plus the container backdrop the style brings with it.
    private func styledWidget(_ face: Face, style: FaceStyle) -> some View {
        plate(UsageWidgetView(snapshot: .preview, face: face, style: style)
            .padding(face == .small ? 12 : 16)
            .frame(width: face.size.width, height: face.size.height)
            .background(style.backdrop))
    }

    private func plate<V: View>(_ content: V) -> some View {
        content
            .background(Color(white: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 22, y: 12)
    }

    private var popover: some View {
        MenuView(snapshot: .preview, isRefreshing: false, showsActions: false)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 24, y: 14)
    }

    private func backdrop<V: View>(_ padding: CGFloat = 44, @ViewBuilder content: () -> V) -> some View {
        content()
            .padding(padding)
            .background(
                LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.13),
                                        Color(red: 0.04, green: 0.04, blue: 0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, .dark)
    }

    // MARK: - Renders

    func testRenderHero() throws {
        // The README's opening image: what you get, in one frame.
        let view = backdrop(52) {
            HStack(alignment: .top, spacing: 36) {
                popover
                VStack(spacing: 24) {
                    widget(.medium)
                    widget(.small)
                }
            }
        }
        try render(view, to: "hero.png")
    }

    func testRenderWidgetFamilies() throws {
        try render(backdrop { widget(.small) }, to: "widget-small.png")
        try render(backdrop { widget(.medium) }, to: "widget-medium.png")
        try render(backdrop { widget(.large) }, to: "widget-large.png")
    }

    func testRenderProjectWidget() throws {
        let project = try XCTUnwrap(Snapshot.preview.stats.projects.first)
        try render(
            backdrop { widget(.medium, project: project, scope: project.name) },
            to: "widget-project.png")
    }

    func testRenderPopover() throws {
        try render(backdrop { popover }, to: "menu.png")
    }

    /// One image per configurable widget style, medium family — the size that
    /// shows each look best without dwarfing the grid it sits in.
    func testRenderWidgetStyles() throws {
        for style in FaceStyle.allCases where style != .standard {
            try render(backdrop { styledWidget(.medium, style: style) },
                       to: "widget-style-\(style.rawValue).png")
        }
    }

    /// The drawn menu bar forms as a labelled strip. Rendered at menu bar size
    /// on purpose — showing them bigger than they ever appear would be a lie.
    func testRenderMenuBarStyles() throws {
        let view = backdrop(36) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(MenuBarAppearance.allCases.filter(\.isDrawn)) { appearance in
                    Self.strip(appearance.label) {
                        if let image = MenuBarIcon.image(
                            appearance: appearance, pct: 42, level: .ok) {
                            Image(nsImage: image)
                        }
                    }
                }
                Self.strip("Text") {
                    Text("42%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
        }
        try render(view, to: "menubar-styles.png")
    }

    /// Static so the view-builder closures above don't capture self.
    private static func strip<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        VStack(spacing: 10) {
            content().frame(height: 18)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rendering

    private func render<V: View>(_ view: V, to name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage, "nothing rendered for \(name)")
        XCTAssertGreaterThan(image.size.width, 0, "\(name) rendered with zero width")

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent(name))
    }
}
