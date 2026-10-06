import SwiftUI
import HarborCore

enum PromptMode: String, CaseIterable, Identifiable, Codable {
    case newTask = "New Task"
    case followup = "Follow-up"
    var id: String { rawValue }
}

struct PromptComposer: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    @State private var showFullPrompt = false
    @State private var confirmReplace = false
    private var runningTask: Bool { model.taskTokens[workspace.id] != nil }
    private var mode: PromptMode { runningTask ? .followup : model.composerModes[workspace.id] ?? .newTask }
    private var draft: Binding<String> {
        Binding(get: { mode == .followup ? model.followupPrompts[workspace.id] ?? "" : model.prompts[workspace.id] ?? "" }, set: {
            if mode == .followup { model.followupPrompts[workspace.id] = $0 } else { model.prompts[workspace.id] = $0 }
        })
    }
    private var status: String {
        if model.stoppingTasks.contains(workspace.id) { return "Stopping task…" }
        if workspace.state == .starting { return "Preparing task…" }
        if runningTask { return model.taskOutcomes[workspace.id] == "Preparing" ? "Preparing follow-up…" : "Current task · working" }
        return "Last task · " + (model.taskOutcomes[workspace.id] ?? "Submitted")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let submitted = model.submittedPrompts[workspace.id] {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if runningTask { ProgressView().controlSize(.small) }
                        Text(status).font(.headline)
                        Spacer()
                        Label("Submitted", systemImage: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(submitted).lineLimit(showFullPrompt ? nil : 3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if submitted.count > 180 { Button(showFullPrompt ? "Show Less" : "Show Full Prompt") { showFullPrompt.toggle() }.controlSize(.small) }
                    if let start = model.taskStartedAt[workspace.id] {
                        let elapsed = max(0, Int((model.taskEndedAt[workspace.id] ?? Date()).timeIntervalSince(start)))
                        Text("\(elapsed / 60)m \(elapsed % 60)s elapsed · includes preparation").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text("Latest task activity: " + (model.taskLastActivity[workspace.id] ?? "Waiting for assistant output…")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    Text(runningTask ? "This prompt is already running. Drafts below do not change it." : "Working files reflect the task’s changes. Review the preview or Activity before continuing.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if !runningTask && (mode == .followup || model.submittedPrompts[workspace.id] != nil || !(model.followupPrompts[workspace.id] ?? "").isEmpty) {
                Picker("Draft type", selection: Binding(get: { mode }, set: { model.composerModes[workspace.id] = $0 })) {
                    ForEach(PromptMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(mode == .followup ? "Draft your next message" : "New task draft").font(.system(size: 12)).foregroundStyle(.secondary)
                PromptTextEditor(text: draft).frame(height: 100)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                    .accessibilityLabel(mode == .followup ? "Follow-up draft" : "New task draft")
                Text(mode == .followup ? "This is a separate message, not an edit to the submitted prompt. Send after the current task finishes or stops." : "Starts a fresh conversation. The current task must finish or stop first.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !draft.wrappedValue.isEmpty {
                    if let error = model.draftErrors[workspace.id] {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                        if model.canRetryDraftSave(workspace.id) {
                            Button("Retry Saving Draft") { model.saveDraft(workspace.id) }.controlSize(.small)
                        }
                    } else if model.savedDrafts.contains(workspace.id) {
                        Label("Draft saved · Not sent", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                            .help("Saved locally on this Mac in Harbor’s hidden drafts folder as a text file. Nothing is sent until you submit.")
                    }
                } else if let error = model.draftErrors[workspace.id] {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    if model.canRetryDraftSave(workspace.id) {
                        Button("Retry Saving Draft") { model.saveDraft(workspace.id) }.controlSize(.small)
                    }
                }
                if mode == .followup, !(model.followupPrompts[workspace.id] ?? "").isEmpty, !model.canFollowUp(workspace), !runningTask {
                    Button("Use Draft as New Task") {
                        if !(model.prompts[workspace.id] ?? "").isEmpty && model.prompts[workspace.id] != model.followupPrompts[workspace.id] { confirmReplace = true }
                        else { useAsNewTask() }
                    }.controlSize(.small)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .confirmationDialog("Replace the existing New Task draft?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace Draft", role: .destructive) { useAsNewTask() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your follow-up will replace the text saved in the New Task draft. The submitted prompt and working files are kept.") }
    }
    private func useAsNewTask() {
        model.prompts[workspace.id] = model.followupPrompts[workspace.id]
        model.composerModes[workspace.id] = .newTask
    }
}
