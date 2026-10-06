import Foundation
import CryptoKit

public enum Performance: String, Codable, CaseIterable, Identifiable, Sendable {
    case gentle = "Keep my Mac responsive"
    case balanced = "Balanced"
    case focused = "Prioritize this workspace"
    case turbo = "Turbo"
    public var id: String { rawValue }
    // Keep existing persisted values compatible while simplifying display names.
    public var title: String {
        switch self {
        case .gentle: return "Light"
        case .balanced: return "Balanced"
        case .focused: return "Boost"
        case .turbo: return "Turbo"
        }
    }
    public var cpus: Int {
        switch self {
        case .gentle: return 1
        case .balanced: return 2
        case .focused: return 4
        case .turbo: return 8
        }
    }
    public var memoryGiB: Int {
        switch self {
        case .gentle: return 2
        case .balanced: return 4
        case .focused: return 6
        case .turbo: return 8
        }
    }
    public var detail: String { "Up to \(cpus) CPU cores · \(memoryGiB) GB memory per run" }
}

public enum RunState: String, Codable, Sendable {
    case ready, starting, running, stopping, stopped, completed, failed, interrupted
    public var label: String { rawValue.capitalized }
    public var isActive: Bool { [.starting, .running, .stopping].contains(self) }
}

public struct Workspace: Identifiable, Codable, Sendable {
    public var promptHistory: [PromptHistoryItem]?
    public var id: UUID
    public var name: String
    public var created: Date
    public var minutes: Int
    public var performance: Performance
    public var cpuOverride: Int?
    public var memoryOverride: Int?
    public var internetAllowed: Bool?
    public var fileChangesAllowed: Bool?
    public var lowLevelToolsAllowed: Bool?
    public var activityMessages: [ActivityMessage]?
    public var previousActivityMessages: [ActivityMessage]?
    public var previewEnabled: Bool?
    public var previewPort: Int?
    public var storageWarningMiB: Int?
    public var problems: [WorkspaceProblem]?
    public var previousProblems: [WorkspaceProblem]?
    public var previousEvents: [String]?
    public var providerUsage: ProviderUsage?
    public var allowsFileChanges: Bool { fileChangesAllowed ?? true }
    public var allowsLowLevelTools: Bool { lowLevelToolsAllowed ?? false }
    public var allowsInternet: Bool { internetAllowed ?? true }
    public var canPreview: Bool { allowsInternet && (previewEnabled ?? true) }
    public var effectivePreviewPort: Int { previewPort ?? 4173 }
    public var cpuLimit: Int { cpuOverride ?? performance.cpus }
    public var memoryLimit: Int { memoryOverride ?? performance.memoryGiB }
    public var performanceTitle: String { cpuOverride == nil && memoryOverride == nil ? performance.title : "Custom" }
    public var state: RunState
    public var runID: String?
    public var startedAt: Date?
    public var deadline: Date?
    public var lastMessage: String
    public var events: [String]
    public var sourceDescription: String
    public var importedFolder: Bool?
    public var showsFileBreakdown: Bool { importedFolder ?? (sourceDescription != "New starter project") }
    public var assistant: Assistant = .claude
    public init(name: String) {
        id = UUID(); self.name = name; created = Date(); minutes = 30
        performance = .balanced; state = .ready; lastMessage = "Ready when you are."
        events = []; sourceDescription = "New starter project"
    }
    public func remainingSeconds(at date: Date) -> Int? {
        deadline.map { max(0, Int(ceil($0.timeIntervalSince(date)))) }
    }
    public mutating func extend(by minutes: Int) {
        guard let deadline else { return }
        self.deadline = deadline.addingTimeInterval(Double(minutes * 60))
    }
}

public struct PromptHistoryItem: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var date = Date()
    public let assistant: Assistant
    public let text: String
    public var elapsedSeconds: Int?
    public var outcome: String?
    public var latestActivity: String?
    public init(assistant: Assistant, text: String) { self.assistant = assistant; self.text = text }
}

