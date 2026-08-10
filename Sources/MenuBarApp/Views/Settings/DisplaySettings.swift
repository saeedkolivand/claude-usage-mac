import SwiftUI

struct DisplaySettings: View {
    @AppStorage(SettingsKey.warn) private var warn = 50.0
    @AppStorage(SettingsKey.critical) private var critical = 80.0
    @AppStorage(SettingsKey.menuBarMetric) private var menuBarMetric = Metric.session.rawValue
    @AppStorage(SettingsKey.menuBarStyle) private var menuBarStyle = MenuBarStyle.percentage.rawValue
    @AppStorage(SettingsKey.menuBarAppearance) private var appearance = MenuBarAppearance.text.rawValue

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
                .pickerStyle(.segmented)

                Picker("Shows", selection: $menuBarMetric) {
                    Text("5-hour session").tag(Metric.session.rawValue)
                    Text("Weekly").tag(Metric.weekly.rawValue)
                    Text("Opus weekly").tag(Metric.opus.rawValue)
                }

                // Only the text form has a shape to choose; a ring is a ring.
                if showsText {
                    Picker("Style", selection: $menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    LabeledContent("", value: style.example)
                        .font(.caption.monospacedDigit())
                } else {
                    Text("A drawn ring keeps the colour a text label can't — menu bar items are otherwise rendered in one tone. It shows no number, so pick the window it tracks above.")
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
