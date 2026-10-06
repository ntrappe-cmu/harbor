import XCTest
import HarborCore
@testable import Harbor

@MainActor final class DraftPersistenceTests: XCTestCase {
    func testBothDraftsAndModeSurviveReopeningWithoutRestoringSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, automaticallyRefresh: false)
        let error = await model.create(name: "Draft test", source: nil)
        XCTAssertNil(error)
        let id = try XCTUnwrap(model.selection)
        model.prompts[id] = "Original new task"
        model.followupPrompts[id] = "Next message — unsent"
        model.composerModes[id] = .followup
        model.submittedPrompts[id] = "Already submitted"
        let reopened = AppModel(storageRoot: root, automaticallyRefresh: false)
        XCTAssertEqual(reopened.prompts[id], "Original new task")
        XCTAssertEqual(reopened.followupPrompts[id], "Next message — unsent")
        XCTAssertEqual(reopened.composerModes[id], .followup)
        XCTAssertTrue(reopened.savedDrafts.contains(id))
        XCTAssertNil(reopened.sessions[id])
        XCTAssertFalse(reopened.canFollowUp(try XCTUnwrap(reopened.selected)))
        XCTAssertTrue(reopened.draftURL(id).path.contains("/.drafts/"))
        XCTAssertEqual(model.submittedPrompts[id], "Already submitted")
    }

    func testUnreadableDraftIsNeverOverwrittenByEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, automaticallyRefresh: false)
        _ = await model.create(name: "Draft test", source: nil)
        let id = try XCTUnwrap(model.selection)
        model.prompts[id] = "Saved text"
        let damaged = Data("invalid JSON".utf8)
        try damaged.write(to: model.draftURL(id))
        let reopened = AppModel(storageRoot: root, automaticallyRefresh: false)
        reopened.prompts[id] = "New text"
        XCTAssertNotNil(reopened.draftErrors[id])
        XCTAssertFalse(reopened.savedDrafts.contains(id))
        XCTAssertFalse(reopened.canRetryDraftSave(id))
        XCTAssertEqual(try Data(contentsOf: model.draftURL(id)), damaged)
    }

    func testFailedSaveCanRetryAndWorkspaceDeletionRemovesDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, automaticallyRefresh: false)
        _ = await model.create(name: "Draft test", source: nil)
        let id = try XCTUnwrap(model.selection)
        try Data("blocks folder".utf8).write(to: model.draftsDirectory)
        model.followupPrompts[id] = "Keep this unsent"
        XCTAssertNotNil(model.draftErrors[id])
        XCTAssertFalse(model.savedDrafts.contains(id))
        try FileManager.default.removeItem(at: model.draftsDirectory)
        model.saveDraft(id)
        XCTAssertNil(model.draftErrors[id])
        XCTAssertTrue(model.savedDrafts.contains(id))
        await model.deleteWorkspace(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.draftURL(id).path))
        XCTAssertNil(model.followupPrompts[id])
        // Late task callbacks must not recreate a deleted workspace’s draft.
        model.followupPrompts[id] = "Late callback"
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.draftURL(id).path))
    }
}
