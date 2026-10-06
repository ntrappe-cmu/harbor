import XCTest
@testable import HarborCore

final class WorkspaceTests: XCTestCase {
    func testDeletionRequiresStoppedWorkspaceAndPreservesOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileWorkspaceStore(root: root)
        var first = Workspace(name: "Delete me")
        let second = Workspace(name: "Keep me")
        _ = try store.create(first, source: nil); _ = try store.create(second, source: nil)
        try store.save([first, second])
        first.runID = "active"
        XCTAssertThrowsError(try store.delete(first, from: [first, second]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.project(for: first.id).path))
        first.runID = nil
        try store.delete(first, from: [first, second])
        XCTAssertEqual(try store.load().map(\.id), [second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: first.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.project(for: second.id).path))
    }
    func testStarterBreakdownAndLegacyMigration() {
        var workspace = Workspace(name: "Starter")
        XCTAssertFalse(workspace.showsFileBreakdown)
        workspace.sourceDescription = "Imported project"
        XCTAssertTrue(workspace.showsFileBreakdown)
        workspace.importedFolder = false
        XCTAssertFalse(workspace.showsFileBreakdown)
        workspace.importedFolder = true
        XCTAssertTrue(workspace.showsFileBreakdown)
    }
    func testResourceOverridesAndOldWorkspaceMigration() throws {
        var workspace = Workspace(name: "Demo")
        workspace.performance = .turbo
        XCTAssertEqual(workspace.cpuLimit, 8)
        workspace.cpuOverride = 3
        workspace.memoryOverride = 5
        let data = try JSONEncoder().encode(workspace)
        let restored = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(restored.cpuLimit, 3)
        XCTAssertEqual(restored.memoryLimit, 5)
        XCTAssertEqual(restored.performanceTitle, "Custom")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "cpuOverride"); legacy.removeValue(forKey: "memoryOverride")
        let migrated = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.cpuLimit, 8)
        XCTAssertEqual(migrated.performanceTitle, "Turbo")
    }
    func testStorageSummaryClassifiesAndSkipsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("app.swift"))
        try Data(repeating: 1, count: 20).write(to: root.appendingPathComponent("image.PNG"))
        try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("unknown"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root)
        let summary = try StorageSummary.scan(root)
        XCTAssertEqual(summary.total, 35)
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.bytes["Code"], 10)
        XCTAssertEqual(summary.bytes["Images"], 20)
        XCTAssertFalse(summary.partial)
    }
    func testOversizedImportExplainsRecoveryAndRemovesPartialWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("large.asset")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_073_741_825)
        try handle.close()
        let store = try FileWorkspaceStore(root: root.appendingPathComponent("storage"))
        let workspace = Workspace(name: "Large project")
        XCTAssertThrowsError(try store.create(workspace, source: source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Choose a smaller project folder"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: workspace.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testWorkspaceNameValidation() {
        for name in ["", "  ", ".", "..", ".hidden", "a/b", "a\\b", "a:b", "hello\nworld", String(repeating: "x", count: 121)] {
            XCTAssertNotNil(WorkspaceValidation.nameError(name), name)
        }
        for name in ["Portfolio website", "设计 ✨", "Client’s prototype", "Demo v2.0"] {
            XCTAssertNil(WorkspaceValidation.nameError(name), name)
        }
    }
    func testRejectsUnsafeSourcesIncludingAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileWorkspaceStore(root: root.appendingPathComponent("storage"))
        for path in ["/", "/System", "/Applications", FileManager.default.homeDirectoryForCurrentUser.path, root.path, store.root.path] {
            XCTAssertNotNil(WorkspaceValidation.sourceError(URL(fileURLWithPath: path), storeRoot: store.root), path)
        }
        let alias = root.appendingPathComponent("disk-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertThrowsError(try store.create(Workspace(name: "Valid"), source: alias))
        XCTAssertThrowsError(try store.create(Workspace(name: "../invalid"), source: nil))
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertNil(WorkspaceValidation.sourceError(project, storeRoot: store.root))
        try FileManager.default.removeItem(at: project)
        XCTAssertThrowsError(try store.create(Workspace(name: "Valid"), source: project))
    }
    func testImportSkipsSecretsLinksAndDependencies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "original".write(to: source.appendingPathComponent("page.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("outside").path, withDestinationPath: "/etc")
        let store = try FileWorkspaceStore(root: root.appendingPathComponent("store"))
        let workspace = Workspace(name: "Test")
        let report = try store.create(workspace, source: source)
        XCTAssertEqual(report.copied, 1)
        XCTAssertEqual(Set(report.skipped), Set([".env", "outside", "node_modules"]))
        try "changed".write(to: store.project(for: workspace.id).appendingPathComponent("page.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("page.txt"), encoding: .utf8), "original")
        let export = root.appendingPathComponent("export")
        _ = try store.export(workspace, to: export)
        XCTAssertThrowsError(try store.export(workspace, to: export))
    }
    func testPersistenceAndDeadlineExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileWorkspaceStore(root: root)
        var workspace = Workspace(name: "Design")
        let now = Date(); workspace.deadline = now.addingTimeInterval(60)
        workspace.extend(by: 15)
        XCTAssertEqual(workspace.remainingSeconds(at: now), 960)
        try store.save([workspace])
        XCTAssertEqual(try store.load().first?.id, workspace.id)
    }
    func testRejectsRecursiveImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileWorkspaceStore.copyTree(from: root, to: root.appendingPathComponent("nested"), omitSensitive: true))
    }
    func testCheckpointReviewAndRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileWorkspaceStore(root: root)
        let w = Workspace(name: "Demo")
        _ = try store.create(w, source: nil)
        try store.checkpoint(w)
        let file = store.project(for: w.id).appendingPathComponent("index.html")
        try "modified".write(to: file, atomically: true, encoding: .utf8)
        let changes = try store.changes(w)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.kind, "Changed")
        try store.restore(w)
        XCTAssertTrue(try store.changes(w).isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), FileWorkspaceStore.starterHTML)
    }
}
