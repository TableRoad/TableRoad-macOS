import SwiftUI
import TableRoadSQL

/// TablePlus-style filter rows above the grid: [✓] [column] [operator] [value] [−][+].
struct FilterBarView: View {
    @Bindable var model: TableBrowserModel
    @FocusState private var focusedFilter: ColumnFilter.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A Grid keeps each pop-up at its natural width (no dead space around it) while still lining the
            // columns up across rows; every control uses the same (regular) size so heights match.
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach($model.filters.filters) { $filter in
                    row($filter)
                }
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
        GridRow {
            Toggle("Enabled", isOn: filter.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .onChange(of: filter.wrappedValue.isEnabled) { model.applyFilters() }

            if filter.wrappedValue.op != .rawSQL {
                Picker("Column", selection: filter.column) {
                    ForEach(model.columnNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Color.clear.frame(width: 0, height: 0)  // raw SQL has no column
            }

            Picker("Operator", selection: filter.op) {
                ForEach(ColumnFilter.Operator.allCases) { op in
                    Text(op.rawValue).tag(op)
                    if op == .greaterThanOrEqual || op == .notIn || op == .isEmpty { Divider() }
                }
            }
            .labelsHidden()
            .fixedSize()

            // Value and −/+ share one stack sized to the text field's height (`fixedSize` vertically), so the
            // buttons, which stretch vertically, end up exactly as tall as the field.
            HStack(spacing: 6) {
                Group {
                    if filter.wrappedValue.op.needsValue {
                        TextField(placeholder(filter.wrappedValue.op), text: filter.value)
                            .textFieldStyle(.roundedBorder)
                            .font(filter.wrappedValue.op == .rawSQL ? .body.monospaced() : .body)
                            .focused($focusedFilter, equals: filter.wrappedValue.id)
                            .onSubmit { model.applyFilters() }
                    } else {
                        // Operators like IS NULL take no value; an invisible field keeps the row height.
                        TextField("", text: .constant("")).textFieldStyle(.roundedBorder).hidden()
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Button {
                        model.removeFilter(filter.wrappedValue.id)
                    } label: {
                        Image(systemName: "minus").frame(width: 12, height: 12)
                    }
                    .help("Remove filter")
                    Button {
                        model.addFilter(after: filter.wrappedValue.id)
                    } label: {
                        Image(systemName: "plus").frame(width: 12, height: 12)
                    }
                    .help("Add filter")
                }
                // Standard bordered buttons have a fixed height per control size, so they can't match the field.
                .buttonStyle(RowIconButtonStyle())
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func placeholder(_ op: ColumnFilter.Operator) -> String {
        switch op {
        case .isIn, .notIn: "a, b, c"
        case .rawSQL: "SQL condition, e.g. total > 100 AND status <> 'paid'"
        default: "Value"
        }
    }
}

/// Square-ish icon button that stretches to its row's height, styled like a bordered macOS button.
private struct RowIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(width: 26)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.16) : Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

#if DEBUG
    #Preview("Filter bar") {
        FilterBarView(model: .preview(withFilters: true))
            .frame(width: 800)
    }
#endif
