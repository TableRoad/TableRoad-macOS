import AppKit
import Observation
import SwiftUI
import TableRoadCore

/// One cell's full value, shared by the Quick Look popover and its "Open in Window" window.
@MainActor @Observable
final class CellDocument {
    let title: String
    var text: String
    private(set) var original: String
    let isEditable: Bool
    var error: String?
    /// Stages the text as the cell's new value; returns an error message if it can't (e.g. the row changed).
    private let apply: (String) -> String?

    var hasChanges: Bool { isEditable && text != original }

    /// JSON objects and arrays open as a tree; Raw switches to the text editor.
    enum ViewMode { case tree, text }
    var viewMode: ViewMode

    /// The text parsed as JSON (nil if it isn't JSON). Cached per text.
    var json: JSONValue? {
        if parsedText != text {
            parsedText = text
            parsed = SyntaxHighlighter.language(of: text) == .json ? try? JSONValue.parse(text) : nil
        }
        return parsed
    }
    @ObservationIgnored private var parsedText: String?
    @ObservationIgnored private var parsed: JSONValue?

    init(title: String, text: String, isEditable: Bool, apply: @escaping (String) -> String? = { _ in nil }) {
        self.title = title
        self.text = text
        self.original = text
        self.isEditable = isEditable
        self.apply = apply
        self.viewMode = .text
        if json?.children != nil { viewMode = .tree }
    }

    /// Re-formats JSON text (keys keep their order). Reports why when the text isn't valid JSON.
    func formatJSON(pretty: Bool) {
        do {
            let value = try JSONValue.parse(text)
            text = pretty ? value.pretty(indent: 4) : value.minified
            error = nil
        } catch {
            self.error = "Not valid JSON: \(error)"
        }
    }

    /// Stages pending changes (called by Apply and when the editor closes).
    func commitChanges() {
        guard hasChanges else { return }
        if let failure = apply(text) {
            error = failure
        } else {
            original = text
            error = nil
        }
    }
}

/// Code view with line numbers and light highlighting, plus a status bar.
struct CellEditorView: View {
    enum Mode {
        case popover(openInWindow: () -> Void)
        case window(close: () -> Void)
    }

    @Bindable var document: CellDocument
    let mode: Mode
    @State private var position = CursorPosition()

    var body: some View {
        VStack(spacing: 0) {
            if document.viewMode == .tree, let json = document.json {
                JSONTreeView(value: json)
                    .id(document.text)
            } else {
                CodeTextView(text: $document.text, isEditable: document.isEditable, position: $position)
            }
            Divider()
            HStack(spacing: 10) {
                if document.viewMode == .text {
                    Text("line \(position.line), column \(position.column), location \(position.location)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let error = document.error {
                    Text(error).font(.callout).foregroundStyle(.red).lineLimit(2)
                } else if !document.isEditable {
                    Label("Read-only", systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if document.viewMode == .tree {
                    Button("Raw") { document.viewMode = .text }
                        .help("Edit the JSON as text")
                } else if SyntaxHighlighter.language(of: document.text) == .json {
                    Button("Pretty") { document.formatJSON(pretty: true) }
                        .help("Indent the JSON (keys keep their order)")
                    Button("Minify") { document.formatJSON(pretty: false) }
                        .help("Remove all whitespace from the JSON")
                    Button("Tree") { document.viewMode = .tree }
                        .disabled(document.json == nil)
                        .help(document.json == nil ? "Not valid JSON" : "Browse the JSON as a tree")
                }
                if document.isEditable && document.viewMode == .text {
                    Button("Revert") { document.text = document.original }
                        .disabled(!document.hasChanges)
                    Button("Apply") { document.commitChanges() }
                        .disabled(!document.hasChanges)
                        .help("Stage this value (it's saved with the table's other changes)")
                }
                switch mode {
                case .popover(let openInWindow):
                    Button("Open in Window", action: openInWindow)
                case .window(let close):
                    Button("Close Window", action: close)
                        .keyboardShortcut("w")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct CursorPosition: Equatable {
    var line = 1
    var column = 1
    var location = 0
}

/// Editable/read-only NSTextView with a line-number gutter and syntax colouring (HTML/XML, JSON).
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    @Binding var position: CursorPosition

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: the gutter needs the layout manager's line fragments.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = CodeTextView.font
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        SyntaxHighlighter.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text  // e.g. Revert
            SyntaxHighlighter.highlight(textView)
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        weak var textView: NSTextView?

        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            SyntaxHighlighter.highlight(textView)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let location = textView.selectedRange().location
            let string = textView.string as NSString
            let prefix = string.substring(to: min(location, string.length))
            var line = 1
            var lineStart = 0
            for (offset, unit) in prefix.utf16.enumerated() where unit == 10 {  // \n
                line += 1
                lineStart = offset + 1
            }
            parent.position = CursorPosition(line: line, column: location - lineStart + 1, location: location)
        }
    }
}

/// Line numbers beside a TextKit 1 text view.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
            object: nil)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let string = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Number of the first visible line.
        var line = 1
        string.substring(to: characters.location).utf16.forEach { if $0 == 10 { line += 1 } }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let inset = textView.textContainerInset.height
        var index = characters.location
        while index <= NSMaxRange(characters) && index <= string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(index, max(0, string.length - 1)))
            var fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            if string.length == 0 { fragment = NSRect(x: 0, y: 0, width: 0, height: 16) }
            let y = fragment.minY + inset - visible.minY
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2),
                withAttributes: attributes)
            line += 1
            let next = NSMaxRange(lineRange)
            if next == index || next > string.length { break }
            if next == string.length {
                // A trailing newline starts one more (empty) line.
                if string.length > 0, string.character(at: string.length - 1) == 10 {
                    let extra = layoutManager.extraLineFragmentRect
                    if extra.height > 0 {
                        ("\(line)" as NSString).draw(
                            at: NSPoint(
                                x: ruleThickness - ("\(line)" as NSString).size(withAttributes: attributes).width - 8,
                                y: extra.minY + inset - visible.minY), withAttributes: attributes)
                    }
                }
                break
            }
            index = next
        }
    }
}