public enum WorkspaceValidation {
    public static func nameError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a workspace name." }
        if trimmed == "." || trimmed == ".." { return "Choose a descriptive name instead of a dot or two dots." }
        if trimmed.utf8.count > 120 { return "Use a shorter name (up to 120 UTF-8 bytes)." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Names cannot contain line breaks or control characters."
        }
        if trimmed.contains(where: { "/\\:".contains($0) }) { return "Names cannot contain /, \\, or :." }
        if trimmed.hasPrefix(".") { return "Start the name with something other than a dot." }
        return nil
    }
    public static func sourceError(_ source: URL, storeRoot: URL) -> String? {
        guard source.isFileURL else { return "Choose a local project folder." }
        let folder = source.resolvingSymlinksInPath().standardizedFileURL
        let path = folder.path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        let broad = ["/", "/Users", "/Volumes", "/private", "/private/var", "/private/tmp", "/System/Volumes/Data", home,
                     home + "/Desktop", home + "/Documents", home + "/Downloads"]
        if broad.contains(path) { return "Choose a specific project folder, rather than an entire disk or personal folder." }
        let protected = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", home + "/Library", home + "/.ssh", home + "/.aws", home + "/.codex", home + "/.claude"]
        if protected.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "This is a system or application-data folder. Choose a project folder instead."
        }
        let storage = storeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if path == storage || path.hasPrefix(storage + "/") || storage.hasPrefix(path + "/") {
            return "Choose a folder outside Harbor’s workspace storage."
        }
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isVolumeKey]),
              values.isDirectory == true else { return "This folder no longer exists or cannot be opened." }
        if values.isVolume == true { return "Choose a project folder inside this disk." }
        if values.isReadable != true { return "Harbor cannot read this folder. Choose another folder or update its permissions." }
        return nil
    }
}

public enum WorkspaceError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct ImportReport: Sendable {
    public var copied = 0
    public var skipped: [String] = []
}

public struct FileChange: Identifiable, Sendable {
    public let path: String
    public let kind: String
    public var id: String { path }
}

