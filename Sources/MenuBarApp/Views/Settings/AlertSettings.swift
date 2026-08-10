import SwiftUI

struct AlertSettings: View {
    @AppStorage(SettingsKey.notifyThreshold) private var notifyThreshold = true
    @AppStorage(SettingsKey.dailyBudget) private var dailyBudget = 0.0
    @AppStorage(SettingsKey.monthlyBudget) private var monthlyBudget = 0.0
    @AppStorage(SettingsKey.warn) private var warn = 50.0
    @AppStorage(SettingsKey.critical) private var critical = 80.0

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a limit crosses a threshold", isOn: $notifyThreshold)
                Text("Once per crossing, at \(Int(warn))% and again at \(Int(critical))% — the same thresholds that colour the rings, set under Display. A window resetting re-arms it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Limits")
            }

            Section {
                budgetField("Daily", value: $dailyBudget)
                budgetField("Monthly", value: $monthlyBudget)
                Text("Zero turns a budget off. Setting one is the opt-in for its alert as well — a target you can see a bar for but never hear about is a decoration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("On Pro and Max plans this is notional equivalent API spend, not money you were charged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Budget")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// A plain currency field rather than a stepper: budgets are round numbers
    /// somebody types once, not values anybody nudges.
    private func budgetField(_ label: String, value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            .multilineTextAlignment(.trailing)
    }
}
