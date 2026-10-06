import SwiftUI
import HarborCore

struct ActivityMessageRow: View {
    let message: ActivityMessage
    var monospaced = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message.text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.count > 1 {
                Text("×\(message.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .accessibilityLabel("Repeated \(message.count) times")
                    .help(message.firstSeen.flatMap { first in message.lastSeen.map { "First: \(first.formatted()) · Latest: \($0.formatted())" } } ?? "Repeated \(message.count) times in the retained log.")
            }
        }
    }
}
