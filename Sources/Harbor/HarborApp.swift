import SwiftUI
import HarborCore
import ScreenCaptureKit
import CoreGraphics

@main struct HarborApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .frame(minWidth: 780, minHeight: 600)
                .onAppear {
                    delegate.model = model
                    // Development-only visual QA of this app's own window.
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "--smoke-shot"), index + 1 < args.count {
                        let output = args[index + 1]
                        Task { @MainActor in
                            if model.workspaces.isEmpty { await model.create(name: "Checkout prototype", source: nil) }
                            if let promptIndex = args.firstIndex(of: "--smoke-prompt"), promptIndex + 1 < args.count, let id = model.selection {
                                model.prompts[id] = args[promptIndex + 1]
                            }
                            try? await Task.sleep(for: .seconds(2))
                            if await captureOwnWindow(to: URL(fileURLWithPath: output)) { return }
                            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }), let view = window.contentView,
                                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: output)) }
                        }
                    }
                }
        }
        .defaultSize(width: 980, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…") { NotificationCenter.default.post(name: .newWorkspace, object: nil) }
                    .keyboardShortcut("n")
            }
        }
        Settings { DefaultsView().environmentObject(model).frame(width: 620, height: 460) }
    }
}

// Developer-only capture. Never prompts for screen access or captures another app.
@MainActor private func captureOwnWindow(to destination: URL) async -> Bool {
    guard CGPreflightScreenCaptureAccess(),
          let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else { return false }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.windowID == CGWindowID(window.windowNumber)
        }) else { return false }
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * 2); config.height = Int(target.frame.height * 2)
        config.showsCursor = false
        let capture = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        guard let data = NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:]) else { return false }
        try data.write(to: destination)
        return true
    } catch { return false }
}

