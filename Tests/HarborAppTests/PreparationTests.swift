import XCTest
import HarborCore
@testable import Harbor

@MainActor final class PreparationTests: XCTestCase {
    func testCancelBuildInterruptsCommandAndAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, automaticallyRefresh: false)
        let executable = root.appendingPathComponent("fake-runtime")
        let script = """
        #!/bin/sh
        case "$1" in
        --version) printf 'container CLI version 1.5.0';;
        system) exit 0;;
        image) printf 'existing image';;
        build)
          if [ -f "$0.cancelled" ]; then exit 0; fi
          trap 'touch "$0.cancelled"; exit 130' INT
          printf 'BUILDREADY\n'
          while :; do sleep 0.05; done;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        model.runtimePath = executable.path
        let preparation = Task { await model.prepare() }
        for _ in 0..<200 {
            if model.setupLog.contains("BUILDREADY") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.preparingBuild)
        XCTAssertTrue(model.setupLog.contains("BUILDREADY"))
        model.cancelPreparation()
        XCTAssertTrue(model.cancelingPreparation)
        await preparation.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path + ".cancelled"), "Build should receive SIGINT, not only terminate waiting")
        XCTAssertFalse(model.preparing)
        XCTAssertFalse(model.cancelingPreparation)
        XCTAssertTrue(model.environmentReady, "Previously installed tools remain usable")
        XCTAssertNil(model.error, "User cancellation is not an error alert")
        XCTAssertTrue(model.setupLog.contains("build command was cancelled"))
        await model.prepare()
        XCTAssertFalse(model.preparing)
        XCTAssertEqual(model.runtimeStatus, "Ready on this Mac")
    }

    func testCancelUnavailableWhileStartingService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, automaticallyRefresh: false)
        let executable = root.appendingPathComponent("fake-runtime")
        try "#!/bin/sh\ncase \"$1\" in\nsystem) sleep 0.2;;\n--version) printf 'container CLI version 1.5.0';;\nesac\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        model.runtimePath = executable.path
        let preparation = Task { await model.prepare() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.preparing)
        XCTAssertFalse(model.preparingBuild)
        model.cancelPreparation()
        XCTAssertFalse(model.cancelingPreparation)
        await preparation.value
        XCTAssertTrue(model.environmentReady)
    }
}
