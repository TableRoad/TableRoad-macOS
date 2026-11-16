import SwiftUI
import TableRoadSQL

/// TablePlus-style filter rows above the grid: [✓] [column] [operator] [value] [−][+].
struct FilterBarView: View {
    @Bindable var model: TableBrowserModel
    @FocusState private var focusedFilter: ColumnFilter.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($model.filters.filters) { $filter in
                row($filter)
            }
            HStack(spacing: 8) {
                if model.filters.filters.count > 1 {
                    Picker("Match", selection: $model.filters.matchAll) {
                        Text("Match all").tag(true)
                        Text("Match any").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if !model.appliedWhereSQL.isEmpty {
                    Text(model.appliedWhereSQL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(model.appliedWhereSQL)
                }
                Spacer()
                Button("Clear") {
                    model.filters.filters.removeAll()
                    model.isFilterBarVisible = false
                    model.applyFilters()
                }
                // No plain-Return shortcut here: it would steal Return from the grid. Value fields apply on submit.
                Button("Apply") { model.applyFilters() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(.bar)
        .onAppear { focusedFilter = model.filters.filters.last?.id }
    }

    private func row(_ filter: Binding<ColumnFilter>) -> some View {
        HStack(spacing: 6) {
            Toggle("Enabled", isOn: filter.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .onChange(of: filter.wrappedValue.isEnabled) { model.applyFilters() }

            if filter.wrappedValue.op != .rawSQL {
                Picker("Column", selection: filter.column) {
                    ForEach(model.columnNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            Picker("Operator", selection: filter.op) {
                ForEach(ColumnFilter.Operator.allCases) { op in
                    Text(op.rawValue).tag(op)
                    if op == .greaterThanOrEqual || op == .notIn || op == .isEmpty { Divider() }
                }
            }
            .labelsHidden()
            .frame(width: 140)

            if filter.wrappedValue.op.needsValue {
                TextField(placeholder(filter.wrappedValue.op), text: filter.value)
                    .textFieldStyle(.roundedBorder)
                    .font(filter.wrappedValue.op == .rawSQL ? .body.monospaced() : .body)
                    .focused($focusedFilter, equals: filter.wrappedValue.id)
                    .onSubmit { model.applyFilters() }
            } else {
                Spacer()
            }

            Button {
                model.removeFilter(filter.wrappedValue.id)
            } label: {
                Image(systemName: "minus")
            }
            .help("Remove filter")
            Button {
                model.addFilter(after: filter.wrappedValue.id)
            } label: {
                Image(systemName: "plus")
            }
            .help("Add filter")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func placeholder(_ op: ColumnFilter.Operator) -> String {
        switch op {
        case .isIn, .notIn: "a, b, c"
        case .rawSQL: "SQL condition, e.g. total > 100 AND status <> 'paid'"
        default: "Value"
        }
    }
}
