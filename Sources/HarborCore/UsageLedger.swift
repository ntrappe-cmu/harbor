import Foundation

public struct UsagePreference: Codable, Sendable {
    public var monthlyBudgetUSD: Double = 0
    public var showOverview = true
    public var warnWhenLow = true
    public init() {}
}

public struct UsageEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let assistant: Assistant
    public let date: Date
    public var usage: ProviderUsage?
    public var finished = false
    public var finalReportConfirmed = false
    public var reportedAt: Date?
    public var demoEstimatedUSD: Double?
    public var followup: Bool?
    public init(id: UUID, assistant: Assistant, date: Date = Date()) {
        self.id = id; self.assistant = assistant; self.date = date
    }
    private enum CodingKeys: String, CodingKey { case id, assistant, date, usage, finished, finalReportConfirmed, reportedAt, demoEstimatedUSD, followup }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); assistant = try c.decode(Assistant.self, forKey: .assistant); date = try c.decode(Date.self, forKey: .date)
        usage = try c.decodeIfPresent(ProviderUsage.self, forKey: .usage)
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        finalReportConfirmed = try c.decodeIfPresent(Bool.self, forKey: .finalReportConfirmed) ?? false
        reportedAt = try c.decodeIfPresent(Date.self, forKey: .reportedAt)
        demoEstimatedUSD = try c.decodeIfPresent(Double.self, forKey: .demoEstimatedUSD)
        followup = try c.decodeIfPresent(Bool.self, forKey: .followup)
    }

}

public struct UsageSummary: Sendable {
    public let count: Int
    public let missingCosts: Int
    public let active: Bool
    public let reportedCost: Double
    public let lastReport: Date?
    public func remaining(budget: Double) -> Double? {
        guard budget.isFinite, budget > 0, missingCosts == 0, !active else { return nil }
        return max(0, budget - reportedCost)
    }
}

/// Local reported costs only. No prices inferred from token counts or external account balance.
public struct UsageLedger: Codable, Sendable {
    public var preferences: [String: UsagePreference] = [:]
    public var entries: [UsageEntry] = []
    public var demoMode: Bool? = true
    public init() {}
    public func preference(_ assistant: Assistant) -> UsagePreference { preferences[assistant.rawValue] ?? UsagePreference() }
    public mutating func begin(id: UUID, assistant: Assistant, date: Date = Date(), prompt: String = "", followup: Bool = false) {
        guard !entries.contains(where: { $0.id == id }) else { return }
        var entry = UsageEntry(id: id, assistant: assistant, date: date)
        entry.demoEstimatedUSD = Self.demoEstimate(prompt: prompt); entry.followup = followup
        entries.append(entry)
    }
    public mutating func report(id: UUID, usage: ProviderUsage) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // CLI terminal reports are cumulative; streamed and final copies must not double count.
        guard usage.reportedCostUSD.map({ $0.isFinite && $0 >= 0 }) ?? true else { return }
        var scoped = usage
        // Resumed CLI reports may have session-wide scope. Preserve tokens but do not aggregate unverified dollar totals.
        if entries[index].followup == true { scoped.reportedCostUSD = nil }
        entries[index].usage = scoped
        entries[index].reportedAt = Date()
    }
    public mutating func finish(id: UUID, confirmed: Bool = false) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].finished = true
            entries[index].finalReportConfirmed = entries[index].finalReportConfirmed || confirmed
        }
    }
    public static func demoEstimate(prompt: String) -> Double {
        // Synthetic prototype heuristic, deliberately unrelated to provider model prices.
        min(5, 0.5 + Double(prompt.utf8.count) / 2000)
    }
    public var isDemo: Bool { demoMode ?? true }
    public func demoSpent(_ assistant: Assistant) -> Double {
        entries.filter { $0.assistant == assistant }.compactMap(\.demoEstimatedUSD).reduce(0, +)
    }
    public var demoTotalSpent: Double { entries.compactMap(\.demoEstimatedUSD).reduce(0, +) }
    public var demoBalance: Double { max(0, 40 - demoTotalSpent) }
    public func summary(_ assistant: Assistant, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let period = calendar.dateInterval(of: .month, for: now)
        let rows = entries.filter { $0.assistant == assistant && (period?.contains($0.date) ?? false) }
        return UsageSummary(count: rows.count, missingCosts: rows.filter { $0.usage?.reportedCostUSD == nil || !$0.finalReportConfirmed }.count,
                            active: entries.contains { $0.assistant == assistant && !$0.finished }, reportedCost: rows.compactMap { $0.usage?.reportedCostUSD }.reduce(0, +),
                            lastReport: rows.compactMap(\.reportedAt).max())
    }
}
