import SwiftUI
import HarborCore

struct CredentialRow: View {
    @EnvironmentObject var model: AppModel
    let assistant: Assistant
    var title = "API key"
    @State private var showEntry = false
    @State private var confirmRemoval = false
    @State private var removalError: String?
    private var saved: Bool { !(model.apiKeys[assistant] ?? "").isEmpty }
    private var working: Bool { model.credentialOperations.contains(assistant) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack(spacing: 10) {
                    if working { ProgressView().controlSize(.small) }
                    else {
                        Text(saved ? "Saved in Keychain" : model.credentialErrors[assistant] == nil ? "Not set" : "Access unavailable")
                            .foregroundStyle(.secondary)
                    }
                    Button(saved ? "Replace…" : "Set API Key…") { removalError = nil; showEntry = true }
                    if saved { Button("Remove…", role: .destructive) { confirmRemoval = true }.foregroundStyle(.red) }
                    if model.credentialErrors[assistant] != nil {
                        Button("Retry") { removalError = nil; Task { await model.reloadCredential(assistant) } }
                    }
                }.disabled(working)
            }
            if let message = removalError ?? model.credentialErrors[assistant] {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showEntry) { CredentialEntryView(assistant: assistant).environmentObject(model) }
        .onChange(of: model.apiKeys[assistant]) { removalError = nil }
        .confirmationDialog("Remove the saved key for \(assistant.rawValue)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                Task { removalError = await model.removeCredential(assistant) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Future tasks will need a new key. Existing workspaces and history are kept. A running task keeps its current credential until the workspace stops.")
        }
    }
}

struct CredentialEntryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let assistant: Assistant
    @State private var draft = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(assistant.rawValue) API key").font(.title2.weight(.semibold))
            Text("Save once in macOS Keychain to use it across your Harbor workspaces and future app launches.")
                .foregroundStyle(.secondary)
            SecureField("Paste your API key", text: $draft).focused($focused).privacySensitive()
                .onChange(of: draft) { error = nil }
            Text("Saving does not send a request or verify the key with the provider. API usage is billed separately.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { draft = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Key") {
                    saving = true
                    Task {
                        error = await model.saveCredential(draft, for: assistant)
                        saving = false
                        if error == nil { draft = ""; dismiss() }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460)
            .disabled(saving).interactiveDismissDisabled(saving)
            .onAppear { focused = true }
            .onDisappear { draft = "" }
    }
}

struct AssistantCredentialsSection: View {
    var body: some View {
        Section {
            ForEach(Assistant.allCases) { assistant in
                CredentialRow(assistant: assistant, title: assistant.rawValue)
            }
        } header: { Text("Assistant credentials") } footer: {
            Text("Harbor saves keys in this Mac’s Keychain and reuses them across workspaces. Running assistants can access their selected key; Harbor does not save it with workspace metadata.")
        }
    }
}
