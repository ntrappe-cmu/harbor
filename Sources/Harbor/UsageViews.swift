import SwiftUI
import HarborCore

struct UsageIndicator: View {
    @EnvironmentObject var model: AppModel
    let assistant: Assistant
    let openSettings: () -> Void
    @State private var details = false
    @State private var dismissedWarning: String?
    private var preference: UsagePreference { model.usageLedger.preference(assistant) }
    private var summary: UsageSummary { model.usageLedger.summary(assistant) }
    private var remaining: Double? { model.usageLedgerError == nil ? (model.usageLedger.isDemo ? model.usageLedger.demoBalance : summary.remaining(budget: preference.monthlyBudgetUSD)) : nil }
    private var capacity: Double { model.usageLedger.isDemo ? 40 : preference.monthlyBudgetUSD }
    private var low: Bool { model.usageLedger.isDemo ? model.usageLedger.demoBalance <= 8 : preference.monthlyBudgetUSD > 0 && summary.reportedCost >= preference.monthlyBudgetUSD * 0.8 }
    private var warningKey: String { "\(assistant.rawValue)-\(preference.monthlyBudgetUSD)-\(summary.reportedCost)-\(model.usageLedger.demoTotalSpent)-\(model.usageLedger.isDemo)" }
    var body: some View {
        if preference.showOverview {
            HStack(spacing: 8) {
                if let remaining {
                    Text(model.usageLedger.isDemo ? "Demo remaining" : "Budget remaining").font(.system(size: 12)).foregroundStyle(.secondary)
                    ProgressView(value: remaining, total: capacity)
                        .tint(remaining <= capacity * 0.2 ? .orange : .accentColor)
                        .frame(maxWidth: 140).accessibilityLabel("Remaining Harbor budget")
                    Text("~\(remaining.formatted(.currency(code: "USD"))) left").font(.system(size: 12)).monospacedDigit()
                } else {
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button { details = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).accessibilityLabel("Usage details")
                    .popover(isPresented: $details) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(assistant.rawValue) · Harbor usage").font(.headline)
                            if model.usageLedger.isDemo {
                                Text("Demo starts with $40 shared across assistants. Each task deducts a synthetic estimate: $0.50 + $1 per 2,000 prompt bytes, up to $5. This is not your account balance or a pricing estimate. Real API charges still apply.")
                                Text("Next task estimate: \(UsageLedger.demoEstimate(prompt: model.selected.flatMap { model.composerModes[$0.id] == .followup ? model.followupPrompts[$0.id] : model.prompts[$0.id] } ?? "").formatted(.currency(code: "USD")))")
                            }
                            Text("This calendar month: \(summary.count) tracked tasks; at least \(summary.reportedCost.formatted(.currency(code: "USD"))) reported cost.")
                            Text("Only new tasks run through Harbor are tracked. Earlier tasks and usage in other apps are excluded. Costs appear when the assistant reports them, usually after a task finishes. Tasks are assigned to the month they start.")
                            if summary.missingCosts > 0, !model.usageLedger.isDemo { Text("\(summary.missingCosts) task(s) have no confirmed final cost. Remaining budget cannot be calculated.") }
                            if let date = summary.lastReport { Text("Latest report received: \(date.formatted(date: .abbreviated, time: .shortened))") }
                            if let error = model.usageLedgerError { Text(error).foregroundStyle(.orange) }
                            Text("This is your own warning budget, not a provider balance or enforced spending cap.").foregroundStyle(.secondary)
                            HStack {
                                Button("Usage Settings", action: openSettings)
                                Button("Hide") { model.setUsagePreference(assistant) { $0.showOverview = false }; details = false }
                            }
                        }.font(.system(size: 12)).padding(16).frame(width: 330)
                    }
                Spacer(minLength: 0)
            }
        }
        if preference.warnWhenLow, low, dismissedWarning != warningKey {
            HStack(alignment: .top) {
                Label(warningText, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                Spacer()
                Button("Dismiss") { dismissedWarning = warningKey }.controlSize(.small)
            }
        }
    }
    private var warningText: String {
        if model.usageLedger.isDemo { return "Demo balance is low. This is simulated; real API charges are separate." }
        if summary.missingCosts > 0 { return "At least \(summary.reportedCost.formatted(.currency(code: "USD"))) reported. Your spending warning threshold is near or reached; some costs are missing." }
        return summary.reportedCost >= preference.monthlyBudgetUSD ? "Monthly spending warning reached. Tasks can still incur charges." : "Monthly spending warning nearly reached. Tasks can still incur charges."
    }
    private var status: String {
        if model.usageLedgerError != nil { return "Usage history unavailable" }
        if preference.monthlyBudgetUSD == 0 { return "Harbor usage · Details" }
        if summary.active { return "Harbor usage · Task cost pending" }
        if summary.missingCosts > 0 { return "Harbor usage · Cost not fully reported" }
        return "Harbor usage · Details"
    }
}

