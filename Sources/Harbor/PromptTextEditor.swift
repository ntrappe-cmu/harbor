import SwiftUI
import AppKit

// Native paragraph alignment avoids inheriting the trailing value-column
// alignment used by macOS grouped forms.
struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        let editor = scroll.documentView as! NSTextView
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.alignment = .left
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        editor.setAccessibilityLabel("Task prompt")
        editor.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEnabled
        guard !editor.hasMarkedText() else { return }
        if editor.string != text {
            let selected = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
        }
        editor.alignment = .left
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextEditor
        init(_ parent: PromptTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
