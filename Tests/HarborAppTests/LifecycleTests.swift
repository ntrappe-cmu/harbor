import XCTest
import HarborCore
@testable import Harbor

@MainActor final class LifecycleTests: XCTestCase {
    func testPreviewCanSwitchToTaskAndRerunAfterStopping() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nexec) cat >/dev/null; printf '%s\\n' '{\"type\":\"result\",\"is_error\":false}';;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        await model.start(previewOnly: true)
        let previewID = model.selected?.runID
        model.apiKeys[.claude] = "synthetic-key"; model.prompts[id] = "First task"
        await model.runDraft(id)
        XCTAssertNotNil(model.selected?.runID)
        XCTAssertNotEqual(model.selected?.runID, previewID)
        XCTAssertEqual(model.submittedPrompts[id], "First task")
        await model.stop(id)
        model.prompts[id] = "Revised task"
        await model.runDraft(id)
        XCTAssertEqual(model.submittedPrompts[id], "Revised task")
        XCTAssertEqual(model.selected?.promptHistory?.count, 2)
        XCTAssertEqual(model.selected?.state, .running)
        await model.stop(id)
    }
    func testRerunNeverLaunchesAfterUnconfirmedStop() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nstop) exit 1;;\nlist) printf '[{}]';;\nrun) touch \"$0.launched\";;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.update(id) { $0.runID = "existing"; $0.state = .running }
        model.apiKeys[.claude] = "synthetic-key"; model.prompts[id] = "Revised task"
        await model.runDraft(id)
        XCTAssertEqual(model.selected?.runID, "existing")
        XCTAssertFalse(model.transitioningTask)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fake-runtime.launched").path))
    }
    func testDraftEditsDoNotChangeSubmittedTask() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nrun) sleep 0.2;;\nexec) cat >/dev/null; printf '%s\\n' '{\"type\":\"result\",\"is_error\":false}';;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.apiKeys[.claude] = "synthetic-key"
        model.prompts[id] = "Initial task"
        let task = Task { await model.start() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(model.taskTokens[id])
        model.prompts[id] = "Revised draft"
        XCTAssertEqual(model.submittedPrompts[id], "Initial task")
        await task.value
        XCTAssertNil(model.taskTokens[id])
        XCTAssertEqual(model.prompts[id], "Revised draft")
        XCTAssertEqual(try model.store.load().first?.promptHistory?.last?.text, "Initial task")
        await model.stop(id)
    }

    func testFollowupPreservesVMAndUsesScopedSession() async throws {
        let session = UUID().uuidString
        let (model, root) = try await fixture(script: "case \"$1\" in\nexec) printf '%s\\n' \"$*\" >> \"$0.calls\"; cat >/dev/null; printf '%s\\n' '{\"type\":\"system\",\"session_id\":\"" + session + "\"}' '{\"type\":\"result\",\"is_error\":false}';;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.apiKeys[.claude] = "synthetic-key"; model.prompts[id] = "First task"
        await model.start(); let runID = model.selected?.runID
        XCTAssertTrue(model.canFollowUp(try XCTUnwrap(model.selected)))
        model.report(id, title: "Previous issue", detail: "Synthetic")
        model.followupPrompts[id] = "Follow-up edit"; await model.followUp(id)
        XCTAssertEqual(model.selected?.runID, runID)
        XCTAssertEqual(model.selected?.promptHistory?.count, 2)
        XCTAssertEqual(model.prompts[id], "First task")
        XCTAssertEqual(model.followupPrompts[id], "")
        XCTAssertEqual(model.submittedPrompts[id], "Follow-up edit")
        let savedTasks = try model.store.load().first?.promptHistory
        XCTAssertEqual(savedTasks?.first?.outcome, "Finished")
        XCTAssertNotNil(savedTasks?.first?.elapsedSeconds)
        XCTAssertTrue(savedTasks?.first?.latestActivity?.contains("Assistant finished") == true)
        XCTAssertEqual(savedTasks?.last?.outcome, "Finished")
        XCTAssertNotNil(model.taskEndedAt[id])
        XCTAssertTrue((model.selected?.problems ?? []).isEmpty)
        XCTAssertEqual(model.selected?.previousProblems?.last?.title, "Previous issue")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("fake-runtime.calls"), encoding: .utf8).contains("--resume " + session))
        await model.stop(id)
        XCTAssertNil(model.sessions[id]); XCTAssertFalse(model.canFollowUp(try XCTUnwrap(model.selected)))
    }
    func testTaskStopKeepsWorkspaceAndFiles() async throws {
        let script = "case \"$1\" in\nexec) case \"$*\" in\n*'Task identity mismatch'*) rm -f \"$0.task\";;\n*) cat >/dev/null; touch \"$0.task\"; while [ -f \"$0.task\" ]; do sleep 0.02; done;;\nesac;;\nesac\n"
        let (model, root) = try await fixture(script: script)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.apiKeys[.claude] = "synthetic-key"; model.prompts[id] = "A task"
        let start = Task { await model.start() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("fake-runtime.task").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("fake-runtime.task").path))
        let runID = model.selected?.runID
        await model.cancelTask(id); await start.value
        XCTAssertEqual(model.selected?.runID, runID); XCTAssertEqual(model.selected?.state, .running)
        XCTAssertNil(model.taskTokens[id]); XCTAssertTrue((model.selected?.problems ?? []).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.store.project(for: id).path))
        await model.stop(id)
    }
    func testReadinessReasonAndChangedStarterFiles() async throws {
        let (model, root) = try await fixture(script: "exit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        XCTAssertEqual(model.runBlockReason(try XCTUnwrap(model.selected)), "Set an API key in Settings.")
        model.apiKeys[.claude] = "synthetic-key"
        XCTAssertEqual(model.runBlockReason(try XCTUnwrap(model.selected)), "Enter a task above to start.")
        await model.measureStorage(id); XCTAssertEqual(model.starterUnchanged[id], true)
        try "Changed page".write(to: model.store.project(for: id).appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        await model.measureStorage(id); XCTAssertEqual(model.starterUnchanged[id], false)
    }
    func testCancelDuringFollowupCheckpointNeverLaunchesAgent() async throws {
        let session = UUID().uuidString
        let (model, root) = try await fixture(script: "case \"$1\" in\nexec) echo invocation >> \"$0.calls\"; cat >/dev/null; printf '%s\\n' '{\"type\":\"system\",\"session_id\":\"" + session + "\"}' '{\"type\":\"result\",\"is_error\":false}';;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.apiKeys[.claude] = "synthetic-key"; model.prompts[id] = "Initial"
        await model.start(); let runID = model.selected?.runID
        let gate = CheckpointGate()
        model.checkpointOperation = { _, _ in await gate.wait() }
        model.followupPrompts[id] = "Follow-up"
        let followup = Task { await model.followUp(id) }
        while !(await gate.started) { await Task.yield() }
        await model.cancelTask(id); await gate.release(); await followup.value
        XCTAssertEqual(model.selected?.runID, runID)
        XCTAssertNil(model.taskTokens[id]); XCTAssertFalse(model.taskStopFailures.contains(id))
        XCTAssertEqual(model.followupPrompts[id], "Follow-up")
        XCTAssertEqual(model.taskOutcomes[id], "Stopped before launch")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fake-runtime.calls"), encoding: .utf8), "invocation\n")
        await model.stop(id)
    }
    func testFullStopDuringFollowupCheckpointPreservesUnsentDraft() async throws {
        let session = UUID().uuidString
        let (model, root) = try await fixture(script: "case \"$1\" in\nexec) echo invocation >> \"$0.calls\"; cat >/dev/null; printf '%s\\n' '{\"type\":\"system\",\"session_id\":\"" + session + "\"}' '{\"type\":\"result\",\"is_error\":false}';;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.apiKeys[.claude] = "synthetic-key"; model.prompts[id] = "Initial"
        await model.start(); let runID = model.selected?.runID
        let gate = CheckpointGate()
        model.checkpointOperation = { _, _ in await gate.wait() }
        model.followupPrompts[id] = "Follow-up"
        let followup = Task { await model.followUp(id) }
        while !(await gate.started) { await Task.yield() }
        await model.stop(id); await gate.release(); await followup.value
        XCTAssertNotNil(runID); XCTAssertNil(model.selected?.runID)
        XCTAssertNil(model.taskTokens[id]); XCTAssertFalse(model.taskStopFailures.contains(id))
        XCTAssertEqual(model.followupPrompts[id], "Follow-up")
        XCTAssertEqual(model.taskOutcomes[id], "Stopped")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fake-runtime.calls"), encoding: .utf8), "invocation\n")
        await model.stop(id)
    }
    private func fixture(script: String) async throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageRoot: root, automaticallyRefresh: false)
        let creationError = await model.create(name: "Test", source: nil)
        XCTAssertNil(creationError)
        let runtime = root.appendingPathComponent("fake-runtime")
        try ("#!/bin/sh\n" + script).write(to: runtime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        model.runtimePath = runtime.path; model.environmentReady = true
        return (model, root)
    }
    func testFailedSaveNeverLaunchesTools() async throws {
        let (model, root) = try await fixture(script: "touch \"$0.launched\"\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("workspaces.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        await model.start(previewOnly: true)
        XCTAssertNil(model.selected?.runID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fake-runtime.launched").path))
        XCTAssertNotNil(model.error)
    }
    func testStopDuringCreationWaitsForCleanup() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nrun) sleep 0.2; touch \"$0.running\";;\nstop) rm -f \"$0.running\";;\ndelete) exit 0;;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        let start = Task { await model.start(previewOnly: true) }
        try await Task.sleep(for: .milliseconds(50))
        await model.stop(id)
        XCTAssertNotNil(model.selected?.runID)
        await start.value
        XCTAssertNil(model.selected?.runID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fake-runtime.running").path))
        XCTAssertNil(try model.store.load().first?.runID)
    }
    func testUnconfirmedStopKeepsOwnershipAndBlocksDeletion() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nstop) exit 1;;\nlist) printf '[{}]';;\n*) exit 0;;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.update(id) { $0.runID = "fixture"; $0.state = .running }
        await model.deleteWorkspace(id)
        XCTAssertEqual(model.selected?.runID, "fixture")
        XCTAssertEqual(model.selected?.state, .interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.store.project(for: id).path))
        XCTAssertFalse((model.selected?.problems ?? []).isEmpty)
    }
    func testProviderFailurePersistsRedactedProblem() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nexec) cat >/dev/null; printf '%s\\n' '{\"type\":\"result\",\"is_error\":true}';;\n*) exit 0;;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.apiKeys[.claude] = "fake-private-key"
        model.prompts[id] = "Test"
        await model.start()
        XCTAssertEqual(model.selected?.state, .failed)
        XCTAssertNil(model.selected?.runID)
        model.report(id, title: "Authentication failed", detail: "Rejected fake-private-key")
        let saved = try model.store.load().first
        XCTAssertTrue(saved?.problems?.last?.detail.contains("[redacted]") == true)
        XCTAssertFalse(saved?.problems?.last?.detail.contains("fake-private-key") == true)
    }
    func testCorruptIndexCannotBeOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("workspaces.json")
        try "broken".write(to: index, atomically: true, encoding: .utf8)
        let model = AppModel(storageRoot: root, automaticallyRefresh: false)
        XCTAssertTrue(model.storageBlocked)
        let creationError = await model.create(name: "New", source: nil)
        XCTAssertNotNil(creationError)
        XCTAssertEqual(try String(contentsOf: index, encoding: .utf8), "broken")
    }
    func testConfirmedUnexpectedExitIsReconciled() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nstats) exit 1;;\ninspect) printf '%s' '[{\"id\":\"fixture\",\"status\":{\"state\":\"stopped\"}}]';;\n*) exit 0;;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection)
        model.update(id) { $0.runID = "fixture"; $0.state = .running }
        await model.pollResources(id)
        XCTAssertNil(model.selected?.runID)
        XCTAssertEqual(model.selected?.state, .failed)
        XCTAssertEqual(model.selected?.problems?.last?.title, "Workspace exited unexpectedly")
    }
    func testExtensionsAreSerialized() async throws {
        let (model, root) = try await fixture(script: "case \"$1\" in\nexec) echo call >> \"$0.calls\"; sleep 0.2;;\nesac\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(model.selection), deadline = Date().addingTimeInterval(60)
        model.update(id) { $0.runID = "fixture"; $0.state = .running; $0.deadline = deadline }
        let first = Task { await model.extendRun(id) }
        try await Task.sleep(for: .milliseconds(40))
        await model.extendRun(id)
        await first.value
        XCTAssertEqual(model.selected?.deadline, deadline.addingTimeInterval(900))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fake-runtime.calls"), encoding: .utf8), "call\n")
    }
}

private actor CheckpointGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; started = true } }
    func release() { continuation?.resume(); continuation = nil }
}
