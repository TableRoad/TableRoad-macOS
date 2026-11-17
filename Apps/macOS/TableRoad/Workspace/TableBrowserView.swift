import SwiftUI
import TableRoadCore
import TableRoadDesign

struct TableBrowserView: View {
    @Bindable var model: TableBrowserModel
    /// Opens the window's row inspector (for values that can't be edited inline).
    var showInspector: () -> Void = {}
    /// Opens the row a foreign key value refers to (in a new tab). Nil hides the → links.
    var onFollowForeignKey: ((ForeignKeyTarget) -> Void)? = nil
    @State private var showingPreview = false
    @State private var confirmingCommit = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.pane {
            case .data: dataPane
            case .structure: StructurePaneView(model: model)
            case .indexes: IndexesPaneView(model: model)
            case .ddl: DDLPaneView(model: model)
            }
            Divider()
            if model.hasChanges {
                pendingBar
                Divider()
            }
            footer
        }
        .sheet(isPresented: $showingPreview) {
            SQLPreviewSheet(sql: model.previewSQL) {
                showingPreview = false
                requestCommit()
            }
        }
        .confirmationDialog(
            "Commit \(model.pending.changedRowCount) change(s) to \(model.table)?", isPresented: $confirmingCommit,
            titleVisibility: .visible
        ) {
            Button("Commit") { Task { await model.commit() } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                model.confirmBeforeCommit
                    ? "This connection is marked as production or uses safe mode."
                    : "The changes are written in one transaction.")
        }
    }

    @ViewBuilder
    private var dataPane: some View {
        VStack(spacing: 0) {
            if model.isFilterBarVisible {
                FilterBarView(model: model)
                Divider()
            }
            if let error = model.error {
                ErrorBanner(message: error)
            }
            if let error = model.commitError {
                ErrorBanner(message: error)
            }
            DataGridView(
                result: model.displayResult, sort: model.sort, sortable: true, onSort: { model.setSort($0) },
                rowNumberOffset: model.page * model.pageSize, editing: model.isEditable ? editing : nil,
                revision: model.gridRevision, onSelectionChange: { model.selectedRows = $0 },
                tableName: model.table, dialect: model.dialect, onRefresh: { model.refresh() },
                onQuickFilter: { model.quickFilter($0) }, onInspect: showInspector,
                foreignKeyColumns: model.foreignKeyColumns,
                onFollowForeignKey: onFollowForeignKey.map { follow in
                    { row, column in
                        if let target = model.foreignKeyTarget(row: row, column: column) { follow(target) }
                    }
                }
            )
            .overlay {
                if model.isLoading, let started = model.loadStartedAt {
                    LoadingOverlay(started: started, onCancel: model.cancelLoad)
                }
            }
        }
    }

    private var editing: GridEditing {
        GridEditing(
            cellState: { model.cellState(row: $0, column: $1) },
            editableText: { model.editableText(row: $0, column: $1) },
            setCell: { model.setCell(row: $0, column: $1, to: $2) },
            deleteRows: { model.deleteRows($0) },
            duplicateRow: { model.duplicateRow($0) },
            addRow: { model.addRow() },
            isInsertedRow: { $0 >= model.pageRowCount },
            choices: { model.choices(column: $0) },
            editRequest: model.editRequest,
            showInspector: showInspector,
            canEditInEditor: { model.canEditInEditor(row: $0, column: $1) }
        )
    }

    private func requestCommit() {
        if model.confirmBeforeCommit {
            confirmingCommit = true
        } else {
            Task { await model.commit() }
        }
    }

    private var pendingBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle.fill").foregroundStyle(Brand.amber)
            Text("\(model.pending.changedRowCount) row(s) changed")
            if model.isCommitting { ProgressView().controlSize(.small) }
            Spacer()
            Button("Discard", role: .destructive) { model.discardChanges() }
            Button("Preview SQL…") { showingPreview = true }
            Button("Commit") { requestCommit() }
                .keyboardShortcut("s")
                .help("Commit (⌘S), or ⌘↩ to confirm first")
                // ⌘↩ always asks first (it's easy to press by accident).
                .background {
                    Button("") { confirmingCommit = true }
                        .keyboardShortcut(.return, modifiers: .command)
                        .hidden()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCommitting)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Brand.amber.opacity(0.08))
    }

    /// Left: pane switcher and actions. Centre: row count (click for exact counting). Right: paging.
    private var footer: some View {
        FooterLayout {
            HStack(spacing: 10) {
                Picker("View", selection: Binding(get: { model.pane }, set: { model.show($0) })) {
                    ForEach(TableBrowserModel.Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Data, structure, indexes or CREATE statement (⌘1–⌘4)")
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload (⌘R)")
                .keyboardShortcut("r")
                if model.pane == .data { dataActions }
            }
            .fixedSize()

            if model.pane == .data {
                RowCountButton(model: model)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }

            HStack(spacing: 10) {
                if model.pane == .data { pager }
            }
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            // ⌘1…⌘4 switch panes, like TablePlus.
            Group {
                ForEach(Array(TableBrowserModel.Pane.allCases.enumerated()), id: \.offset) { offset, pane in
                    Button("") { model.show(pane) }
                        .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: [.command])
                }
            }
            .hidden()
        }
    }

    @ViewBuilder
    private var dataActions: some View {
        Button {
            model.toggleFilterBar()
        } label: {
            Label(
                model.appliedFilters.activeCount > 0 ? "Filters (\(model.appliedFilters.activeCount))" : "Filters",
                systemImage: model.appliedFilters.activeCount > 0
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .keyboardShortcut("f")
        .help("Show or hide filters (⌘F)")
        if model.isEditable {
            Button {
                model.addRow()
            } label: {
                Label("Row", systemImage: "plus")
            }
            .keyboardShortcut("i")
            .help("Add a row (⌘I)")
        } else if let reason = model.readOnlyReason {
            Label("Read-only", systemImage: "lock")
                .foregroundStyle(.secondary)
                .help(reason)
        }
    }

    @ViewBuilder
    private var pager: some View {
        Button {
            model.go(toPage: model.page - 1)
        } label: {
            Image(systemName: "chevron.left")
        }
        .disabled(model.page == 0)
        .help("Previous page")
        Text("Page \(model.page + 1) of \(model.totalIsEstimate ? "~" : "")\(model.pageCount.formatted())")
            .monospacedDigit()
        Button {
            model.go(toPage: model.page + 1)
        } label: {
            Image(systemName: "chevron.right")
        }
        .disabled(model.page + 1 >= model.pageCount)
        .help("Next page")
    }
}

/// Three children: leading, centre, trailing. The centre one is centred in the bar when it fits between the others,
/// otherwise it sits just after the leading one (so nothing overlaps or wraps).
struct FooterLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? (sizes.map(\.width).reduce(0, +) + spacing * 2)
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let (leading, centre, trailing) = (sizes[0], sizes[1], sizes[2])
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        let minX = bounds.minX + leading.width + spacing
        let available = bounds.maxX - trailing.width - spacing - minX
        if centre.width > available {
            // Not enough room: squeeze it into the gap (the text truncates) rather than overlap the pager.
            subviews[1].place(
                at: CGPoint(x: minX, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: max(0, available), height: nil))
            return
        }
        let centred = bounds.midX - centre.width / 2
        let x = min(max(centred, minX), minX + available - centre.width)
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}

/// "1–300 of ~226,374,516 rows". Click for the exact count (TablePlus-style popover).
struct RowCountButton: View {
    let model: TableBrowserModel
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                if model.isCounting || model.isLoading { ProgressView().controlSize(.mini) }
                Text(model.rowRangeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(model.totalIsEstimate ? "Estimated by the storage engine. Click to count exactly." : "Row count")
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            RowCountPopover(model: model)
        }
    }
}

