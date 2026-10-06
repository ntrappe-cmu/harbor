import Foundation

public enum Assistant: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude = "Claude Code"
    case codex = "Codex"
    public var id: String { rawValue }
    public var executable: String { self == .claude ? "claude" : "codex" }
    public var runArguments: [String] {
        switch self {
        case .claude: return ["claude", "-p", "--verbose", "--output-format", "stream-json", "--permission-mode", "acceptEdits"]
        case .codex: return ["codex", "exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write", "-"]
        }
    }
}

extension Assistant {
    public func arguments(resuming session: String?) -> [String] {
        guard let session else { return runArguments }
        if self == .claude { return runArguments + ["--resume", session] }
        return ["codex", "exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write", "resume", session, "-"]
    }
}

public enum AgentEvent {
    public static func summary(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let type = object["type"] as? String ?? ""
        if type == "error" || type == "turn.failed" {
            return "Assistant reported an error. Open details to review."
        }
        if type == "result" {
            return object["is_error"] as? Bool == true ? "Assistant reported an error." : "Assistant finished its response."
        }
        if type == "turn.completed" { return "Assistant finished its response." }
        if type == "item.started", let item = object["item"] as? [String: Any] {
            switch item["type"] as? String {
            case "command_execution": return "Running a project command."
            case "file_change": return "Updating working files."
            default: return "Working on your request."
            }
        }
        if type == "assistant" { return "Assistant is working on your request." }
        if type == "system" || type == "thread.started" { return "Assistant connected." }
        return nil
    }
}

extension AgentEvent {
    public static func sessionID(_ line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let value = (object["thread_id"] as? String) ?? (object["session_id"] as? String), UUID(uuidString: value) != nil else { return nil }
        return value
    }
    public static func failed(_ line: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        let type = object["type"] as? String
        return type == "turn.failed" || type == "error" || (type == "result" && object["is_error"] as? Bool == true)
    }
    public static func usage(_ line: String) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              ["result", "turn.completed"].contains(object["type"] as? String ?? ""),
              let usage = object["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int, let output = usage["output_tokens"] as? Int,
              input >= 0, output >= 0 else { return nil }
        let cost = object["total_cost_usd"] as? Double
        return ProviderUsage(inputTokens: input, outputTokens: output, reportedCostUSD: cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }
}
