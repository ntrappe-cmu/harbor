import XCTest
@testable import HarborCore

final class RuntimeTests: XCTestCase {
    func testPolicyEnforcesOfflineAndLoopbackPreview() throws {
        var w = Workspace(name: "Test")
        w.internetAllowed = false
        XCTAssertThrowsError(try RuntimePolicy.validate(w, needsAI: true))
        let offline = try RuntimePolicy.runArguments(w, project: URL(fileURLWithPath: "/tmp/project"), id: "test", image: "fixture")
        XCTAssertTrue(offline.contains("none")); XCTAssertFalse(offline.contains("--publish"))
        w.internetAllowed = true; w.previewPort = 4999
        let online = try RuntimePolicy.runArguments(w, project: URL(fileURLWithPath: "/tmp/project"), id: "test", image: "fixture")
        XCTAssertTrue(online.contains("127.0.0.1:4999:4173"))
        w.previewEnabled = false
        XCTAssertFalse(try RuntimePolicy.runArguments(w, project: URL(fileURLWithPath: "/tmp/project"), id: "test", image: "fixture").contains("--publish"))
        w.minutes = Int.max
        XCTAssertThrowsError(try RuntimePolicy.validate(w))
        w.minutes = 30; w.previewPort = 80
        XCTAssertThrowsError(try RuntimePolicy.validate(w))
        w.previewPort = 4173; w.memoryOverride = 8
        XCTAssertThrowsError(try RuntimePolicy.validate(w, capacity: HostCapacity(cpus: 8, memoryGiB: 8)))
    }
    func testStatisticsRejectWrongRunAndUnknownResponses() throws {
        let before = try ResourceSample.parse("[{\"id\":\"a\",\"cpuUsageUsec\":1000000}]", id: "a")
        let after = try ResourceSample.parse("[{\"id\":\"a\",\"cpuUsageUsec\":3000000,\"memoryUsageBytes\":1024,\"memoryLimitBytes\":4096}]", id: "a")
        XCTAssertEqual(after.cpuFraction(previous: before, interval: 2, cores: 2), 0.5)
        XCTAssertNil(before.cpuFraction(previous: after, interval: 2, cores: 2))
        XCTAssertThrowsError(try ResourceSample.parse("[]", id: "a"))
        XCTAssertThrowsError(try ResourceSample.parse("[{\"id\":\"b\"}]", id: "a"))
        XCTAssertThrowsError(try RuntimePolicy.containerIDs("not json"))
        XCTAssertThrowsError(try RuntimePolicy.containerIDs("[{}]"))
        XCTAssertEqual(try RuntimePolicy.containerIDs("[{\"configuration\":{\"id\":\"a\"}}]"), ["a"])
        XCTAssertEqual(try RuntimePolicy.containerIDs("[]"), [])
    }
    func testSessionIdentityAndHistoricalCoreAllocation() throws {
        let id = UUID().uuidString
        XCTAssertEqual(AgentEvent.sessionID("{\"thread_id\":\"" + id + "\"}"), id)
        XCTAssertNil(AgentEvent.sessionID("{\"session_id\":\"--invalid\"}"))
        XCTAssertTrue(Assistant.codex.arguments(resuming: id).contains("resume"))
        let sample = try ResourceSample.parse("[{\"id\":\"run\",\"cpuUsageUsec\":10}]", id: "run")
        XCTAssertEqual(ResourceReading(sample: sample, previous: nil, cores: 2).allocatedCores, 2)
    }
    func testProviderReportsAreNotAssumedFromExitCode() {
        XCTAssertTrue(AgentEvent.failed("{\"type\":\"result\",\"is_error\":true}"))
        XCTAssertTrue(AgentEvent.failed("{\"type\":\"turn.failed\"}"))
        XCTAssertNil(AgentEvent.usage("{\"type\":\"turn.completed\"}"))
        let usage = AgentEvent.usage("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":50,\"output_tokens\":12}}")
        XCTAssertEqual(usage?.inputTokens, 50); XCTAssertNil(usage?.reportedCostUSD)
    }
    func testRunnerTimeoutAndCancellation() async throws {
        let runner = CommandRunner()
        let began = Date()
        do {
            _ = try await runner.run("/bin/sleep", ["10"], timeout: 0.1)
            XCTFail("Should time out")
        } catch { XCTAssertTrue(error is CommandFailure) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
        let task = Task { try await runner.run("/bin/sleep", ["10"]) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRunnerPipesAndNonzeroExit() async throws {
        let runner = CommandRunner()
        let text = String(repeating: "hello ✨\n", count: 5000)
        let result = try await runner.run("/bin/cat", [], input: text)
        XCTAssertEqual(result.output, text); XCTAssertEqual(result.code, 0)
        let failure = try await runner.run("/usr/bin/false", [])
        XCTAssertNotEqual(failure.code, 0)
        // A background child inherits stdout. Returning must not wait for its EOF.
        let start = Date()
        _ = try await runner.run("/bin/sh", ["-c", "sleep 1 & exit 0"], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
    }
    func testDeletionCrashRecoveryAndCorruptMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileWorkspaceStore(root: root)
        let w = Workspace(name: "Saved")
        _ = try store.create(w, source: nil); try store.save([w])
        try FileManager.default.moveItem(at: store.directory(for: w.id), to: root.appendingPathComponent(".deleted-" + w.id.uuidString))
        XCTAssertEqual(try store.load().first?.id, w.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.project(for: w.id).path))
        let index = root.appendingPathComponent("workspaces.json")
        try Data("invalid".utf8).write(to: index)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: index, encoding: .utf8), "invalid")
    }
}
