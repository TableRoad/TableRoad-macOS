import SwiftUI
import TableRoadCore
import TableRoadSQL

/// Phase 1 editor: plain monospaced text. Highlighting and autocomplete arrive with the TextKit 2 editor (Phase 6).
struct QueryEditorView: View {
    @Bindable var model: QueryEditorModel
    /// Opens the Save Query sheet (the window owns the saved-query store).
    var onSaveQuery: () -> Void = {}
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

    @ViewBuilder
    private var resultsPane: some View {
        if model.statements.isEmpty && model.notes.isEmpty {
            ContentUnavailableView(
                "No Results", systemImage: "play",
                description: Text(
                    "⌘↩ runs the highlighted SQL or the statement under the cursor; ⇧⌘↩ runs everything."))
        } else {
            VStack(spacing: 0) {
                ResultTabStrip(model: model)
                Divider()
                switch model.selectedTab {
                case .messages:
                    MessagesView(model: model)
                case .statement:
                    if let statement = model.selectedStatement {
                        switch statement.outcome {
                        case .rows(let rows):
                            DataGridView(
                                result: rows, revision: AnyHashable(statement.id),
                                onSelectionChange: { model.selectedRows = $0 }
                            )
                            .id(statement.id)
                        case .failed(let message):
                            StatementErrorView(statement: statement, message: message)
                        case .rowsNotKept, .affected:
                            MessagesView(model: model)
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack {
            if model.isRunning, let started = model.runStartedAt {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: started, by: 0.1)) { context in
                    Text(
                        "Running… \(context.date.timeIntervalSince(started), format: .number.precision(.fractionLength(1)))s"
                    )
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                Button("Cancel") { Task { await model.cancel() } }
                    .keyboardShortcut(".")
                    .help("Stop the running query and the rest of the script (⌘.)")
            } else if model.isConnected {
                Label("Own connection", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    .help("This tab runs on its own connection, so long queries don't block browsing or other tabs.")
            }
            Spacer()
            Button {
                onSaveQuery()
            } label: {
                Label(model.savedQueryID == nil ? "Save Query…" : "Update Saved Query…", systemImage: "star")
            }
            .disabled(isEmpty)
            .help("Keep this SQL in the sidebar's Queries list")
            // One split button: click runs the selection (or the statement under the cursor); the arrow offers Run All.
            Menu {
                Button("Run All", action: runAll)
                    .disabled(isEmpty)
            } label: {
                Label(hasSelection ? "Run Selection" : "Run Current", systemImage: "play.fill")
            } primaryAction: {
                runCurrent()
            }
            .menuStyle(.button)
            .fixedSize()
            .help(
                hasSelection
                    ? "Run the highlighted SQL (⌘↩). Use the arrow for Run All (⇧⌘↩)."
                    : "Run the statement under the cursor (⌘↩). Use the arrow for Run All (⇧⌘↩)."
            )
            .disabled(model.isRunning || isEmpty)
        }
        .background {
            // Key equivalents for the split button (menu items inside a pull-down don't register them).
            Group {
                Button("", action: runCurrent).keyboardShortcut(.return)
                Button("", action: runAll).keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            .disabled(model.isRunning)
            .hidden()
        }
        .padding(8)
        .background(.bar)
    }

    private func runCurrent() {
        if let script = scriptToRun { Task { await model.run(script) } }
    }

    private func runAll() {
        guard !isEmpty else { return }
        Task { await model.run() }
    }

    private var isEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSelection: Bool {
        !selection.isEmpty
    }

    private var scriptToRun: String? {
        StatementSplitter(syntax: model.syntax).scriptToRun(in: model.text, selection: selection)
    }
}

/// One tab per row result / error, plus Messages.
private struct ResultTabStrip: View {
    @Bindable var model: QueryEditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(model.resultTabs) { statement in
                    tab(
                        .statement(statement.id),
                        title: "Result \(statement.number)",
                        detail: statement.isFailure ? "Error" : statement.summary,
                        systemImage: statement.isFailure ? "exclamationmark.triangle.fill" : "tablecells",
                        tint: statement.isFailure ? .red : nil)
                }
                tab(
                    .messages, title: "Messages", detail: "\(model.statements.count)",
                    systemImage: "text.alignleft", tint: model.notes.contains(where: \.isError) ? .red : nil)
            }
        }
        .frame(height: 28)
        .background(.bar)
    }

    private func tab(
        _ tab: QueryEditorModel.ResultTab, title: String, detail: String, systemImage: String, tint: Color?
    ) -> some View {
        let selected = model.selectedTab == tab
        return HStack(spacing: 5) {
            Image(systemName: systemImage).font(.caption).foregroundStyle(tint ?? .secondary)
            Text(title).font(.callout)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .overlay(alignment: .bottom) {
            if selected { Color.accentColor.frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .help(tabHelp(tab))
    }

    private func tabHelp(_ tab: QueryEditorModel.ResultTab) -> String {
        guard case .statement(let id) = tab, let statement = model.statements.first(where: { $0.id == id }) else {
            return "Every statement in the last run"
        }
        return statement.sql
    }
}

/// Every statement in the run: status, SQL, outcome and time. Click one with a tab to open it.
private struct MessagesView: View {
    @Bindable var model: QueryEditorModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.statements) { statement in
                    row(statement)
                    Divider()
                }
                ForEach(model.notes) { note in
                    Label(note.text, systemImage: note.isError ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(note.isError ? .red : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
            }
            .font(.callout)
        }
    }

    private func row(_ statement: QueryEditorModel.StatementResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statement.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(statement.isFailure ? .red : .green)
            Text("\(statement.number)").monospacedDigit().foregroundStyle(.secondary).frame(
                width: 24, alignment: .trailing)
            Text(statement.sql.replacingOccurrences(of: "\n", with: " "))
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(statement.summary)
                .foregroundStyle(statement.isFailure ? .red : .secondary)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .trailing)
            Text(statement.elapsedText).monospacedDigit().foregroundStyle(.tertiary).frame(
                width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if statement.hasTab { model.select(.statement(statement.id)) } }
        .textSelection(.enabled)
    }
}

/// The error for a failed statement, with the SQL that caused it.
private struct StatementErrorView: View {
    let statement: QueryEditorModel.StatementResult
    let message: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Statement \(statement.number) failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message).textSelection(.enabled)
                Text(statement.sql)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
    #Preview("Query – results") {
        QueryEditorView(model: .preview(.results))
            .frame(width: 900, height: 650)
    }

    #Preview("Query – error") {
        QueryEditorView(model: .preview(.failed))
            .frame(width: 900, height: 650)
    }

    #Preview("Query – running") {
        QueryEditorView(model: .preview(.running))
            .frame(width: 900, height: 650)
    }

    #Preview("Query – empty") {
        QueryEditorView(model: .preview(.empty))
            .frame(width: 900, height: 650)
    }

    #Preview("Result tabs") {
        ResultTabStrip(model: .preview(.failed))
            .frame(width: 700)
    }

    #Preview("Messages") {
        MessagesView(model: .preview(.failed))
            .frame(width: 800, height: 240)
    }

    #Preview("Statement error") {
        let model = QueryEditorModel.preview(.failed)
        let failed = model.statements.last!
        return StatementErrorView(statement: failed, message: "Table 'shop.no_such_table' doesn't exist (1146)")
            .frame(width: 700, height: 240)
    }
#endif
