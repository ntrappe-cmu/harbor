import XCTest
@testable import HarborCore

final class UsageLedgerTests: XCTestCase {
    func testDuplicateReportsReplaceAndUnknownCostsSuppressRemaining() throws {
        var ledger = UsageLedger(); let id = UUID()
        ledger.begin(id: id, assistant: .claude); ledger.begin(id: id, assistant: .claude)
        XCTAssertNil(ledger.summary(.claude).remaining(budget: 10))
        let usage = ProviderUsage(inputTokens: 5, outputTokens: 2, reportedCostUSD: 2)
        ledger.report(id: id, usage: usage); ledger.report(id: id, usage: usage)
        XCTAssertNil(ledger.summary(.claude).remaining(budget: 10)) // Still running.
        ledger.finish(id: id, confirmed: true)
        XCTAssertEqual(ledger.summary(.claude).remaining(budget: 10), 8)
        XCTAssertEqual(ledger.entries.count, 1)
        ledger.begin(id: UUID(), assistant: .claude)
        XCTAssertNil(ledger.summary(.claude).remaining(budget: 10))
        let restored = try JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertNil(restored.summary(.claude).remaining(budget: 10))
    }
    func testInterruptedCostIsNotAFinalBalance() {
        var ledger = UsageLedger(); let id = UUID()
        ledger.begin(id: id, assistant: .claude)
        ledger.report(id: id, usage: ProviderUsage(inputTokens: 1, outputTokens: 1, reportedCostUSD: 2))
        ledger.finish(id: id)
        XCTAssertNil(ledger.summary(.claude).remaining(budget: 10))
        XCTAssertEqual(ledger.summary(.claude).reportedCost, 2)
    }
    func testDemoBalanceIsSeparateAndEstimatesEachTaskOnce() throws {
        var ledger = UsageLedger(); let id = UUID()
        XCTAssertEqual(ledger.demoBalance, 40)
        ledger.begin(id: id, assistant: .codex, prompt: String(repeating: "x", count: 2000))
        ledger.begin(id: id, assistant: .codex, prompt: "Duplicate")
        ledger.report(id: id, usage: ProviderUsage(inputTokens: 2, outputTokens: 2, reportedCostUSD: 100))
        XCTAssertEqual(ledger.demoBalance, 38.5)
        XCTAssertEqual(ledger.summary(.codex).reportedCost, 100)
        XCTAssertEqual(try JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(ledger)).demoBalance, 38.5)
        let followup = UUID(); ledger.begin(id: followup, assistant: .codex, followup: true)
        ledger.report(id: followup, usage: ProviderUsage(inputTokens: 10, outputTokens: 2, reportedCostUSD: 110))
        XCTAssertEqual(ledger.summary(.codex).reportedCost, 100) // Unverified session-cumulative amount excluded.
    }
    func testOlderEntryDecodesWithoutNewFlags() throws {
        let text = "{\"id\":\"" + UUID().uuidString + "\",\"assistant\":\"Codex\",\"date\":0}"
        let entry = try JSONDecoder().decode(UsageEntry.self, from: Data(text.utf8))
        XCTAssertFalse(entry.finished); XCTAssertFalse(entry.finalReportConfirmed)
    }
    func testMonthlyProviderScopeAndOverBudget() {
        var ledger = UsageLedger(); let now = Date(), id = UUID()
        ledger.begin(id: id, assistant: .codex, date: now)
        ledger.report(id: id, usage: ProviderUsage(inputTokens: 10, outputTokens: 10, reportedCostUSD: 15)); ledger.finish(id: id, confirmed: true)
        let old = UUID(); ledger.begin(id: old, assistant: .codex, date: Calendar.current.date(byAdding: .month, value: -1, to: now)!)
        XCTAssertNil(ledger.summary(.codex, now: now).remaining(budget: 10)) // Prior-month task still running.
        ledger.finish(id: old)
        XCTAssertEqual(ledger.summary(.codex, now: now).remaining(budget: 10), 0)
        XCTAssertEqual(ledger.summary(.claude, now: now).count, 0)
        XCTAssertNil(ledger.summary(.codex).remaining(budget: 0))
    }
}
