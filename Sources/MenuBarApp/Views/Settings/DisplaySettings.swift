import SwiftUI

struct DisplaySettings: View {
    @AppStorage(SettingsKey.warn) private var warn = 50.0
    @AppStorage(SettingsKey.critical) private var critical = 80.0
    @AppStorage(SettingsKey.menuBarMetric) private var menuBarMetric = Metric.session.rawValue
    @AppStorage(SettingsKey.menuBarStyle) private var menuBarStyle = MenuBarStyle.percentage.rawValue
    @AppStorage(SettingsKey.menuBarAppearance) private var appearance = MenuBarAppearance.text.rawValue
    @AppStorage(SettingsKey.menuBarColorMode) private var colorMode = MenuBarColorMode.threshold.rawValue
    @AppStorage(SettingsKey.menuBarCustomColor) private var customColor = "#22c55e"

    private var style: MenuBarStyle { MenuBarStyle(rawValue: menuBarStyle) ?? .percentage }
    private var showsText: Bool { MenuBarAppearance(rawValue: appearance) == .text }

    var body: some View {
        Form {
            Section {
                Picker("Menu bar", selection: $appearance) {
                    ForEach(MenuBarAppearance.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }

                Picker("Shows", selection: $menuBarMetric) {
                    Text("5-hour session").tag(Metric.session.rawValue)
                    Text("Weekly").tag(Metric.weekly.rawValue)
                    Text("Opus weekly").tag(Metric.opus.rawValue)
                }

                // Only the text form has a shape to choose; the drawn ones have
                // a colour to choose instead.
                if showsText {
                    Picker("Style", selection: $menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    LabeledContent("", value: style.example)
                        .font(.caption.monospacedDigit())
                } else {
                    Picker("Colour", selection: $colorMode) {
                        ForEach(MenuBarColorMode.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    if MenuBarColorMode(rawValue: colorMode) == .custom {
                        TextField("Hex colour", text: $customColor,
                                  prompt: Text("#22c55e"))
                            .font(.body.monospaced())
                        if HexColor.rgb(customColor) == nil {
                            Text("Not a hex colour — the usage colours apply until it is.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Text("A drawn form keeps the colour a text label can't — menu bar items are otherwise rendered in one tone. \"Match menu bar\" gives that tone back on purpose. Battery, bar and the plain ring show no number, so pick the window they track above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Opus and Sonnet have their own weekly limits on the plans that report them, and show as rows in the menu when present.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Menu bar")
            }

            Section {
                Slider(value: $warn, in: 10...95, step: 5) {
                    Text("Amber above")
                } minimumValueLabel: {
                    Text("10%").font(.caption)
                } maximumValueLabel: {
                    Text("95%").font(.caption)
                }
                LabeledContent("", value: "\(Int(warn))%")
                Slider(value: $critical, in: 10...100, step: 5) {
                    Text("Red above")
                } minimumValueLabel: {
                    Text("10%").font(.caption)
                } maximumValueLabel: {
                    Text("100%").font(.caption)
                }
                LabeledContent("", value: "\(Int(critical))%")
            } header: {
                Text("Thresholds")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        // Amber above red would colour everything red; keep the bands ordered.
        .onChange(of: warn) { _, new in if new > critical { critical = new } }
        .onChange(of: critical) { _, new in if new < warn { warn = new } }
    }
}