struct RowCountPopover: View {
    let model: TableBrowserModel
    @State private var includeFilters = true

    var body: some View {
        VStack(spacing: 10) {
            Text(model.rowRangeText).monospacedDigit()
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(model.totalIsEstimate || model.totalRows == nil ? Color.orange : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.appliedFilters.activeCount > 0 {
                Toggle("Include current filter conditions", isOn: $includeFilters)
                    .toggleStyle(.checkbox)
                    .disabled(model.isCounting)
            }
            if let unfiltered = model.unfilteredCount {
                Text("Whole table: \(unfiltered.formatted()) rows").font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.countError {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if model.isCounting, let started = model.countStartedAt {
                HStack {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: started, by: 0.1)) { context in
                        Text(
                            "Counting… \(context.date.timeIntervalSince(started), format: .number.precision(.fractionLength(1)))s"
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    Button("Cancel") { model.cancelCount() }
                }
            } else {
                Button(model.totalRows != nil && !model.totalIsEstimate ? "Count Again" : "Count") {
                    model.count(includeFilters: includeFilters)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isLoading)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var note: String? {
        if model.totalIsEstimate {
            return "This is the storage engine's estimate. Count gets the exact number, but on a large table it "
                + "can take a while and load the server."
        }
        if model.totalRows == nil && !model.isCounting {
            return "Large tables aren't counted automatically. Count runs SELECT COUNT(*), which can take a while "
                + "and load the server."
        }
        return nil
    }
}

extension TableBrowserModel {
    /// "1–300 of ~226,374,516 rows", "1–300 of 10,000 rows", or "1–300 of ? rows" when not counted.
    var rowRangeText: String {
        let rows = result.rows.count
        guard rows > 0 else { return totalRows == 0 || page == 0 ? "No rows" : "No rows on this page" }
        let first = page * pageSize + 1
        let last = page * pageSize + rows
        let total: String =
            if let totalRows { (totalIsEstimate ? "~" : "") + totalRows.formatted() } else if isCounting { "…" } else {
                "?"
            }
        return "\(first.formatted())–\(last.formatted()) of \(total) rows"
    }
}

/// Shown over the grid while a page loads. Appears only after a short delay so fast loads don't flicker,
/// then shows elapsed time and a Cancel that kills the query on the server.
struct LoadingOverlay: View {
    let started: Date
    var onCancel: () -> Void
    @State private var isVisible = false

    var body: some View {
        ZStack {
            if isVisible {
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
                VStack(spacing: 10) {
                    ProgressView()
                    TimelineView(.periodic(from: started, by: 0.1)) { context in
                        Text(
                            "Loading… \(context.date.timeIntervalSince(started), format: .number.precision(.fractionLength(1)))s"
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(".")
                        .help("Stop the query on the server (⌘.)")
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.15)) { isVisible = true }
        }
    }
}

struct SQLPreviewSheet: View {
    let sql: String
    var onCommit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pending Changes").font(.headline)
            Text("Runs in one transaction; if any statement fails, nothing is saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(sql)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minWidth: 560, minHeight: 200, maxHeight: 400)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy SQL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Commit", action: onCommit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.red.opacity(0.08))
    }
}

#if DEBUG
    #Preview("Table – estimated count") {
        TableBrowserView(model: .preview(estimated: true))
            .frame(width: 900, height: 600)
    }

    #Preview("Row count popover – estimate") {
        RowCountPopover(model: .preview(estimated: true))
    }

    #Preview("Row count popover – filtered, not counted") {
        RowCountPopover(model: .preview(withFilters: true, estimated: true))
    }

    #Preview("Table – structure") {
        TableBrowserView(model: .preview(pane: .structure))
            .frame(width: 1000, height: 500)
    }

    #Preview("Table – indexes") {
        TableBrowserView(model: .preview(pane: .indexes))
            .frame(width: 900, height: 500)
    }

    #Preview("Table – DDL") {
        TableBrowserView(model: .preview(pane: .ddl))
            .frame(width: 900, height: 500)
    }

    #Preview("Table – browsing") {
        TableBrowserView(model: .preview())
            .frame(width: 900, height: 600)
    }

    #Preview("Table – filters and staged edits") {
        TableBrowserView(model: .preview(withFilters: true, withEdits: true))
            .frame(width: 900, height: 600)
    }

    #Preview("Table – read-only") {
        TableBrowserView(model: .preview(safeMode: .readOnly))
            .frame(width: 900, height: 600)
    }

    #Preview("Preview SQL sheet") {
        SQLPreviewSheet(sql: TableBrowserModel.preview(withEdits: true).previewSQL) {}
    }

    #Preview("Loading overlay") {
        LoadingOverlay(started: .now.addingTimeInterval(-2.4), onCancel: {})
            .frame(width: 500, height: 300)
    }

    #Preview("Error banner") {
        ErrorBanner(
            message: "Change 1 failed, so nothing was saved: Data truncated for column 'status' at row 1 (1265)"
        )
        .frame(width: 700)
    }
#endif