/// Regex-based colouring for markup and JSON (enough to read a value; not a full parser).
enum SyntaxHighlighter {
    enum Language { case markup, json, plain }

    /// Values above this size stay plain (highlighting multi-megabyte cells would stall typing).
    static let limit = 200_000

    static func language(of text: String) -> Language {
        let start = text.drop(while: \.isWhitespace).first
        switch start {
        case "<": return .markup
        case "{", "[": return .json
        default: return .plain
        }
    }

    @MainActor
    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: CodeTextView.font, .foregroundColor: NSColor.labelColor], range: full)
        if storage.length <= limit {
            switch language(of: text) {
            case .markup: markup(storage, text)
            case .json: json(storage, text)
            case .plain: break
            }
        }
        storage.endEditing()
    }

    private static func color(
        _ storage: NSTextStorage, _ pattern: String, _ color: NSColor, group: Int = 0, in text: String,
        range: NSRange? = nil
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return
        }
        let searchRange = range ?? NSRange(location: 0, length: (text as NSString).length)
        for match in regex.matches(in: text, range: searchRange) {
            let target = match.range(at: group)
            if target.location != NSNotFound { storage.addAttribute(.foregroundColor, value: color, range: target) }
        }
    }

    private static func markup(_ storage: NSTextStorage, _ text: String) {
        guard let tags = try? NSRegularExpression(pattern: "<[^<>]*>") else { return }
        for tag in tags.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            color(storage, "</?!?([A-Za-z][\\w:.-]*)", .systemBlue, group: 1, in: text, range: tag.range)
            color(storage, "\\s([A-Za-z_:][\\w:.-]*)\\s*=", .systemPurple, group: 1, in: text, range: tag.range)
            color(storage, "\"[^\"]*\"|'[^']*'", .systemRed, in: text, range: tag.range)
        }
        color(storage, "<!--.*?-->", .secondaryLabelColor, in: text)
    }

    private static func json(_ storage: NSTextStorage, _ text: String) {
        color(storage, "\\b(true|false|null)\\b|-?\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", .systemPurple, in: text)
        color(storage, "\"(?:\\\\.|[^\"\\\\])*\"", .systemRed, in: text)
        color(storage, "(\"(?:\\\\.|[^\"\\\\])*\")\\s*:", .systemBlue, group: 1, in: text)
    }
}

/// Keeps "Open in Window" windows alive until they close.
@MainActor
enum CellEditorWindows {
    private static var windows: [NSWindow] = []
    private static var closers: [ObjectIdentifier: WindowCloser] = [:]

    /// Stages the edit and releases the window when it closes.
    private final class WindowCloser: NSObject, NSWindowDelegate {
        let document: CellDocument
        init(document: CellDocument) { self.document = document }

        func windowWillClose(_ notification: Notification) {
            document.commitChanges()
            guard let window = notification.object as? NSWindow else { return }
            CellEditorWindows.windows.removeAll { $0 === window }
            CellEditorWindows.closers[ObjectIdentifier(window)] = nil
        }
    }

    static func open(_ document: CellDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = document.title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: CellEditorView(document: document, mode: .window(close: { [weak window] in window?.close() })))
        window.center()
        window.setFrameAutosaveName("CellEditorWindow")
        windows.append(window)
        let closer = WindowCloser(document: document)
        window.delegate = closer
        closers[ObjectIdentifier(window)] = closer
        window.makeKeyAndOrderFront(nil)
    }
}

#if DEBUG
    #Preview("Quick Look – HTML") {
        CellEditorView(
            document: CellDocument(
                title: "body — emails",
                text: "<!doctype html>\n<html>\n<head>\n    <meta name=\"viewport\" content=\"width=device-width\" />\n"
                    + "    <title>Simple Transactional Email</title>\n</head>\n<!-- comment -->\n<body>Hi</body>\n</html>",
                isEditable: true), mode: .popover(openInWindow: {})
        )
        .frame(width: 700, height: 400)
    }

    #Preview("Quick Look – JSON, read-only") {
        CellEditorView(
            document: CellDocument(
                title: "settings",
                text: "{\n  \"theme\": \"dark\",\n  \"size\": 13,\n  \"beta\": true,\n  \"tags\": null\n}",
                isEditable: false), mode: .window(close: {})
        )
        .frame(width: 600, height: 300)
    }
#endif
