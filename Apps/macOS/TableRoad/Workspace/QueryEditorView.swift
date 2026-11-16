import SwiftUI
import TableRoadCore
import TableRoadSQL

/// Phase 1 editor: plain monospaced text. Highlighting and autocomplete arrive with the TextKit 2 editor (Phase 6).
struct QueryEditorView: View {
    @Bindable var model: QueryEditorModel
    /// Editor pane height; the results get the rest. Dragged via the divider.
    @State private var editorHeight: CGFloat = 200
    @State private var dragStartHeight: CGFloat?
    /// UTF-16 selection from the editor; empty = caret.
    @State private var selection: Range<Int> = 0..<0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                editorPane
                    .frame(height: min(max(editorHeight, 90), geometry.size.height - 120))
                divider(maxHeight: geometry.size.height - 120)
                resultsPane
            }
        }
    }

    private func divider(maxHeight: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? editorHeight
                        dragStartHeight = start
                        editorHeight = min(max(start + value.translation.height, 90), maxHeight)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            SQLTextView(text: $model.text, selection: $selection)
            toolbar
        }
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            if let result = model.result {
                DataGridView(result: result)
            } else {
                ContentUnavailableView(
                    "No Results", systemImage: "play",
                    description: Text(
                        "⌘↩ runs the highlighted SQL or the statement under the cursor; ⇧⌘↩ runs everything."))
            }
            if !model.messages.isEmpty {
                Divider()
                messages
            }
        }
    }

    private var toolbar: some View {
        HStack {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel") { Task { await model.cancel() } }
                    .keyboardShortcut(".")
            }
            Spacer()
            Button("Run All") { Task { await model.run() } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Run the whole script (⇧⌘↩)")
                .disabled(model.isRunning || isEmpty)
            Button {
                if let script = scriptToRun { Task { await model.run(script) } }
            } label: {
                Label(hasSelection ? "Run Selection" : "Run Current", systemImage: "play.fill")
            }
            .keyboardShortcut(.return)
            .help(hasSelection ? "Run the highlighted SQL (⌘↩)" : "Run the statement under the cursor (⌘↩)")
            .disabled(model.isRunning || scriptToRun == nil)
        }
        .padding(8)
        .background(.bar)
    }

    private var isEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSelection: Bool {
        !selection.isEmpty
    }

    private var scriptToRun: String? {
        StatementSplitter(syntax: .mysql).scriptToRun(in: model.text, selection: selection)
    }

    private var messages: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.messages) { message in
                    Text(message.text)
                        .foregroundStyle(message.isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 80)
    }
}
