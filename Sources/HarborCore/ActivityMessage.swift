import Foundation

public struct ActivityMessage: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var count: Int
    public var firstSeen: Date?
    public var lastSeen: Date?
    public init(text: String, count: Int = 1, date: Date? = nil) {
        id = UUID(); self.text = text; self.count = count; firstSeen = date; lastSeen = date
    }
    public static func grouped(_ lines: [String]) -> [Self] {
        var result: [Self] = []
        for line in lines where !line.isEmpty { record(line, in: &result, date: nil) }
        return result
    }
    public static func record(_ text: String, in messages: inout [Self], date: Date?) {
        if let index = messages.firstIndex(where: { $0.text == text }) {
            var message = messages.remove(at: index)
            if message.count < Int.max { message.count += 1 }
            message.lastSeen = date
            messages.append(message)
        } else { messages.append(Self(text: text, date: date)) }
    }
}

extension Workspace {
    public var groupedActivity: [ActivityMessage] { activityMessages ?? ActivityMessage.grouped(events) }
    public var groupedPreviousActivity: [ActivityMessage] { previousActivityMessages ?? ActivityMessage.grouped(previousEvents ?? []) }
    public mutating func recordActivity(_ text: String, at date: Date = Date()) {
        var messages = groupedActivity
        ActivityMessage.record(text, in: &messages, date: date)
        activityMessages = Array(messages.suffix(50))
        events = activityMessages!.map(\.text)
        lastMessage = text
    }
    public mutating func archiveActivity(label: String) {
        // Keep run boundaries: identical messages from different tasks remain separate.
        previousActivityMessages = Array((groupedPreviousActivity + [ActivityMessage(text: label)] + groupedActivity).suffix(100))
        previousEvents = previousActivityMessages!.map(\.text)
        activityMessages = []; events = []
    }
}
