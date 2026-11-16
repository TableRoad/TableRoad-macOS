import SwiftUI
import TableRoadCore

struct TableBrowserView: View {
    @Bindable var model: TableBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                ErrorBanner(message: error)
            }
            DataGridView(
                result: model.result, sort: model.sort, sortable: true, onSort: { model.setSort($0) },
                rowNumberOffset: model.page * model.pageSize)
            Divider()
            footer
        }
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
