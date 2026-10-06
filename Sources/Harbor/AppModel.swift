import SwiftUI
import HarborCore

@MainActor final class AppModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var selection: UUID?
    @Published var runtimePath: String?
    @Published var runtimeStatus = "Checking this Mac…"
    @Published var preparing = false
    @Published var preparingBuild = false
    @Published var checkingPreparedTools = false
    @Published var cancelingPreparation = false
    private var preparationBuildTask: Task<Void, Error>?
    private var preparationToken: UUID?
    @Published var environmentReady = false
    @Published var setupLog = ""
    @Published var error: String?
    @Published var busy = false
    @Published var storageBlocked = false
    @Published var errorTitle = "Harbor couldn’t complete the operation"
    @Published var readings: [UUID: ResourceReading] = [:]
    @Published var measurementErrors: [UUID: String] = [:]
    @Published var storageMeasurements: [UUID: StorageSummary] = [:]
    @Published var starterUnchanged: [UUID: Bool] = [:]
    @Published var storageMeasuredAt: [UUID: Date] = [:]
    @Published var storageMeasurementErrors: [UUID: String] = [:]
    @Published var extendingRuns: Set<UUID> = []
    private var polling = false
    private var nextPoll = Date.distantPast
    private var nextStoragePoll = Date.distantPast
    private var storagePolling: Set<UUID> = []
    private var creationInFlight: [UUID: UUID] = [:]
    @Published var transitioningTask = false
    private var stopRequested: Set<UUID> = []
    private var providerFailed = false
    @Published var logs: [UUID: String] = [:]
    @Published var usageLedger = UsageLedger()
    @Published var usageLedgerError: String?
    @Published var apiKeys: [Assistant: String] = [:]
    @Published var credentialOperations: Set<Assistant> = []
    @Published var credentialErrors: [Assistant: String] = [:]
    private let credentialStore: any CredentialStore
    @Published var prompts: [UUID: String] = [:] { didSet { saveChangedDrafts(old: oldValue, new: prompts) } }
    @Published var taskTokens: [UUID: UUID] = [:]
    @Published var followupPrompts: [UUID: String] = [:] { didSet { saveChangedDrafts(old: oldValue, new: followupPrompts) } }
    @Published var composerModes: [UUID: PromptMode] = [:] { didSet { saveChangedDrafts(old: oldValue, new: composerModes) } }
    @Published var draftErrors: [UUID: String] = [:]
    @Published var savedDrafts: Set<UUID> = []
    var loadingDrafts = false
    var unreadableDrafts: Set<UUID> = []
    @Published var taskStartedAt: [UUID: Date] = [:]
    @Published var taskLastActivity: [UUID: String] = [:]
    @Published var taskOutcomes: [UUID: String] = [:]
    @Published var taskEndedAt: [UUID: Date] = [:]
    @Published var submittedPrompts: [UUID: String] = [:]
    @Published var previewAvailable = false
    @Published var previewHealth: [UUID: PreviewHealth] = [:]
    @Published var stoppingTasks: Set<UUID> = []
    @Published var taskStopFailures: Set<UUID> = []
    @Published var sessions: [UUID: [Assistant: String]] = [:]
    private var canceledTasks: Set<UUID> = []
    private var historyProgressTokens: [UUID: UUID] = [:]
    private var historyProgressIDs: [UUID: UUID] = [:]
    private var pendingTaskLaunch: [UUID: UUID] = [:]
    var checkpointOperation: @Sendable (FileWorkspaceStore, Workspace) async throws -> Void = { store, workspace in
        try await Task.detached { try store.checkpoint(workspace) }.value
    }
    private var previewChecking: Set<UUID> = []
    private var nextPreviewPoll = Date.distantPast
    @Published var changes: [FileChange] = []
    let store: FileWorkspaceStore
    private var ticker: Timer?
    private var streamBuffer = ""
    private var activeSecret = ""
    private var generation: UUID?
    var runtime: ContainerRuntime? { runtimePath.map { ContainerRuntime(executable: $0) } }
    var selected: Workspace? { workspaces.first { $0.id == selection } }
    var active: Workspace? { workspaces.first { $0.state.isActive } }

    init(storageRoot: URL? = nil, automaticallyRefresh: Bool = true, credentialStore: any CredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--data-root").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let root = storageRoot ?? override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Harbor/Workspaces")
        do {
            store = try FileWorkspaceStore(root: root)
        } catch {
            store = FileWorkspaceStore(readOnlyRoot: root)
            storageBlocked = true; self.error = "Harbor cannot open its storage. Free disk space or restore folder access, then reopen Harbor. \(error.localizedDescription)"
        }
        if !storageBlocked {
            do { workspaces = try store.load() }
            catch { storageBlocked = true; self.error = "Saved workspaces could not be read. Harbor has disabled changes to avoid overwriting them. Restore workspaces.json from a backup, then reopen Harbor. \(error.localizedDescription)" }
        }
        loadDrafts()
        loadUsageLedger()
        selection = workspaces.first?.id
        runtimePath = ContainerRuntime.discover()
        if automaticallyRefresh {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await refreshRuntime(); await reconcile() }
        if !args.contains("--smoke-shot") { Task { await loadCredentials() } }
        }
    }
    private var usageURL: URL { store.root.appendingPathComponent("usage.json") }
    private func loadUsageLedger() {
        guard FileManager.default.fileExists(atPath: usageURL.path) else { return }
        do { usageLedger = try JSONDecoder().decode(UsageLedger.self, from: Data(contentsOf: usageURL)) }
        catch { usageLedgerError = "Usage history could not be read. Remaining budget is unavailable. Saved history has not been overwritten." }
    }
    private func saveUsageLedger() {
        guard usageLedgerError == nil else { return }
        do { try JSONEncoder().encode(usageLedger).write(to: usageURL, options: .atomic) }
        catch { usageLedgerError = "Usage history could not be saved. Remaining budget is unavailable; check storage access and reopen Harbor." }
    }
    func setDemoUsage(_ enabled: Bool) {
        guard usageLedgerError == nil else { return }; usageLedger.demoMode = enabled; saveUsageLedger()
    }
    func setUsagePreference(_ assistant: Assistant, _ change: (inout UsagePreference) -> Void) {
        guard usageLedgerError == nil else { return }
        var preference = usageLedger.preference(assistant); change(&preference)
        guard preference.monthlyBudgetUSD.isFinite, preference.monthlyBudgetUSD >= 0, preference.monthlyBudgetUSD <= 1_000_000 else { return }
        usageLedger.preferences[assistant.rawValue] = preference; saveUsageLedger()
    }
    private func recordUsage(_ usage: ProviderUsage, token: UUID) {
        usageLedger.report(id: token, usage: usage); saveUsageLedger()
    }
    func loadCredentials() async {
        for assistant in Assistant.allCases { await reloadCredential(assistant) }
    }
    func reloadCredential(_ assistant: Assistant) async {
        guard !credentialOperations.contains(assistant) else { return }
        credentialOperations.insert(assistant); defer { credentialOperations.remove(assistant) }
        do {
            let storage = credentialStore
            let key = try await Task.detached { try storage.load(assistant) }.value
            apiKeys[assistant] = key; credentialErrors[assistant] = nil
        } catch { apiKeys[assistant] = nil; credentialErrors[assistant] = error.localizedDescription }
    }
    func saveCredential(_ input: String, for assistant: Assistant) async -> String? {
        guard !credentialOperations.contains(assistant) else { return "A Keychain operation is already in progress. Try again shortly." }
        credentialOperations.insert(assistant); defer { credentialOperations.remove(assistant) }
        do {
            let key = try CredentialValidation.normalized(input), storage = credentialStore
            try await Task.detached { try storage.save(key, for: assistant) }.value
            apiKeys[assistant] = key; credentialErrors[assistant] = nil
            return nil
        } catch { return error.localizedDescription }
    }
    func removeCredential(_ assistant: Assistant) async -> String? {
        guard !credentialOperations.contains(assistant) else { return "A Keychain operation is already in progress. Try again shortly." }
        credentialOperations.insert(assistant); defer { credentialOperations.remove(assistant) }
        do {
            let storage = credentialStore
            try await Task.detached { try storage.remove(assistant) }.value
            apiKeys[assistant] = nil; credentialErrors[assistant] = nil
            return nil
        } catch { return error.localizedDescription }
    }
    func persist() {
        guard !storageBlocked else { return }
        do { try store.save(workspaces) }
        catch { storageBlocked = true; self.error = "Changes could not be saved. Free disk space or restore storage access, then reopen Harbor. Active workspaces can still be stopped. \(error.localizedDescription)" }
    }
    private func commit(_ id: UUID, _ change: (inout Workspace) -> Void) throws {
        guard !storageBlocked else { throw WorkspaceError.invalid("Storage is unavailable. Restore access and reopen Harbor before starting new work.") }
        var next = workspaces
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.invalid("This workspace no longer exists.") }
        change(&next[index]); try store.save(next); workspaces = next
    }
    private func redacted(_ text: String) -> String {
        (Array(apiKeys.values) + [activeSecret]).filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
    }
    func report(_ id: UUID?, title: String, detail: String) {
        let safe = String(redacted(detail).suffix(6000))
        errorTitle = title; error = safe
        if let id {
            logs[id] = String(((logs[id] ?? "") + "\n" + title + ": " + safe + "\n").suffix(32000))
            update(id) { w in
                w.problems = Array(((w.problems ?? []) + [WorkspaceProblem(title: title, detail: safe)]).suffix(30))
            }
        }
    }
    func update(_ id: UUID, _ change: (inout Workspace) -> Void) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        change(&workspaces[i]); persist()
    }
    private func beginTaskHistory(_ id: UUID, token: UUID) {
        historyProgressTokens[id] = token
        historyProgressIDs[id] = workspaces.first(where: { $0.id == id })?.promptHistory?.last?.id
    }
    private func saveTaskHistory(_ id: UUID, token: UUID) {
        guard historyProgressTokens[id] == token, let itemID = historyProgressIDs[id] else { return }
        let elapsed = taskStartedAt[id].map { max(0, Int((taskEndedAt[id] ?? Date()).timeIntervalSince($0))) }
        let outcome = taskOutcomes[id], activity = taskLastActivity[id]
        update(id) { w in
            guard let index = w.promptHistory?.firstIndex(where: { $0.id == itemID }) else { return }
            w.promptHistory?[index].elapsedSeconds = elapsed
            w.promptHistory?[index].outcome = outcome
            w.promptHistory?[index].latestActivity = activity
        }
    }
    func event(_ id: UUID, _ text: String) {
        if taskTokens[id] != nil { taskLastActivity[id] = text }
        update(id) { w in
            w.recordActivity(text)
        }
    }
    func refreshRuntime(discover: Bool = true, timeout: TimeInterval = 60) async {
        if discover { runtimePath = ContainerRuntime.discover() }
        guard let runtime else { environmentReady = false; runtimeStatus = "One-time setup needed"; return }
        do {
            let version = try await runtime.health(timeout: timeout)
            runtimeStatus = version.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await runtime.checked(["image", "inspect", ContainerRuntime.image], timeout: timeout)
            environmentReady = !result.isEmpty
        } catch { runtimeStatus = "Workspace tools are unavailable. " + error.localizedDescription; environmentReady = false }
    }
    func cancelPreparation() {
        guard preparing, preparingBuild, !cancelingPreparation, let task = preparationBuildTask else { return }
        cancelingPreparation = true
        setupLog += "\nCancelling Harbor’s build command…\n"
        task.cancel()
    }
    func prepare() async {
        guard let runtime, !preparing, !busy, !storageBlocked, !workspaces.contains(where: { $0.runID != nil }) else { return }
        let token = UUID()
        preparationToken = token
        preparing = true; setupLog = "Preparing the local workspace tools…\n"
        defer { preparing = false; preparingBuild = false; checkingPreparedTools = false; cancelingPreparation = false; preparationBuildTask = nil; preparationToken = nil }
        do {
            try await runtime.startService()
            preparingBuild = true
            let root = store.root
            let task = Task {
                try await runtime.prepare(at: root) { [weak self] chunk in
                    Task { @MainActor in
                        guard let self, self.preparing, self.preparationToken == token else { return }
                        self.setupLog = String((self.setupLog + chunk).suffix(16000))
                    }
                }
            }
            preparationBuildTask = task
            try await task.value
            if cancelingPreparation { throw CancellationError() }
            environmentReady = true; runtimeStatus = "Ready on this Mac"
        } catch is CancellationError {
            // Interrupt only our CLI process. Do not stop the shared builder or runtime service.
            setupLog += "\nHarbor’s build command was cancelled. The shared builder may continue cleanup or background work.\n"
            preparingBuild = false; checkingPreparedTools = true
            await refreshRuntime(discover: false, timeout: 6)
            runtimeStatus = environmentReady ? "Build cancelled · existing tools are ready" : "Build cancelled — prepare tools to retry"
        } catch {
            report(selection, title: "Workspace tools couldn’t be prepared", detail: error.localizedDescription)
            runtimeStatus = "Preparation failed — retry when ready"
        }
    }
    @discardableResult
    func create(name: String, source: URL?) async -> String? {
        guard !storageBlocked else { return "Restore access to Harbor’s storage and reopen the app before creating a workspace." }
        guard !busy else { return "Wait for the current operation to finish, then try again." }; busy = true
        defer { busy = false }
        if let message = WorkspaceValidation.nameError(name) { return message }
        var workspace = Workspace(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        workspace.sourceDescription = source?.lastPathComponent ?? "New starter project"
        workspace.importedFolder = source != nil
        do {
            let store = self.store; let initial = workspace
            let report = try await Task.detached { try store.create(initial, source: source) }.value
            workspace.events = ["Created a working copy with \(report.copied) files."]
            if !report.skipped.isEmpty { workspace.events.append("Skipped \(report.skipped.count) sensitive, generated, or linked items. Review your working files before sending them to an AI service.") }
            do { try store.save(workspaces + [workspace]) }
            catch {
                try? FileManager.default.removeItem(at: store.directory(for: workspace.id))
                throw error
            }
            workspaces.append(workspace); selection = workspace.id
            return nil
        } catch { return error.localizedDescription }
    }
    func runDraft(_ id: UUID) async {
        guard !transitioningTask, !busy, !preparing, !storageBlocked, environmentReady, runtime != nil,
              let workspace = workspaces.first(where: { $0.id == id }),
              ![.starting, .stopping].contains(workspace.state),
              !workspaces.contains(where: { $0.id != id && $0.runID != nil }) else { return }
        do {
            try RuntimePolicy.validate(workspace, needsAI: true)
            _ = try CredentialValidation.normalized(apiKeys[workspace.assistant] ?? "")
            guard !credentialOperations.contains(workspace.assistant), !(prompts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceError.invalid("Finish setting up the key and enter a prompt before running the task.")
            }
        } catch { report(id, title: "Task can’t start", detail: error.localizedDescription); return }
        transitioningTask = true
        if workspace.runID != nil { await stop(id) }
        guard let current = workspaces.first(where: { $0.id == id }), current.runID == nil else {
            transitioningTask = false
            return // Failed cleanup keeps ownership; never start a second task.
        }
        transitioningTask = false
        await start(workspaceID: id)
    }
    func start(previewOnly: Bool = false, workspaceID: UUID? = nil) async {
        let target: Workspace?
        if let workspaceID { target = workspaces.first { $0.id == workspaceID } }
        else { target = selected }
        guard !transitioningTask, let runtime, let workspace = target, !workspaces.contains(where: { $0.runID != nil }), environmentReady, !preparing, !busy, !storageBlocked else { return }
        guard previewOnly || !credentialOperations.contains(workspace.assistant) else { return }
        do { try RuntimePolicy.validate(workspace, needsAI: !previewOnly) }
        catch { report(workspace.id, title: "Workspace can’t start", detail: error.localizedDescription); return }
        let key = (apiKeys[workspace.assistant] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let request = (prompts[workspace.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard previewOnly || (!key.isEmpty && !request.isEmpty) else { error = "Add an API key and describe your task."; return }
        guard !key.contains("\n"), !key.contains("\r") else { error = "The API key must be a single line."; return }
        let id = workspace.id; let token = UUID()
        let runID = "harbor-" + token.uuidString.lowercased()
        logs[id] = ""; streamBuffer = ""; activeSecret = key; previewAvailable = false
        do {
            let safePrompt = redacted(request)
            try commit(id) { w in
                w.previousProblems = Array(((w.previousProblems ?? []) + (w.problems ?? [])).suffix(50)); w.problems = []
                w.archiveActivity(label: "Previous run · " + Date().formatted())
                w.state = .starting; w.runID = runID; w.startedAt = Date(); w.deadline = Date().addingTimeInterval(Double(w.minutes * 60)); w.providerUsage = nil
                if !previewOnly {
                    let summary = safePrompt.count > 32000 ? String(safePrompt.prefix(32000)) + "\n[Prompt truncated]" : safePrompt
                    w.promptHistory = Array(((w.promptHistory ?? []) + [PromptHistoryItem(assistant: w.assistant, text: summary)]).suffix(10))
                }
            }
        } catch { report(id, title: "Workspace couldn’t start", detail: "Run ownership could not be saved. No tools were launched. " + error.localizedDescription); return }
        sessions[id] = nil; taskStopFailures.remove(id)
        generation = token; providerFailed = false; readings[id] = nil; measurementErrors[id] = nil
        if !previewOnly {
            taskTokens[id] = token; submittedPrompts[id] = request; composerModes[id] = .followup
            taskStartedAt[id] = Date(); taskEndedAt[id] = nil; taskOutcomes[id] = "Preparing"; taskLastActivity[id] = "Preparing task…"; beginTaskHistory(id, token: token)
        }
        else { submittedPrompts[id] = nil }
        defer { if taskTokens[id] == token { taskTokens[id] = nil; taskEndedAt[id] = Date() }; if !previewOnly { saveTaskHistory(id, token: token) }; canceledTasks.remove(token) }
        creationInFlight[id] = token
        defer {
            if creationInFlight[id] == token { creationInFlight[id] = nil; stopRequested.remove(id) }
        }
        event(id, "Starting an isolated working copy…")
        do {
            let store = self.store
            if !previewOnly { try await checkpointOperation(store, workspace) }
            guard generation == token else { return }
            guard !storageBlocked else { throw WorkspaceError.invalid("Storage became unavailable before startup. Restore access before retrying.") }
            let launch = workspaces.first(where: { $0.id == id })!
            try await runtime.create(launch, project: store.project(for: id), id: runID)
            if creationInFlight[id] == token { creationInFlight[id] = nil }
            if stopRequested.remove(id) != nil { await stop(id); return }
            update(id) { $0.state = .running }; previewAvailable = workspace.canPreview
            Task { await checkPreview(id) }
            if previewOnly { event(id, workspace.canPreview ? "Preview is running locally. No AI request has been sent." : "Workspace running without a browser preview. No AI request has been sent."); return }
            try await executeTask(workspace, token: token, runID: runID, key: key, request: request)

        } catch {
            guard generation == token else { return }
            if canceledTasks.remove(token) != nil {
                taskOutcomes[id] = "Stopped"
                event(id, "Task stopped. Preview and working files are kept; send a follow-up or start a new task."); return
            }
            if creationInFlight[id] == token { creationInFlight[id] = nil }
            stopRequested.remove(id)
            taskOutcomes[id] = "Failed"
            report(id, title: "Task couldn’t finish", detail: error.localizedDescription)
            event(id, "Run failed. Your working files are preserved.")
            await stop(id, failed: true)
        }
    }
    private func executeTask(_ workspace: Workspace, token: UUID, runID: String, key: String, request: String, session: String? = nil) async throws {
        guard let runtime else { return }
        let id = workspace.id
            taskOutcomes[id] = "Working"
            event(id, "\(workspace.assistant.rawValue) is working. Project content may be sent to its provider.")
            let workInstruction = workspace.allowsFileChanges
                ? "Build or edit a static HTML/CSS/JS prototype with index.html so the built-in preview works."
                : "The working folder is read-only. Review or analyze its files and report findings in your response. Do not attempt edits, dependency installation, or builds that write into /workspace."
            let instructions = "Work only in /workspace. " + workInstruction + " Do not publish, deploy, send messages, or access external accounts. User request:\n" + request
            let immutableKeys = Array(apiKeys.values.filter { !$0.isEmpty }) + [key]
            usageLedger.begin(id: token, assistant: workspace.assistant, prompt: request, followup: session != nil); saveUsageLedger()
            defer { usageLedger.finish(id: token); saveUsageLedger() }
            let transcript = try await runtime.execute(workspace.assistant, in: runID, prompt: instructions, key: key, token: token, session: session) { [weak self] chunk in
                let safe = immutableKeys.reduce(chunk) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.receive(safe, id: id)
                }
            }
            guard generation == token, workspaces.first(where: { $0.id == id })?.state == .running else { return }
            if transcript.split(separator: "\n").contains(where: { AgentEvent.failed(String($0)) }) { providerFailed = true }
            for line in transcript.split(separator: "\n") {
                if let sessionID = AgentEvent.sessionID(String(line)) { sessions[id, default: [:]][workspace.assistant] = sessionID }
                if let usage = AgentEvent.usage(String(line)) { update(id) { $0.providerUsage = usage }; recordUsage(usage, token: token) }
            }
            if canceledTasks.contains(token) { throw CancellationError() }
            if providerFailed { throw WorkspaceError.invalid("The provider reported a failed turn. Check Activity, verify your API key and connection, then retry.") }
            usageLedger.finish(id: token, confirmed: true); saveUsageLedger()
            taskOutcomes[id] = "Finished"
            event(id, "Assistant finished. Review your preview, then stop the workspace to export.")
            // Keep the run redactor until stop; output callbacks may still be queued.
    }
    func canFollowUp(_ workspace: Workspace) -> Bool {
        workspace.state == .running && workspace.runID != nil && taskTokens[workspace.id] == nil && !stoppingTasks.contains(workspace.id) && !taskStopFailures.contains(workspace.id) && sessions[workspace.id]?[workspace.assistant] != nil
    }
    func followUp(_ id: UUID) async {
        guard !busy, !transitioningTask, !storageBlocked, let workspace = workspaces.first(where: { $0.id == id }), canFollowUp(workspace),
              let runID = workspace.runID, let session = sessions[id]?[workspace.assistant], !credentialOperations.contains(workspace.assistant) else { return }
        let draftSnapshot = followupPrompts[id] ?? ""
        let request = draftSnapshot.trimmingCharacters(in: .whitespacesAndNewlines), key = apiKeys[workspace.assistant] ?? ""
        guard !request.isEmpty, !key.isEmpty else { return }
        let token = UUID()
        do {
            let safe = redacted(request)
            try commit(id) { w in
                w.previousProblems = Array(((w.previousProblems ?? []) + (w.problems ?? [])).suffix(50)); w.problems = []
                w.archiveActivity(label: "Previous task · " + Date().formatted())
                w.providerUsage = nil
                w.promptHistory = Array(((w.promptHistory ?? []) + [PromptHistoryItem(assistant: w.assistant, text: String(safe.prefix(32000)))]).suffix(10))
            }
        } catch { report(id, title: "Follow-up couldn’t start", detail: error.localizedDescription); return }
        generation = token; providerFailed = false; streamBuffer = ""; activeSecret = key
        taskTokens[id] = token; pendingTaskLaunch[id] = token; submittedPrompts[id] = request; logs[id] = ""
        taskStartedAt[id] = Date(); taskEndedAt[id] = nil; taskOutcomes[id] = "Preparing"; taskLastActivity[id] = "Preparing task…"; beginTaskHistory(id, token: token)
        if followupPrompts[id] == draftSnapshot { followupPrompts[id] = "" }
        defer { if taskTokens[id] == token { taskTokens[id] = nil; taskEndedAt[id] = Date() }; saveTaskHistory(id, token: token); if pendingTaskLaunch[id] == token { pendingTaskLaunch[id] = nil }; canceledTasks.remove(token) }
        do {
            let store = self.store
            try await checkpointOperation(store, workspace)
            guard generation == token, workspaces.first(where: { $0.id == id })?.runID == runID else {
                if workspaces.contains(where: { $0.id == id }), pendingTaskLaunch[id] == token, (followupPrompts[id] ?? "").isEmpty { followupPrompts[id] = draftSnapshot }
                return
            }
            guard !canceledTasks.contains(token), !taskStopFailures.contains(id) else {
                taskOutcomes[id] = "Stopped before launch"
                if (followupPrompts[id] ?? "").isEmpty { followupPrompts[id] = draftSnapshot }
                event(id, "Task stopped before launch. Preview remains open."); return
            }
            pendingTaskLaunch[id] = nil
            try await executeTask(workspace, token: token, runID: runID, key: key, request: request, session: session)
        }
        catch {
            guard generation == token else { return }
            if canceledTasks.contains(token) { taskOutcomes[id] = "Stopped"; event(id, "Task stopped. Preview and working files are kept.") }
            else {
                taskOutcomes[id] = "Failed"
                if pendingTaskLaunch[id] == token && (followupPrompts[id] ?? "").isEmpty { followupPrompts[id] = draftSnapshot }
                do {
                    guard let runtime else { throw WorkspaceError.invalid("Runtime access is unavailable; stop the workspace before retrying.") }
                    try await runtime.cancelAgent(in: runID, token: token)
                } catch { taskStopFailures.insert(id) }
                report(id, title: "Follow-up couldn’t finish", detail: error.localizedDescription)
            }
        }
    }
    func cancelTask(_ id: UUID) async {
        guard !stoppingTasks.contains(id), let token = taskTokens[id], let workspace = workspaces.first(where: { $0.id == id }), workspace.state == .running,
              let runID = workspace.runID, let runtime else { return }
        if pendingTaskLaunch[id] == token {
            canceledTasks.insert(token); event(id, "Task stopped before launch. Finishing the local checkpoint; preview remains open."); return
        }
        stoppingTasks.insert(id); canceledTasks.insert(token)
        defer { stoppingTasks.remove(id) }
        do {
            try await runtime.cancelAgent(in: runID, token: token)
            guard workspaces.first(where: { $0.id == id })?.runID == runID else { return }
            taskStopFailures.remove(id)
            event(id, "Task stop confirmed. Preview remains open; waiting for assistant output to close.")
        } catch {
            canceledTasks.remove(token)
            guard workspaces.first(where: { $0.id == id })?.runID == runID else { return }
            taskStopFailures.insert(id)
            report(id, title: "Task stop couldn’t be confirmed", detail: "Retry Stop Task or stop the entire workspace. " + error.localizedDescription)
        }
    }
    func runBlockReason(_ workspace: Workspace, for mode: PromptMode = .newTask) -> String? {
        if storageBlocked { return "Restore storage access and reopen Harbor." }
        if busy || transitioningTask || preparing || [.starting, .stopping].contains(workspace.state) { return "Wait for the current operation to finish." }
        if stoppingTasks.contains(workspace.id) || taskStopFailures.contains(workspace.id) { return "Confirm the task has stopped before starting another." }
        if taskTokens[workspace.id] != nil { return "The current task is still working. Prepare a draft below; send it when this task finishes, or use Stop Task." }
        if workspaces.contains(where: { $0.id != workspace.id && $0.runID != nil }) { return "Stop the other running workspace first." }
        if !environmentReady { return "Prepare workspace tools in Settings." }
        if !workspace.allowsInternet { return "Turn on Internet in Settings to use an assistant." }
        if credentialOperations.contains(workspace.assistant) { return "Waiting for Keychain access…" }
        if let error = credentialErrors[workspace.assistant] { return "Check API key access in Settings. " + error }
        if (apiKeys[workspace.assistant] ?? "").isEmpty { return "Set an API key in Settings." }
        do { try RuntimePolicy.validate(workspace, needsAI: true) } catch { return error.localizedDescription }
        if mode == .followup && !canFollowUp(workspace) { return "No conversation is available for this assistant. Choose New Task to start a fresh conversation." }
        let draft = mode == .followup ? followupPrompts[workspace.id] : prompts[workspace.id]
        if (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return mode == .followup ? "Write a follow-up below to continue the conversation." : "Enter a task above to start." }
        return nil
    }
    func checkPreview(_ id: UUID) async {
        guard !previewChecking.contains(id), let workspace = workspaces.first(where: { $0.id == id }), let runID = workspace.runID else { previewHealth[id] = .unavailable; return }
        guard workspace.state == .running, workspace.canPreview else { previewHealth[id] = .unknown; return }
        previewChecking.insert(id); defer { previewChecking.remove(id) }
        previewHealth[id] = .checking
        let result = await PreviewProbe.check(port: workspace.effectivePreviewPort, runID: runID)
        guard let current = workspaces.first(where: { $0.id == id }), current.runID == runID, current.state == .running else { return }
        previewHealth[id] = result
    }
    func deleteWorkspace(_ id: UUID) async {
        guard !busy, !preparing, !storageBlocked, let workspace = workspaces.first(where: { $0.id == id }),
              workspace.state != .starting, workspace.state != .stopping else { return }
        busy = true; defer { busy = false }
        if workspace.runID != nil { await stop(id) }
        guard let stopped = workspaces.first(where: { $0.id == id }), stopped.runID == nil else {
            error = "The workspace could not be confirmed stopped. Its files have not been deleted. Try stopping it again."
            return
        }
        do {
            // Commit the index without yielding; agent events and settings also persist on MainActor.
            let staged = try store.stageDeletion(stopped, from: workspaces)
            workspaces.removeAll { $0.id == id }
            logs[id] = nil; prompts[id] = nil; followupPrompts[id] = nil; composerModes[id] = nil
            savedDrafts.remove(id); draftErrors[id] = nil; unreadableDrafts.remove(id)
            let draftURL = draftURL(id)
            if FileManager.default.fileExists(atPath: draftURL.path) {
                do { try FileManager.default.removeItem(at: draftURL) }
                catch { self.error = "Workspace removed, but its draft could not be deleted at \(draftURL.path). \(error.localizedDescription)" }
            }
            if selection == id { selection = workspaces.first?.id }
            if let staged {
                do { try await Task.detached { try FileManager.default.removeItem(at: staged) }.value }
                catch { self.error = "The workspace was removed, but some local files could not be deleted at \(staged.path). \(error.localizedDescription)" }
            }
        } catch {
            // Reload committed metadata if file cleanup failed after removal from the index.
            if let saved = try? store.load() { workspaces = saved }
            if !workspaces.contains(where: { $0.id == selection }) { selection = workspaces.first?.id }
            self.error = "Workspace deletion could not finish. \(error.localizedDescription)"
        }
    }
    private func receive(_ chunk: String, id: UUID) {
        streamBuffer += chunk
        while let newline = streamBuffer.firstIndex(of: "\n") {
            let line = String(streamBuffer[..<newline]); streamBuffer.removeSubrange(...newline)
            let safe = activeSecret.isEmpty ? line : line.replacingOccurrences(of: activeSecret, with: "[redacted]")
            logs[id] = String(((logs[id] ?? "") + safe + "\n").suffix(32000))
            if let session = AgentEvent.sessionID(safe), let assistant = workspaces.first(where: { $0.id == id })?.assistant { sessions[id, default: [:]][assistant] = session }
            if AgentEvent.failed(safe) { providerFailed = true }
            if let usage = AgentEvent.usage(safe) { update(id) { $0.providerUsage = usage }; if let token = taskTokens[id] { recordUsage(usage, token: token) } }
            if let summary = AgentEvent.summary(safe) { event(id, summary) }
        }
        if streamBuffer.count > 64000 { streamBuffer = String(streamBuffer.suffix(32000)) }
    }
    func stop(_ id: UUID, failed: Bool = false) async {
        if creationInFlight[id] != nil {
            stopRequested.insert(id); event(id, "Stop requested. Waiting for startup to settle before cleanup."); return
        }
        guard let w = workspaces.first(where: { $0.id == id }), w.state != .stopping, let runID = w.runID, let runtime else { return }
        let hadActiveTask = taskTokens[id] != nil
        let progressToken = historyProgressTokens[id]
        defer { if let progressToken { saveTaskHistory(id, token: progressToken) } }
        sessions[id] = nil; previewHealth[id] = .unknown; taskStopFailures.remove(id)
        generation = nil; update(id) { $0.state = .stopping }; event(id, "Stopping the workspace and its tools…")
        if taskTokens[id] != nil { taskEndedAt[id] = Date(); taskOutcomes[id] = failed ? "Failed" : "Stopped" }
        taskTokens[id] = nil
        do {
            try await runtime.stop(runID)
            try await runtime.remove(runID)
            update(id) { $0.state = failed ? .failed : .stopped; $0.runID = nil; $0.deadline = nil }
            event(id, failed ? "Task failed; workspace stopped. Your working files are preserved." : "Stopped. Working files are saved on your Mac.")
            measurementErrors[id] = "Workspace stopped. Showing the last measurement."
            previewAvailable = false; previewHealth[id] = .unavailable; activeSecret = ""
        } catch {
            if hadActiveTask { taskOutcomes[id] = "Stop unconfirmed" }
            update(id) { $0.state = .interrupted }
            report(id, title: "Workspace stop couldn’t be confirmed", detail: "Retry Stop before starting or deleting this workspace. " + error.localizedDescription)
        }
    }
    private func tick() async {
        objectWillChange.send()
        if Date() >= nextPreviewPoll, let running = workspaces.first(where: { $0.state == .running }) {
            nextPreviewPoll = Date().addingTimeInterval(8); Task { await checkPreview(running.id) }
        }
        if Date() >= nextPoll, !polling, let running = workspaces.first(where: { $0.state == .running }) {
            nextPoll = Date().addingTimeInterval(5)
            Task { await pollResources(running.id) }
        }
        if Date() >= nextStoragePoll, let selected {
            nextStoragePoll = Date().addingTimeInterval(30)
            Task { await measureStorage(selected.id) }
        }
        guard let active, active.state != .stopping, let deadline = active.deadline, deadline <= Date() else { return }
        event(active.id, "The time allowance has ended."); await stop(active.id)
    }
    func extendRun(_ id: UUID) async {
        guard !extendingRuns.contains(id), !storageBlocked, let w = workspaces.first(where: { $0.id == id }), w.state == .running, let runID = w.runID, let runtime else { return }
        extendingRuns.insert(id); defer { extendingRuns.remove(id) }
        do {
            try await runtime.extend(runID, seconds: 900)
            guard let current = workspaces.first(where: { $0.id == id }), current.runID == runID, current.state == .running else { return }
            update(id) { $0.extend(by: 15) }
        } catch { report(id, title: "Run couldn’t be extended", detail: error.localizedDescription) }
    }
    func pollResources(_ id: UUID) async {
        guard !polling, let runtime, let workspace = workspaces.first(where: { $0.id == id }), workspace.state == .running, let runID = workspace.runID else { return }
        polling = true; defer { polling = false }
        do {
            let sample = try await runtime.stats(runID)
            guard let current = workspaces.first(where: { $0.id == id }), current.runID == runID, current.state == .running else { return }
            readings[id] = ResourceReading(sample: sample, previous: readings[id], cores: workspace.cpuLimit)
            measurementErrors[id] = nil
        } catch {
            guard workspaces.first(where: { $0.id == id })?.runID == runID else { return }
            measurementErrors[id] = "Measurements unavailable. Last values may be stale. " + redacted(error.localizedDescription)
            // A failed measurement is not proof of shutdown. Only a matching, typed
            // inspect result can establish that the guest exited unexpectedly.
            if let inspection = try? await runtime.inspect(runID),
               (try? RuntimePolicy.isStopped(inspection, id: runID)) == true,
               workspaces.first(where: { $0.id == id })?.runID == runID {
                report(id, title: "Workspace exited unexpectedly", detail: "The runtime reports this workspace stopped. Check Activity, then restart it. Working files are preserved.")
                await stop(id, failed: true)
            }
        }
    }
    func measureStorage(_ id: UUID) async {
        guard !storagePolling.contains(id), workspaces.contains(where: { $0.id == id }), !busy else { return }
        storagePolling.insert(id); defer { storagePolling.remove(id) }
        let folder = store.project(for: id)
        do {
            let result = try await Task.detached(priority: .utility) {
                let summary = try StorageSummary.scan(folder)
                let unchanged = summary.count == 1 && (try? String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)) == FileWorkspaceStore.starterHTML
                return (summary, unchanged)
            }.value
            let summary = result.0
            guard workspaces.contains(where: { $0.id == id }) else { return }
            starterUnchanged[id] = result.1
            storageMeasurements[id] = summary; storageMeasuredAt[id] = Date(); storageMeasurementErrors[id] = nil
        } catch { storageMeasurementErrors[id] = "Storage measurement unavailable. " + error.localizedDescription }
    }
    func reconcile() async {
        for w in workspaces where w.runID != nil {
            update(w.id) { $0.state = .interrupted }
            if runtime != nil { await stop(w.id) }
            else { event(w.id, "Previous run needs a stop check. Restore the runtime to clean it up.") }
        }
    }
    func exportSelected() async {
        guard let workspace = selected, !workspace.state.isActive, workspace.runID == nil, !busy else { return }
        busy = true; defer { busy = false }
        let panel = NSSavePanel(); panel.title = "Export a copy"; panel.nameFieldStringValue = workspace.name + " Export"
        panel.canCreateDirectories = true; panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard workspaces.first(where: { $0.id == workspace.id })?.runID == nil else { return }
        do {
            let store = self.store
            let report = try await Task.detached { try store.export(workspace, to: destination) }.value
            event(workspace.id, "Exported \(report.copied) files. \(report.skipped.count) linked or special items were skipped.")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { report(workspace.id, title: "Copy couldn’t be exported", detail: error.localizedDescription) }
    }
    func reviewChanges() async {
        guard let workspace = selected, workspace.runID == nil, !busy else { return }
        changes = []; busy = true; defer { busy = false }
        do {
            let store = self.store
            changes = try await Task.detached { try store.changes(workspace) }.value
        } catch { report(workspace.id, title: "Changes couldn’t be read", detail: error.localizedDescription) }
    }
    func restoreSelected() async {
        guard let workspace = selected, workspace.runID == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let store = self.store
            try await Task.detached { try store.restore(workspace) }.value
            changes = []; event(workspace.id, "Restored the files from before the last run.")
        } catch { report(workspace.id, title: "Files couldn’t be restored", detail: error.localizedDescription) }
    }
}
