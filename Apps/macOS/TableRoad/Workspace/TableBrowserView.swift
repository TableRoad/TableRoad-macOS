import SwiftUI
import TableRoadCore
import TableRoadDesign

struct TableBrowserView: View {
    @Bindable var model: TableBrowserModel
    /// Opens the window's row inspector (for values that can't be edited inline).
    var showInspector: () -> Void = {}
    @State private var showingPreview = false
    @State private var confirmingCommit = false

    var body: some View {
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
                revision: model.pending.hashValue, onSelectionChange: { model.selectedRows = $0 }
            )
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
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This connection is marked as production or uses safe mode.")
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
            showInspector: showInspector
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
                .buttonStyle(.borderedProminent)
                .disabled(model.isCommitting)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Brand.amber.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload (⌘R)")
            .keyboardShortcut("r")
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
            if model.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Text(rangeText).foregroundStyle(.secondary).monospacedDigit()
            Button {
                model.go(toPage: model.page - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.page == 0)
            Text("Page \(model.page + 1) of \(model.pageCount)").monospacedDigit()
            Button {
                model.go(toPage: model.page + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.page + 1 >= model.pageCount)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var rangeText: String {
        let first = model.page * model.pageSize + (model.result.rows.isEmpty ? 0 : 1)
        let last = model.page * model.pageSize + model.result.rows.count
        let total = model.totalRows.map { " of \($0.formatted())" } ?? ""
        return "Rows \(first.formatted())–\(last.formatted())\(total)"
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
