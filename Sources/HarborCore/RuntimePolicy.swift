import Foundation

public struct HostCapacity: Sendable {
    public let cpus: Int
    public let memoryGiB: Int
    public init(cpus: Int, memoryGiB: Int) { self.cpus = max(1, cpus); self.memoryGiB = max(1, memoryGiB - 2) }
    public static var current: Self {
        Self(cpus: ProcessInfo.processInfo.activeProcessorCount, memoryGiB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }
}
public enum RuntimePolicy {
    public static func validate(_ workspace: Workspace, capacity: HostCapacity = .current, needsAI: Bool = false) throws {
        guard (1...capacity.cpus).contains(workspace.cpuLimit), (1...capacity.memoryGiB).contains(workspace.memoryLimit) else {
            throw WorkspaceError.invalid("Choose 1–\(capacity.cpus) CPU cores and 1–\(capacity.memoryGiB) GB memory in Settings. Harbor leaves at least 2 GB for macOS.")
        }
        guard [15, 30, 60, 120].contains(workspace.minutes) else { throw WorkspaceError.invalid("Choose a run allowance of 15, 30, 60, or 120 minutes in Settings.") }
        guard (1024...65535).contains(workspace.effectivePreviewPort) else { throw WorkspaceError.invalid("Choose a preview port between 1024 and 65535.") }
        if needsAI && !workspace.allowsInternet { throw WorkspaceError.invalid("Turn on Internet in Settings to use a cloud assistant. Offline workspaces cannot send AI requests.") }
        if let limit = workspace.storageWarningMiB, !(1...1_048_576).contains(limit) { throw WorkspaceError.invalid("Choose a positive storage warning threshold, up to 1 TB.") }
    }
    public static func runArguments(_ w: Workspace, project: URL, id: String, image: String, now: Date = Date()) throws -> [String] {
        try validate(w)
        guard !project.path.contains(":"), !project.path.contains(",") else { throw WorkspaceError.invalid("The working folder path contains a character unsupported by the runtime.") }
        let deadline = w.deadline ?? now.addingTimeInterval(Double(w.minutes * 60))
        var args = ["run", "-d", "--name", id, "--cpus", String(w.cpuLimit), "--memory", "\(w.memoryLimit)G",
                    "--env", "HARBOR_DEADLINE_MS=\(Int64(deadline.timeIntervalSince1970 * 1000))",
                    "--env", "HARBOR_RUN_ID=\(id)", "--workdir", "/workspace"]
        args += ["--mount", "type=bind,source=\(project.path),target=/workspace" + (w.allowsFileChanges ? "" : ",readonly")]
        if !w.allowsLowLevelTools {
            for capability in ["NET_RAW", "NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE", "SYS_MODULE", "SYS_RAWIO", "SYS_BOOT", "SYS_TIME"] {
                args += ["--cap-drop", capability]
            }
        }
        if !w.allowsInternet { args += ["--network", "none"] }
        if w.canPreview { args += ["--publish", "127.0.0.1:\(w.effectivePreviewPort):4173"] }
        args += [image, "node", "/opt/harbor/preview.cjs"]
        return args
    }
    public static func containerIDs(_ text: String) throws -> [String] {
        guard let data = text.data(using: .utf8), let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw WorkspaceError.invalid("Unable to confirm container state: unrecognized runtime response.")
        }
        return try entries.map { entry in
            guard let id = (entry["id"] as? String) ?? ((entry["configuration"] as? [String: Any])?["id"] as? String), !id.isEmpty else {
                throw WorkspaceError.invalid("Unable to confirm container state: missing container identity.")
            }
            return id
        }
    }
    public static func isStopped(_ text: String, id: String) throws -> Bool {
        guard let entries = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]],
              entries.count == 1, let entry = entries.first,
              (entry["id"] as? String) == id,
              let state = (entry["status"] as? [String: Any])?["state"] as? String,
              ["running", "stopped"].contains(state) else {
            throw WorkspaceError.invalid("The runtime did not confirm this workspace’s state.")
        }
        return state == "stopped"
    }
}

public struct ResourceSample: Decodable, Sendable {
    public let id: String
    public let memoryUsageBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public let cpuUsageUsec: UInt64?
    public let numProcesses: UInt64?
    public static func parse(_ text: String, id: String) throws -> Self {
        let values = try JSONDecoder().decode([Self].self, from: Data(text.utf8))
        guard values.count == 1, let sample = values.first, sample.id == id else {
            throw WorkspaceError.invalid("Resource measurements are unavailable for this run.")
        }
        return sample
    }
    public func cpuFraction(previous: Self, interval: TimeInterval, cores: Int) -> Double? {
        guard id == previous.id, interval > 0, cores > 0, let current = cpuUsageUsec, let old = previous.cpuUsageUsec, current >= old else { return nil }
        return Double(current - old) / 1_000_000 / interval / Double(cores)
    }
}
public struct ResourceReading: Sendable {
    public let sample: ResourceSample
    public let sampledAt: Date
    public let uptime: TimeInterval
    public let cpuFraction: Double?
    public let allocatedCores: Int
    public init(sample: ResourceSample, previous: Self?, cores: Int, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.sample = sample; self.sampledAt = now; self.uptime = uptime; self.allocatedCores = cores
        self.cpuFraction = previous.flatMap { sample.cpuFraction(previous: $0.sample, interval: uptime - $0.uptime, cores: cores) }
    }
}
public struct WorkspaceProblem: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public let title: String
    public let detail: String
    public init(title: String, detail: String) { self.title = title; self.detail = detail }
}
public struct ProviderUsage: Codable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var reportedCostUSD: Double?
    public init(inputTokens: Int, outputTokens: Int, reportedCostUSD: Double? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.reportedCostUSD = reportedCostUSD
    }
}