public struct FileWorkspaceStore: Sendable {
    public let root: URL
    public init(readOnlyRoot: URL) { self.root = readOnlyRoot }
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func project(for id: UUID) -> URL { directory(for: id).appendingPathComponent("Project", isDirectory: true) }
    public func load() throws -> [Workspace] {
        let url = root.appendingPathComponent("workspaces.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let workspaces = try JSONDecoder().decode([Workspace].self, from: Data(contentsOf: url))
        // Recover a deletion interrupted before the workspace index was committed.
        for workspace in workspaces {
            let original = directory(for: workspace.id)
            let staged = root.appendingPathComponent(".deleted-" + workspace.id.uuidString)
            if !FileManager.default.fileExists(atPath: original.path), FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.moveItem(at: staged, to: original)
            }
        }
        return workspaces
    }
    public func save(_ workspaces: [Workspace]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspaces).write(to: root.appendingPathComponent("workspaces.json"), options: .atomic)
    }
    public func delete(_ workspace: Workspace, from workspaces: [Workspace]) throws {
        if let staged = try stageDeletion(workspace, from: workspaces) { try FileManager.default.removeItem(at: staged) }
    }
    public func stageDeletion(_ workspace: Workspace, from workspaces: [Workspace]) throws -> URL? {
        guard workspace.runID == nil else { throw WorkspaceError.invalid("Stop this workspace before deleting its files.") }
        let fm = FileManager.default
        let original = directory(for: workspace.id)
        let staged = root.appendingPathComponent(".deleted-" + workspace.id.uuidString)
        let exists = fm.fileExists(atPath: original.path)
        if exists { try fm.moveItem(at: original, to: staged) }
        do { try save(workspaces.filter { $0.id != workspace.id }) }
        catch {
            if exists { try fm.moveItem(at: staged, to: original) }
            throw error
        }
        return exists ? staged : nil
    }
    public func checkpoint(_ workspace: Workspace) throws {
        let folder = directory(for: workspace.id)
        let pending = folder.appendingPathComponent("Snapshot-pending")
        let snapshot = folder.appendingPathComponent("Snapshot")
        let fm = FileManager.default
        if fm.fileExists(atPath: pending.path) { try fm.removeItem(at: pending) }
        try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        _ = try Self.copyTree(from: project(for: workspace.id), to: pending, omitSensitive: false)
        if fm.fileExists(atPath: snapshot.path) { try fm.removeItem(at: snapshot) }
        try fm.moveItem(at: pending, to: snapshot)
    }
    public func hasCheckpoint(_ workspace: Workspace) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: workspace.id).appendingPathComponent("Snapshot").path)
    }
    public func restore(_ workspace: Workspace) throws {
        let fm = FileManager.default
        let snapshot = directory(for: workspace.id).appendingPathComponent("Snapshot")
        guard fm.fileExists(atPath: snapshot.path) else { throw WorkspaceError.invalid("There is no earlier version to restore.") }
        let current = project(for: workspace.id)
        let staging = directory(for: workspace.id).appendingPathComponent("Restore-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try Self.copyTree(from: snapshot, to: staging, omitSensitive: false)
        let old = directory(for: workspace.id).appendingPathComponent("Before-Restore-" + UUID().uuidString)
        try fm.moveItem(at: current, to: old)
        do { try fm.moveItem(at: staging, to: current) }
        catch { try? fm.moveItem(at: old, to: current); throw error }
        try? fm.removeItem(at: old)
    }
    public func changes(_ workspace: Workspace) throws -> [FileChange] {
        let before = try Self.manifest(directory(for: workspace.id).appendingPathComponent("Snapshot"))
        let after = try Self.manifest(project(for: workspace.id))
        return Set(before.keys).union(after.keys).sorted().compactMap { path in
            guard before[path] != after[path] else { return nil }
            return FileChange(path: path, kind: before[path] == nil ? "Added" : after[path] == nil ? "Removed" : "Changed")
        }
    }
    private static func manifest(_ root: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        var result: [String: String] = [:]
        var failure: Error?
        let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], errorHandler: { _, error in failure = error; return false })!
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            var hash = SHA256()
            do {
                while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
                try handle.close()
            } catch { try? handle.close(); throw error }
            result[file.pathComponents.suffix(iterator.level).joined(separator: "/")] = hash.finalize().description
        }
        if let failure { throw failure }
        return result
    }
    public func create(_ workspace: Workspace, source: URL?) throws -> ImportReport {
        if let message = WorkspaceValidation.nameError(workspace.name) { throw WorkspaceError.invalid(message) }
        if let source, let message = WorkspaceValidation.sourceError(source, storeRoot: root) { throw WorkspaceError.invalid(message) }
        let destination = project(for: workspace.id)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            if let source { return try Self.copyTree(from: source, to: destination, omitSensitive: true) }
            try Self.starterHTML.write(to: destination.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            return ImportReport(copied: 1)
        } catch {
            try? FileManager.default.removeItem(at: directory(for: workspace.id))
            throw error
        }
    }
    public func export(_ workspace: Workspace, to destination: URL) throws -> ImportReport {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceError.invalid("Choose a new folder. Harbor never overwrites an existing export.")
        }
        let source = project(for: workspace.id).resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !target.path.hasPrefix(source.path + "/") else {
            throw WorkspaceError.invalid("Choose a location outside this workspace.")
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do { return try Self.copyTree(from: source, to: target, omitSensitive: false) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
    }
    // Reject symlinks and special files on both import and export. No shared home mounts.
    public static func copyTree(from source: URL, to destination: URL, omitSensitive: Bool) throws -> ImportReport {
        let fm = FileManager.default
        let src = source.resolvingSymlinksInPath().standardizedFileURL
        let dst = destination.resolvingSymlinksInPath().standardizedFileURL
        guard src != dst, !dst.path.hasPrefix(src.path + "/") else {
            throw WorkspaceError.invalid("The source cannot contain Harbor’s working folder.")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var traversalError: Error?
        guard let entries = fm.enumerator(at: src, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in traversalError = error; return false }) else {
            throw WorkspaceError.invalid("This folder could not be read.")
        }
        var report = ImportReport(); var total: Int64 = 0
        for case let file as URL in entries {
            let relative = file.pathComponents.suffix(entries.level).joined(separator: "/")
            let values = try file.resourceValues(forKeys: keys)
            let name = file.lastPathComponent
            let excluded = [".git", ".claude", ".codex", ".mcp.json", "node_modules", ".DS_Store", ".ssh", ".aws", ".npmrc", ".pypirc", "credentials.json"].contains(name)
                || name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".pem") || name.hasSuffix(".key")
            if values.isSymbolicLink == true || (omitSensitive && excluded) {
                entries.skipDescendants(); report.skipped.append(relative); continue
            }
            let output = dst.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
                guard total <= 1_073_741_824, report.copied < 20_000 else {
                    throw WorkspaceError.invalid("This folder exceeds Harbor’s import limit of 1 GB or 20,000 files. Choose a smaller project folder, or move large assets out of it and try again.")
                }
                try fm.copyItem(at: file, to: output); report.copied += 1
            } else { report.skipped.append(relative) }
        }
        if let traversalError { throw traversalError }
        return report
    }
    public static let starterHTML = """
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>A fresh start</title><style>body{margin:0;background:#f6f5f1;color:#283b36;font-family:system-ui;display:grid;place-items:center;min-height:100vh}main{max-width:620px;padding:48px}small{letter-spacing:.16em;text-transform:uppercase}h1{font-size:64px;letter-spacing:-3px;line-height:1.05;font-weight:550}p{font-size:20px;line-height:1.6;color:#64716c}button{padding:14px 22px;border:0;border-radius:12px;background:#283b36;color:white;font-size:16px}</style>
    <main><small>Your private workspace</small><h1>Make room for<br>your next idea.</h1><p>This is your working copy. Try a change, explore a direction, and keep what you like.</p><button onclick="this.textContent='It works. Keep exploring.'">Try the interaction</button></main></html>
    """
}
