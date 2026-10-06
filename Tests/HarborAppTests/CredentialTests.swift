import XCTest
import HarborCore
@testable import Harbor

private final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Assistant: String] = [:]
    private var failing = false
    func fail(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func load(_ assistant: Assistant) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if failing { throw WorkspaceError.invalid("Keychain denied access.") }
        return values[assistant]
    }
    func save(_ key: String, for assistant: Assistant) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw WorkspaceError.invalid("Keychain denied access.") }
        values[assistant] = key
    }
    func remove(_ assistant: Assistant) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw WorkspaceError.invalid("Keychain denied access.") }
        values[assistant] = nil
    }
}

@MainActor final class CredentialTests: XCTestCase {
    func testKeysReloadAcrossAppModelsWithoutEnteringMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentialStore()
        let first = AppModel(storageRoot: root, automaticallyRefresh: false, credentialStore: credentials)
        let saveError = await first.saveCredential("  synthetic-codex-key  ", for: .codex)
        XCTAssertNil(saveError)
        let creationError = await first.create(name: "Demo", source: nil)
        XCTAssertNil(creationError)
        let data = try Data(contentsOf: root.appendingPathComponent("workspaces.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-codex-key"))
        let second = AppModel(storageRoot: root, automaticallyRefresh: false, credentialStore: credentials)
        await second.loadCredentials()
        XCTAssertEqual(second.apiKeys[.codex], "synthetic-codex-key")
        XCTAssertNil(second.apiKeys[.claude])
        let removeError = await second.removeCredential(.codex)
        XCTAssertNil(removeError)
        XCTAssertNil(second.apiKeys[.codex])
        XCTAssertNil(try credentials.load(.codex))
    }
    func testSaveAndRemoveFailuresPreservePreviouslyStoredKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentialStore()
        let model = AppModel(storageRoot: root, automaticallyRefresh: false, credentialStore: credentials)
        _ = await model.saveCredential("previous-key", for: .codex)
        credentials.fail(true)
        let saveError = await model.saveCredential("replacement-key", for: .codex)
        XCTAssertNotNil(saveError)
        XCTAssertEqual(model.apiKeys[.codex], "previous-key")
        let removeError = await model.removeCredential(.codex)
        XCTAssertNotNil(removeError)
        XCTAssertEqual(model.apiKeys[.codex], "previous-key")
        await model.reloadCredential(.codex)
        XCTAssertNil(model.apiKeys[.codex])
        XCTAssertNotNil(model.credentialErrors[.codex])
        credentials.fail(false)
        await model.reloadCredential(.codex)
        XCTAssertEqual(model.apiKeys[.codex], "previous-key")
        XCTAssertNil(model.credentialErrors[.codex])
    }
    func testInvalidKeysNeverReachStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = TestCredentialStore()
        let model = AppModel(storageRoot: root, automaticallyRefresh: false, credentialStore: credentials)
        for input in ["", "\n", "key with spaces", "two\nlines", String(repeating: "x", count: 4097)] {
            let error = await model.saveCredential(input, for: .codex)
            XCTAssertNotNil(error)
            XCTAssertNil(try credentials.load(.codex))
        }
    }
}