struct UsageSettingsSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section {
            Toggle("Use simulated $40 demo balance", isOn: Binding(get: { model.usageLedger.isDemo }, set: { model.setDemoUsage($0) }))
            if model.usageLedger.isDemo { Text("$40 starting balance shared across assistants. \(model.usageLedger.demoTotalSpent.formatted(.currency(code: "USD"))) estimated across tracked tasks. No real credits are provided.").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(Assistant.allCases) { assistant in
                UsagePreferenceView(assistant: assistant)
            }
            if let error = model.usageLedgerError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } header: { Text("AI usage · all Harbor workspaces") } footer: {
            Text("Monthly spending warnings in USD. They do not stop tasks or change provider limits. Only reported costs from new Harbor tasks are tracked; missing costs prevent a remaining estimate. Manage payments and account limits on your provider’s website.")
        }
    }
}

private struct UsagePreferenceView: View {
    @EnvironmentObject var model: AppModel
    let assistant: Assistant
    @State private var editBudget = false
    @State private var amount = ""
    private var preference: UsagePreference { model.usageLedger.preference(assistant) }
    private var summary: UsageSummary { model.usageLedger.summary(assistant) }
    private var parsed: Double? { Double(amount).flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 ? $0 : nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(assistant.rawValue).font(.headline)
                Spacer()
                Button(preference.monthlyBudgetUSD == 0 ? "Set Monthly Spending Warning…" : "Edit \(preference.monthlyBudgetUSD.formatted(.currency(code: "USD"))) Warning…") {
                    amount = String(preference.monthlyBudgetUSD); editBudget = true
                }
            }
            Text("This month · \(summary.count) tracked tasks · At least \(summary.reportedCost.formatted(.currency(code: "USD"))) reported\(summary.missingCosts > 0 ? " · \(summary.missingCosts) final costs unconfirmed" : "")")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let latest = model.usageLedger.entries.last(where: { $0.assistant == assistant }), let usage = latest.usage {
                Text("Latest task report: \(usage.inputTokens) input / \(usage.outputTokens) output tokens. Tokens used do not indicate tokens remaining.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Toggle("Show \(assistant.rawValue) usage on Overview", isOn: Binding(get: { preference.showOverview }, set: { value in model.setUsagePreference(assistant) { $0.showOverview = value } }))
            Toggle("Warn near spending threshold or low demo balance", isOn: Binding(get: { preference.warnWhenLow }, set: { value in model.setUsagePreference(assistant) { $0.warnWhenLow = value } }))
                .disabled(preference.monthlyBudgetUSD == 0 && !model.usageLedger.isDemo)
            Link("Manage \(assistant.rawValue) Billing ↗", destination: URL(string: assistant == .codex ? "https://platform.openai.com/settings/organization/billing/overview" : "https://platform.claude.com/settings/billing")!)
        }.padding(.vertical, 4)
            .disabled(model.usageLedgerError != nil)
            .sheet(isPresented: $editBudget) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(assistant.rawValue) Monthly Spending Warning").font(.headline)
                    TextField("Amount in USD", text: $amount)
                    Text("Enter 0 to turn off the budget. This warning does not enforce a spending limit.").font(.system(size: 12)).foregroundStyle(.secondary)
                    if parsed == nil { Text("Enter an amount from 0 to 1,000,000 in USD.").foregroundStyle(.red) }
                    HStack { Spacer(); Button("Cancel") { editBudget = false }; Button("Save") {
                        if let value = parsed { model.setUsagePreference(assistant) { $0.monthlyBudgetUSD = value }; editBudget = false }
                    }.keyboardShortcut(.defaultAction).disabled(parsed == nil) }
                }.padding(20).frame(width: 390)
            }
    }
}
