import AppKit
import SwiftUI

/// Plain-text SQL editor backed by `NSTextView`. Reports the selection as UTF-16 offsets, exactly
/// what `StatementSplitter` expects (SwiftUI's `TextEditor` doesn't reliably report selections).
/// Phase 6 adds highlighting and autocomplete on top of this.
struct SQLTextView: NSViewRepresentable {
    @Binding var text: String
    /// Selected range in UTF-16 offsets; empty range = caret position.
    @Binding var selection: Range<Int>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize + 1, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // SQL must never be "corrected": smart quotes/dashes silently break queries.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.string = text
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        let wanted = NSRange(location: selection.lowerBound, length: selection.count)
        let length = (textView.string as NSString).length
        if textView.selectedRange() != wanted, NSMaxRange(wanted) <= length {
            textView.setSelectedRange(wanted)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextView
        weak var textView: NSTextView?

        init(_ parent: SQLTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            publishSelection(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            publishSelection(textView)
        }

        private func publishSelection(_ textView: NSTextView) {
            let range = textView.selectedRange()
            let new = range.location..<(range.location + range.length)
            if parent.selection != new { parent.selection = new }
        }
    }
}
