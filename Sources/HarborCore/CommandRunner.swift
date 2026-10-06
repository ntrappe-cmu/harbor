import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let code: Int32
    public let output: String
}
public enum CommandFailure: LocalizedError {
    case timedOut
    public var errorDescription: String? { "The operation timed out. Check Activity for details, then retry." }
}
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// Fixed executable + argument arrays; no host shell interpolation. Bounded output and
// nonblocking pipes avoid hanging on a descendant that inherited stdout or stdin.
public final class CommandRunner: @unchecked Sendable {
    public init() {}
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()
    public func run(_ executable: String, _ arguments: [String], input: String? = nil,
                    timeout: TimeInterval = 60,
                    onOutput: (@Sendable (String) -> Void)? = nil,
                    cancellationSignal: Int32 = SIGTERM) async throws -> CommandResult {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                _ = Self.ignoreBrokenPipe
                if flag.cancelled { throw CancellationError() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                let host = ProcessInfo.processInfo.environment
                process.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                                       "TMPDIR": host["TMPDIR"] ?? "/tmp", "LANG": "en_US.UTF-8", "TERM": "dumb"]
                let pipe = Pipe(), stdin = Pipe()
                process.standardOutput = pipe; process.standardError = pipe; process.standardInput = stdin
                defer {
                    try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
                    try? stdin.fileHandleForReading.close(); try? stdin.fileHandleForWriting.close()
                }
                try process.run()
                try? pipe.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
                let outputFD = pipe.fileHandleForReading.fileDescriptor
                let inputFD = stdin.fileHandleForWriting.fileDescriptor
                _ = fcntl(outputFD, F_SETFL, O_NONBLOCK)
                _ = fcntl(inputFD, F_SETFL, O_NONBLOCK)
                let payload = Data((input ?? "").utf8)
                var written = 0, inputClosed = false
                var output = Data(), pending = Data()
                var buffer = [UInt8](repeating: 0, count: 16_384)
                let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
                var abortedAt: TimeInterval?
                var wasCancelled = false
                while true {
                    let now = ProcessInfo.processInfo.systemUptime
                    if abortedAt == nil && (flag.cancelled || now >= deadline) {
                        abortedAt = now; wasCancelled = flag.cancelled
                        if process.isRunning {
                            if wasCancelled { kill(process.processIdentifier, cancellationSignal) }
                            else { process.terminate() }
                        }
                    }
                    if let abortedAt, now - abortedAt >= 0.3, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    if !inputClosed {
                        if written < payload.count && abortedAt == nil {
                            let count = payload.withUnsafeBytes { bytes in
                                Darwin.write(inputFD, bytes.baseAddress!.advanced(by: written), min(16_384, payload.count - written))
                            }
                            if count > 0 { written += count }
                            else if count < 0 && errno != EAGAIN && errno != EINTR { written = payload.count }
                        }
                        if written == payload.count || abortedAt != nil {
                            try? stdin.fileHandleForWriting.close(); inputClosed = true
                        }
                    }
                    let count = Darwin.read(outputFD, &buffer, buffer.count)
                    if count > 0 {
                        let data = Data(buffer.prefix(count)); output.append(data); pending.append(data)
                        if output.count > 262_144 { output.removeFirst(output.count - 262_144) }
                        if let newline = pending.lastIndex(of: 10) {
                            onOutput?(String(decoding: pending[...newline], as: UTF8.self)); pending.removeSubrange(...newline)
                        }
                        if pending.count > 65_536 { onOutput?(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
                    } else if !process.isRunning { break }
                    // Deadline remains effective even if inherited pipe handles never close.
                    if let abortedAt, now - abortedAt > 2 { break }
                    usleep(10_000)
                }
                if !pending.isEmpty { onOutput?(String(decoding: pending, as: UTF8.self)) }
                if wasCancelled { throw CancellationError() }
                if abortedAt != nil { throw CommandFailure.timedOut }
                process.waitUntilExit()
                return CommandResult(code: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
            }.value
        }, onCancel: { flag.cancel() })
    }
}