extension Notification.Name { static let newWorkspace = Notification.Name("Harbor.newWorkspace") }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.preparing {
            let alert = NSAlert()
            if !model.preparingBuild && !model.cancelingPreparation {
                alert.messageText = "Workspace tools are still preparing"
                alert.informativeText = "Wait for service startup to finish. You can cancel when the build starts."
                alert.addButton(withTitle: "Keep Harbor Open")
                alert.runModal()
                return .terminateCancel
            }
            alert.messageText = "Cancel preparation before quitting?"
            alert.informativeText = "Harbor will interrupt its build command and check installed tools before closing. The shared builder may remain running."
            alert.addButton(withTitle: "Cancel Build and Quit"); alert.addButton(withTitle: "Keep Harbor Open")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            Task {
                model.cancelPreparation()
                while model.preparing { try? await Task.sleep(for: .milliseconds(50)) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        guard model.workspaces.contains(where: { $0.runID != nil }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop your workspace before quitting?"
        alert.informativeText = "Harbor will stop the workspace’s tools and preserve its working files."
        alert.addButton(withTitle: "Stop and Quit"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            for w in model.workspaces where w.runID != nil { await model.stop(w.id) }
            sender.reply(toApplicationShouldTerminate: !model.workspaces.contains(where: { $0.runID != nil }))
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var newWorkspace = false
    @State private var pendingDeletion: UUID?
    private var deletionTarget: Workspace? { model.workspaces.first { $0.id == pendingDeletion } }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Workspaces") {
                    ForEach(model.workspaces) { workspace in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.name).lineLimit(1)
                                Text(workspace.state == .ready && !model.environmentReady ? "Setup needed" : workspace.state.label).font(.system(size: 12)).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        } icon: { Image(systemName: "square.stack.3d.up").foregroundStyle(.tint) }
                        .tag(workspace.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { pendingDeletion = workspace.id }
                                .disabled(model.busy || model.preparing || workspace.state == .starting || workspace.state == .stopping)
                        }
                        .contextMenu {
                            Button("Delete Workspace…", role: .destructive) { pendingDeletion = workspace.id }
                                .foregroundStyle(.red)
                                .disabled(model.busy || model.preparing || workspace.state == .starting || workspace.state == .stopping)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button { newWorkspace = true } label: { Label("New Workspace", systemImage: "plus") }.frame(maxWidth: .infinity).disabled(model.storageBlocked)
                }.padding()
            }
        } detail: {
            if let workspace = model.selected {
                WorkspaceView(workspace: workspace).id(workspace.id)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 46, weight: .light)).foregroundStyle(.tint)
                    Text("A little room to experiment.").font(.largeTitle.weight(.semibold))
                    Text("Give your assistant a working copy.\nKeep control of your files and your Mac.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Create a Workspace") { newWorkspace = true }.disabled(model.storageBlocked).buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Your original files stay where they are.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Harbor")
        .sheet(isPresented: $newWorkspace) { NewWorkspaceView().environmentObject(model) }
        .alert("Delete “\(deletionTarget?.name ?? "workspace")”?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: deletionTarget) { target in
            Button(target.runID == nil ? "Delete Workspace" : "Stop and Delete", role: .destructive) {
                Task { await model.deleteWorkspace(target.id) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { target in
            Text((target.runID == nil ? "No active workspace session. " : "Harbor must stop this workspace session, including its assistant, preview, and any tools inside it, before deleting. The entire session must stop before deletion. ") + "Its working files, saved versions, and workspace history will be permanently deleted. Imported originals and exported copies are kept.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkspace)) { _ in newWorkspace = true }
        .alert(model.errorTitle, isPresented: Binding(get: { model.error != nil && !newWorkspace }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    @State private var tab: Int = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--smoke-shot"), let index = args.firstIndex(of: "--smoke-tab"), index + 1 < args.count else { return 0 }
        return Int(args[index + 1]) ?? 0
    }()
    @State private var showDetails = false
    @State private var confirmRun = false
    @State private var showChanges = false
    @State private var confirmRestore = false
    @State private var confirmClearHistory = false
    var unresolved: Bool { model.workspaces.contains { $0.runID != nil } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.name).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(workspace.state.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Picker("Workspace section", selection: $tab) { Text("Overview").tag(0); Text("Settings").tag(1); Text("Activity").tag(2) }
                .labelsHidden().pickerStyle(.segmented).frame(width: 320).padding(.bottom, 10)
            Divider()
            Form {
                if tab == 0 { overview } else if tab == 1 { settings } else { activity }
            }.formStyle(.grouped)
        }
        .confirmationDialog("Start with \(workspace.assistant.rawValue)?", isPresented: $confirmRun, titleVisibility: .visible) {
            Button(workspace.runID == nil ? "Start New Task" : "Stop Workspace and Start New Task") { Task { await model.runDraft(workspace.id) } }
        } message: {
            Text((workspace.runID == nil ? "" : "The current workspace and preview will stop first. Working files are kept, then your current draft starts a fresh conversation. ") + "Tools run in a local Linux workspace. The assistant can send project content to its cloud provider and has internet access. API usage is billed separately. Only use trusted projects; credentials are available to the assistant inside the workspace.")
        }
        .confirmationDialog("Restore the previous version?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore", role: .destructive) { Task { await model.restoreSelected() } }
        } message: { Text("This replaces your working files with the copy saved before the last run. Export the current version first if you want to keep it.") }
        .confirmationDialog("Clear saved prompt history?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.update(workspace.id) { $0.promptHistory = [] } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Deletes this workspace’s saved prompts. Your current draft and running task are kept.") }
        .sheet(isPresented: $showChanges) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Changes since the last run").font(.title2.weight(.semibold))
                Text("A file-level comparison. Open the working files to inspect their contents.").foregroundStyle(.secondary)
                if model.busy { ProgressView() }
                else if model.changes.isEmpty { Text("No file changes found.").padding(.vertical) }
                else {
                    List(model.changes) { change in
                        HStack { Text(change.path).lineLimit(2); Spacer(); Text(change.kind).foregroundStyle(.secondary) }
                    }.frame(height: 260)
                }
                HStack { Spacer(); Button("Done") { showChanges = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 520)
        }
    }
    private var statusColor: Color {
        switch workspace.state {
        case .ready: return model.environmentReady ? .green : .gray
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed, .interrupted: return .red
        case .stopped, .completed: return .gray
        }
    }
    @ViewBuilder var overview: some View {
        Section {
            LabeledContent("Working folder", value: model.store.project(for: workspace.id).lastPathComponent)
            LabeledContent("Performance", value: workspace.performanceTitle)
            if let seconds = workspace.remainingSeconds(at: Date()), workspace.state.isActive {
                LabeledContent("Time remaining") {
                    Text("\(seconds / 60)m \(seconds % 60)s").monospacedDigit()
                    Button("Add 15 min") { Task { await model.extendRun(workspace.id) } }.controlSize(.small).disabled(workspace.state != .running || model.extendingRuns.contains(workspace.id) || model.storageBlocked)
                }
            } else { LabeledContent("Run allowance", value: "\(workspace.minutes) minutes") }
        }
        Section {
            Picker("Assistant", selection: binding(\.assistant)) {
                ForEach(Assistant.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(model.taskTokens[workspace.id] != nil || [.starting, .stopping].contains(workspace.state) || model.transitioningTask || model.busy || model.storageBlocked)
            UsageIndicator(assistant: workspace.assistant, openSettings: { tab = 1 })
            PromptComposer(workspace: workspace).disabled(model.transitioningTask)
            if model.taskTokens[workspace.id] == nil {
                HStack {
                    if model.composerModes[workspace.id] == .followup {
                        Button("Send Follow-up") { Task { await model.followUp(workspace.id) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.runBlockReason(workspace, for: .followup) != nil)
                            .help("Sends only the follow-up draft after the current task has finished or stopped.")
                    } else {
                        Button("Start New Task") { confirmRun = true }.buttonStyle(.borderedProminent)
                            .disabled(model.runBlockReason(workspace) != nil)
                    }
                    Button("Preview Only") {
                        Task {
                            await model.start(previewOnly: true, workspaceID: workspace.id)
                            await model.checkPreview(workspace.id)
                            if model.previewHealth[workspace.id] == .available {
                                NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(workspace.effectivePreviewPort)")!)
                            }
                        }
                    }.disabled(!workspace.canPreview || unresolved || !model.environmentReady || model.preparing || model.busy || model.storageBlocked)
                    Spacer()
                }
            }
            if model.taskTokens[workspace.id] == nil, let reason = model.runBlockReason(workspace, for: model.composerModes[workspace.id] ?? .newTask) {
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if workspace.runID != nil {
                HStack {
                    if model.taskTokens[workspace.id] != nil {
                        Button(model.stoppingTasks.contains(workspace.id) ? "Stopping Task…" : model.taskStopFailures.contains(workspace.id) ? "Retry Stop Task" : "Stop Task", role: .destructive) { Task { await model.cancelTask(workspace.id) } }
                            .foregroundStyle(.red).disabled(workspace.state != .running || model.stoppingTasks.contains(workspace.id))
                            .help("Stops the assistant and its tagged tools. Keeps the workspace and preview running.")
                    }
                    Spacer()
                    Button(workspace.state == .interrupted ? "Retry Stop Workspace" : "Stop Workspace", role: .destructive) { Task { await model.stop(workspace.id) } }
                        .foregroundStyle(.red).disabled(workspace.state == .stopping || model.transitioningTask)
                }
                Text("Stop Task keeps the preview open. Stop Workspace ends tools, preview, and the conversation; your files stay saved.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if (model.apiKeys[workspace.assistant] ?? "").isEmpty {
                Button("Set up \(workspace.assistant.rawValue) in Settings") { tab = 1 }
            }
            if let history = workspace.promptHistory, !history.isEmpty {
                DisclosureGroup("Task history (\(history.count))") {
                    Text("Recent prompts are saved on this Mac. Saved text may be truncated or have known keys redacted; review reused drafts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(history.reversed()) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text).lineLimit(2).textSelection(.enabled)
                            if let outcome = item.outcome {
                                HStack {
                                    Text(outcome)
                                    if let elapsed = item.elapsedSeconds { Text("· \(elapsed / 60)m \(elapsed % 60)s elapsed") }
                                }.font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if let activity = item.latestActivity { Text(activity).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                            HStack {
                                Text(item.assistant.rawValue).foregroundStyle(.secondary)
                                Spacer()
                                Button("Use as New Task Draft") { model.prompts[workspace.id] = item.text; model.composerModes[workspace.id] = .newTask }.disabled(model.taskTokens[workspace.id] != nil)
                            }.font(.system(size: 12))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            }
        } header: { Text("Give your assistant a task") } footer: {
            Text("New Task starts a fresh conversation. Send Follow-up continues the selected assistant’s conversation while this workspace stays running. Provider charges apply. Preview Only opens existing files without an AI request.")
        }
        if !model.environmentReady { Button("Prepare Workspace in Settings") { tab = 1 } }
        Section("Your work") {
            HStack {
                Button { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(workspace.effectivePreviewPort)")!) } label: { Label("Open Preview", systemImage: "safari") }
                    .disabled(model.previewHealth[workspace.id] != .available || workspace.state != .running)
                Button { NSWorkspace.shared.open(model.store.project(for: workspace.id)) } label: { Label("Working Files", systemImage: "folder") }
                Spacer()
                Button("Export Copy…") { Task { await model.exportSelected() } }.disabled(workspace.runID != nil || model.busy)
            }
            HStack {
                Label((workspace.runID == nil ? PreviewHealth.unavailable : model.previewHealth[workspace.id] ?? .checking).rawValue, systemImage: model.previewHealth[workspace.id] == .available ? "checkmark.circle" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Check Preview") { Task { await model.checkPreview(workspace.id) } }.disabled(workspace.state != .running)
            }
            Text("The preview supports static HTML, CSS, and JavaScript. Stop the workspace before exporting a consistent copy.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.store.hasCheckpoint(workspace) {
                HStack {
                    Button("Review Changes…") { showChanges = true; Task { await model.reviewChanges() } }
                    Button("Restore Previous Version…", role: .destructive) { confirmRestore = true }.foregroundStyle(.red)
                }.disabled(workspace.runID != nil || model.busy)
            }
        }
        WorkspaceStatusView(workspace: workspace, project: model.store.project(for: workspace.id))
    }
    @ViewBuilder var activity: some View {
        Section("Current run · status and problems") {
            if [.failed, .interrupted].contains(workspace.state) {
                Label("The last run did not finish normally", systemImage: "exclamationmark.triangle")
            }
            Text(workspace.lastMessage).textSelection(.enabled)
            if (workspace.problems ?? []).isEmpty { Text("No problems reported for the current task.").foregroundStyle(.secondary) }
            ForEach((workspace.problems ?? []).reversed()) { problem in
                VStack(alignment: .leading, spacing: 4) {
                    Label(problem.title, systemImage: "exclamationmark.triangle").font(.headline)
                    Text(problem.detail).textSelection(.enabled)
                    Text(problem.date, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("Harbor reports run and tool errors here. It does not scan generated code for security problems.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Section("Current run · activity") {
            if workspace.state == .starting || workspace.state == .stopping { ProgressView().controlSize(.small) }
            ForEach(workspace.groupedActivity, id: \.text) { message in
                ActivityMessageRow(message: message)
            }
            DisclosureGroup("Assistant output and error logs", isExpanded: $showDetails) {
                Text("Identical lines in the retained output are grouped. Counts exclude older output that has been trimmed.").font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let output = model.logs[workspace.id] ?? ""
                        if output.isEmpty { Text("No assistant output yet.").foregroundStyle(.secondary) }
                        ForEach(ActivityMessage.grouped(output.components(separatedBy: "\n")), id: \.text) { message in
                            ActivityMessageRow(message: message, monospaced: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                    .frame(height: 180)
            }
        }
        if !(workspace.previousProblems ?? []).isEmpty || !(workspace.previousEvents ?? []).isEmpty {
            Section {
                DisclosureGroup("Previous runs and issues") {
                    ForEach((workspace.previousProblems ?? []).reversed()) { problem in
                        VStack(alignment: .leading) {
                            Text(problem.title).font(.headline)
                            Text(problem.detail).textSelection(.enabled)
                            Text(problem.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(workspace.groupedPreviousActivity.enumerated()), id: \.offset) { _, message in
                        ActivityMessageRow(message: message)
                    }
                }
            }
        }
    }
    @ViewBuilder var settings: some View {
        Section {
            TextField("Name", text: binding(\.name)).disabled(model.busy || model.storageBlocked)
            LabeledContent("Imported from", value: workspace.sourceDescription)
            Button("Show Working Files") { NSWorkspace.shared.open(model.store.project(for: workspace.id)) }
            Button("Clear Prompt History…", role: .destructive) { confirmClearHistory = true }
                .foregroundStyle(.red).disabled((workspace.promptHistory ?? []).isEmpty || model.storageBlocked || model.busy)
        } header: { Text("Project") } footer: { Text("Imported files are copied. Linked files, common credentials, and dependency folders are skipped. This is not a complete secret scan.") }
        Section {
            Picker("Work for", selection: binding(\.minutes)) { ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) } }
                .disabled(workspace.runID != nil)
            Picker("Performance", selection: Binding(get: { workspace.performance }, set: { preset in
                model.update(workspace.id) { $0.performance = preset
                    $0.cpuOverride = preset.cpus > HostCapacity.current.cpus ? HostCapacity.current.cpus : nil
                    $0.memoryOverride = preset.memoryGiB > HostCapacity.current.memoryGiB ? HostCapacity.current.memoryGiB : nil }
            })) { ForEach(Performance.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).disabled(workspace.runID != nil)
            if workspace.performanceTitle == "Custom" { Button("Reset to \(workspace.performance.title)") { model.update(workspace.id) { $0.cpuOverride = $0.performance.cpus > HostCapacity.current.cpus ? HostCapacity.current.cpus : nil; $0.memoryOverride = $0.performance.memoryGiB > HostCapacity.current.memoryGiB ? HostCapacity.current.memoryGiB : nil } }.disabled(workspace.runID != nil) }
            ResourceSlider(title: "CPU cores", value: Binding(get: { Double(workspace.cpuLimit) }, set: { value in
                model.update(workspace.id) { $0.cpuOverride = Int(value) }
            }), range: 1...Double(max(2, HostCapacity.current.cpus)), unit: "cores")
                .disabled(workspace.runID != nil)
            ResourceSlider(title: "Memory", value: Binding(get: { Double(workspace.memoryLimit) }, set: { value in
                model.update(workspace.id) { $0.memoryOverride = Int(value) }
            }), range: 1...Double(max(2, HostCapacity.current.memoryGiB)), unit: "GB")
                .disabled(workspace.runID != nil)
            AccessInfoRow(title: "Parallelism", value: "Managed by the assistant", explanation: "CPU cores let local tools do more work at once. They do not set the number of AI agents. Harbor currently runs one task at a time; an agent concurrency control is not available.")
            Text("More local resources can help builds and tools. They do not make the cloud model smarter or increase its token budget.").font(.system(size: 12)).foregroundStyle(.secondary)
            if workspace.cpuLimit > ProcessInfo.processInfo.activeProcessorCount || workspace.memoryLimit > max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) - 2) {
                Label("These limits are too high for this Mac. Reduce CPU or memory before starting; Harbor leaves at least 2 GB for macOS.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
        } header: { Text("Run limits") } footer: {
            Text("Applied on the next start. CPU and memory cannot be resized during a run. You can extend an active run from Overview.")
        }
        .disabled(model.busy || model.storageBlocked)
        Section {
            Picker("Warn when working files exceed", selection: Binding(get: { workspace.storageWarningMiB ?? 0 }, set: { value in
                model.update(workspace.id) { $0.storageWarningMiB = value == 0 ? nil : value }
            })) {
                Text("Off").tag(0); Text("256 MB").tag(256); Text("1 GB").tag(1024); Text("5 GB").tag(5120); Text("10 GB").tag(10240)
            }.disabled(model.busy || model.storageBlocked)
            Text("Changes apply immediately. Checked approximately every 30 seconds while this workspace is selected. Does not stop writes or reserve disk space.").font(.system(size: 12)).foregroundStyle(.secondary)
        } header: { Text("Storage warning") }
        Section {
            AccessInfoRow(title: "Files", value: "Working copy only", explanation: "Only this workspace’s copied files are mounted. Your home folder and host control sockets are not shared. Imported files are not fully scanned for secrets.")
            Toggle("Allow changes to working files", isOn: binding(\.fileChangesAllowed, default: true))
            Text("Off makes the working folder read-only for all tools in the workspace. Useful for reviews; editing, installs, and builds that write there will fail. Temporary files elsewhere in the guest remain writable.").font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("Allow low-level system tools", isOn: binding(\.lowLevelToolsAllowed, default: false))
            Text("Off restricts raw network sockets, mounts, and privileged system operations using Linux capabilities. Ordinary coding tools and HTTPS still work. Some debuggers and network diagnostics may fail. On uses the runtime’s default permissions; it does not grant full privileges.").font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("Internet", isOn: Binding(get: { workspace.allowsInternet }, set: { value in model.update(workspace.id) { $0.internetAllowed = value } }))
            AccessInfoRow(title: "Internet access", value: workspace.allowsInternet ? "On" : "Off", explanation: "Off removes network interfaces on the next start. Cloud assistants and browser preview are unavailable offline. On allows outgoing connections; it is not a domain allowlist.")
            AccessInfoRow(title: "AI processing", value: "Cloud provider", explanation: "Claude and Codex send prompts and relevant project content to their providers. Local CPU and memory limits apply to tools on your Mac, not to model inference or API charges.")
            Toggle("Browser preview", isOn: Binding(get: { workspace.previewEnabled ?? true }, set: { value in model.update(workspace.id) { $0.previewEnabled = value } })).disabled(!workspace.allowsInternet)
            TextField("Local preview port", value: Binding(get: { workspace.effectivePreviewPort }, set: { value in model.update(workspace.id) { $0.previewPort = value } }), format: .number.grouping(.never))
                .disabled(!workspace.canPreview)
            AccessInfoRow(title: "Preview access", value: workspace.canPreview ? "This Mac · port \(workspace.effectivePreviewPort)" : "Off", explanation: "Uses a localhost-only published port (1024–65535), applied on the next start. The guest server may still be reachable through the runtime’s virtual network while Internet is on; this toggle controls the published localhost port, not a firewall.")
        } header: { Text("Access") } footer: {
            Text("Applied on the next start. Stop the workspace before changing access. No host home folder is mounted. Isolation does not verify generated code or prevent data sent through allowed connections.")
        }
        .disabled(workspace.runID != nil || model.busy || model.storageBlocked)
        RuntimePreparationSection()
        AssistantCredentialsSection()
        UsageSettingsSection()
    }
    func binding(_ keyPath: WritableKeyPath<Workspace, Bool?>, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { model.workspaces.first(where: { $0.id == workspace.id })?[keyPath: keyPath] ?? fallback },
                set: { value in model.update(workspace.id) { $0[keyPath: keyPath] = value } })
    }
    func binding<T>(_ keyPath: WritableKeyPath<Workspace, T>) -> Binding<T> {
        Binding(get: { model.workspaces.first(where: { $0.id == workspace.id })![keyPath: keyPath] },
                set: { value in model.update(workspace.id) { $0[keyPath: keyPath] = value } })
    }
}

struct NewWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var source: URL?
    @State private var creationError: String?
    @State private var showCreationError = false
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK {
            source = panel.url; creationError = nil
            if name.isEmpty, folderError == nil { name = source?.lastPathComponent ?? "" }
        }
    }
    private var nameError: String? { WorkspaceValidation.nameError(name) }
    private var folderError: String? { source.flatMap { WorkspaceValidation.sourceError($0, storeRoot: model.store.root) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Workspace").font(.title2.weight(.semibold))
            Text("A separate place for your assistant to experiment.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Portfolio website"))
                if !name.isEmpty, let nameError { Text(nameError).font(.system(size: 12)).foregroundStyle(.red) }
                LabeledContent("Start with") {
                    Text(source?.lastPathComponent ?? "A simple web starter").foregroundStyle(.secondary)
                    Button("Choose Folder…", action: chooseFolder)
                }
                if source != nil { Button("Use starter instead") { source = nil; creationError = nil } }
                if let folderError { Text(folderError).font(.system(size: 12)).foregroundStyle(.red) }
            }
            if let creationError {
                Label(creationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("Common secret files and symbolic links are excluded. Review the copy before sharing it with an AI service.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Create Workspace") {
                    Task {
                        creationError = await model.create(name: name, source: source)
                        if creationError == nil { dismiss() } else { showCreationError = true }
                    }
                }
                    .keyboardShortcut(.defaultAction).disabled(model.busy || nameError != nil || folderError != nil)
            }
        }.padding(28).frame(width: 500)
        .disabled(model.busy)
        .interactiveDismissDisabled(model.busy)
        .alert("Workspace couldn’t be created", isPresented: $showCreationError) {
            if source != nil {
                Button("Choose Another Folder…") {
                    DispatchQueue.main.async { chooseFolder() }
                }
            }
            Button("OK", role: .cancel) { }
        } message: { Text(creationError ?? "") }
    }
}

struct DefaultsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("Harbor Preview") {
                Text("A protected place to experiment with coding assistants.")
                LabeledContent("Execution", value: "On this Mac")
                LabeledContent("Supported assistants", value: "Claude Code and Codex")
                Text("This development build supports one running workspace at a time. Model requests use your provider’s API and are billed separately.").foregroundStyle(.secondary)
            }
            AssistantCredentialsSection()
            UsageSettingsSection()
            Section("Local storage") {
                Button("Show App Data") { NSWorkspace.shared.open(model.store.root) }

            }
        }.formStyle(.grouped)
    }
}
