import XCTest
@testable import HarborCore

final class ActivityTests: XCTestCase {
    func testAlternatingRepeatsPersistCountsAndTimes() throws {
        var w = Workspace(name: "Activity")
        let first = Date(timeIntervalSince1970: 10), latest = Date(timeIntervalSince1970: 30)
        w.recordActivity("Connected", at: first)
        w.recordActivity("Working", at: first)
        let identity = w.groupedActivity[0].id
        w.recordActivity("Connected", at: latest)
        XCTAssertEqual(w.groupedActivity.map(\.text), ["Working", "Connected"])
        XCTAssertEqual(w.groupedActivity.last?.count, 2)
        XCTAssertEqual(w.groupedActivity.last?.firstSeen, first)
        XCTAssertEqual(w.groupedActivity.last?.lastSeen, latest)
        XCTAssertEqual(w.groupedActivity.last?.id, identity)
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(restored.groupedActivity, w.groupedActivity)
        w.archiveActivity(label: "Previous task")
        w.recordActivity("Connected", at: latest)
        XCTAssertEqual(w.groupedActivity.first?.count, 1)
        XCTAssertEqual(w.groupedPreviousActivity.last?.count, 2)
    }
    func testLegacyLogsMigrateWithoutLosingRetainedRepeats() throws {
        var w = Workspace(name: "Legacy")
        w.events = ["Connected", "Working", "Connected", "Working"]
        XCTAssertEqual(w.groupedActivity.map(\.count), [2, 2])
        w.recordActivity("Connected")
        XCTAssertEqual(w.groupedActivity.last?.count, 3)
        XCTAssertEqual(w.events.count, 2)
        w.previousEvents = ["Old", "Old"]
        w.archiveActivity(label: "Previous task")
        XCTAssertEqual(w.groupedPreviousActivity.first?.count, 2)
        XCTAssertEqual(ActivityMessage.grouped(["a", "b", "a", "a ", ""]).map(\.count), [1, 2, 1])
    }
    func testUniqueMessageRetentionDoesNotDropFrequentlyRepeatedCount() {
        var w = Workspace(name: "Bounded")
        for n in 0..<60 { w.recordActivity("Message \(n)"); w.recordActivity("Working") }
        XCTAssertEqual(w.groupedActivity.count, 50)
        XCTAssertEqual(w.groupedActivity.last?.text, "Working")
        XCTAssertEqual(w.groupedActivity.last?.count, 60)
    }
    func testAccessPoliciesRoundTripAndLegacyDefaults() throws {
        var w = Workspace(name: "Policies")
        w.fileChangesAllowed = false; w.lowLevelToolsAllowed = false
        let readonly = try RuntimePolicy.runArguments(w, project: URL(fileURLWithPath: "/tmp/test folder"), id: "test", image: "fixture")
        XCTAssertTrue(readonly.contains("type=bind,source=/tmp/test folder,target=/workspace,readonly"))
        XCTAssertTrue(readonly.contains("NET_RAW")); XCTAssertTrue(readonly.contains("SYS_ADMIN"))
        XCTAssertFalse(readonly.contains("--cap-add"))
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        XCTAssertFalse(restored.allowsFileChanges); XCTAssertFalse(restored.allowsLowLevelTools)
        w.fileChangesAllowed = true; w.lowLevelToolsAllowed = true
        let writable = try RuntimePolicy.runArguments(w, project: URL(fileURLWithPath: "/tmp/project"), id: "test", image: "fixture")
        XCTAssertFalse(writable.contains("--cap-drop"))
        XCTAssertTrue(writable.contains("type=bind,source=/tmp/project,target=/workspace"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any])
        object.removeValue(forKey: "fileChangesAllowed"); object.removeValue(forKey: "lowLevelToolsAllowed")
        let legacy = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.allowsFileChanges); XCTAssertFalse(legacy.allowsLowLevelTools)
    }
}
