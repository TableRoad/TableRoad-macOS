import AppKit
import SwiftUI
import TableRoadCore
import TableRoadDesign
import TableRoadSQL
import UniformTypeIdentifiers

/// One row, shown field by field in the inspector.
struct InspectorRow {
    var title: String
    var columns: [ResultColumn]
    var values: [CellValue]
    /// Schema detail per column, when known (nullability, ENUM choices, JSON type).
    var details: [ColumnDetail?]
    var states: [GridCellState]
}

/// Hooks for editing from the inspector; nil = read-only (e.g. query results).
struct InspectorEditing {
    var canEdit: (Int) -> Bool
    var set: (Int, CellEdit) -> Void
    var choices: (Int) -> [String]?
}

/// TablePlus-style right-hand panel: every field of the selected row at full size.
struct RowInspectorView: View {
    var row: InspectorRow?
    var editing: InspectorEditing?
    @State private var filter = ""

    var body: some View {
        if let row {
            VStack(spacing: 0) {
                HStack {
                    Text(row.title).font(.headline)
                    Spacer()
                    if editing == nil {
                        Label("Read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .top], 12)
                TextField("Filter fields", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(visibleColumns(row), id: \.self) { index in
                            FieldView(
                                column: row.columns[index], value: row.values[index], detail: row.details[index],
                                state: row.states[index],
                                canEdit: editing?.canEdit(index) ?? false,
                                choices: editing?.choices(index),
                                set: { editing?.set(index, $0) })
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            ContentUnavailableView(
                "No Row Selected", systemImage: "sidebar.right",
                description: Text("Select a row to see every field in full."))
        }
    }

    private func visibleColumns(_ row: InspectorRow) -> [Int] {
        row.columns.indices.filter { filter.isEmpty || row.columns[$0].name.localizedCaseInsensitiveContains(filter) }
    }
}

/// One field: header (name, type, state, NULL toggle) and a value editor suited to the type.
private struct FieldView: View {
    let column: ResultColumn
    let value: CellValue
    let detail: ColumnDetail?
    let state: GridCellState
    let canEdit: Bool
    let choices: [String]?
    let set: (CellEdit) -> Void

    @State private var jsonMode: JSONMode = .pretty
    private enum JSONMode { case pretty, raw }

    /// Values above this are shown truncated and read-only, so the inspector stays responsive.
    private static let editableLimit = 256 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
    }

    private var isNull: Bool { value == .null }
    private var isDefault: Bool { state == .insertedDefault }
    private var isNullable: Bool { detail?.isNullable ?? true }
    private var isJSON: Bool {
        if case .json = value { return true }
        return detail?.type.lowercased() == "json" || column.typeName == "JSON"
    }
    private var text: String { isDefault ? "" : (value.displayText ?? "") }

    private var header: some View {
        HStack(spacing: 6) {
            if state != .normal {
                Circle()
                    .fill(state == .deleted ? Color.red : state == .edited ? Brand.amber : .green)
                    .frame(width: 6, height: 6)
            }
            Text(column.name).font(.callout.weight(.semibold)).lineLimit(1)
            if detail?.isPrimaryKey == true {
                Image(systemName: "key.fill").font(.caption2).foregroundStyle(Brand.amber).help("Primary key")
            }
            Text(detail?.type ?? column.typeName.lowercased())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if canEdit && isNullable {
                Toggle(
                    "NULL",
                    isOn: Binding(
                        get: { isNull },
                        set: { set($0 ? .null : .text("")) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isDefault {
            placeholder("DEFAULT")
            if canEdit { textEditor }
        } else if isNull && !canEdit {
            placeholder("NULL")
        } else if case .bytes(let data) = value {
            BinaryFieldView(data: data, name: column.name)
        } else if let choices, canEdit {
            Picker(column.name, selection: Binding(get: { text }, set: { set(.text($0)) })) {
                if isNull { Text("NULL").tag("") }
                ForEach(choices, id: \.self) { Text($0.isEmpty ? "(empty)" : $0).tag($0) }
            }
            .labelsHidden()
        } else if isJSON {
            jsonField
        } else if isNull {
            placeholder("NULL")
        } else {
            textEditor
        }
        if let comment = detail?.comment {
            Text(comment).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).italic().foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var textEditor: some View {
        if text.utf8.count > Self.editableLimit {
            VStack(alignment: .leading, spacing: 4) {
                Text("Large value (\(ValueFormatting.byteCount(text.utf8.count))): showing the start, read-only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                readOnlyText(String(text.prefix(Self.editableLimit)))
            }
        } else if canEdit {
            TextField(
                "", text: Binding(get: { text }, set: { set(.text($0)) }), prompt: Text(isNull ? "NULL" : ""),
                axis: .vertical
            )
            .lineLimit(1...14)
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
        } else {
            readOnlyText(text)
        }
    }

    private func readOnlyText(_ text: String) -> some View {
        Text(text)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private var jsonField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("JSON view", selection: $jsonMode) {
                Text("Pretty").tag(JSONMode.pretty)
                Text(canEdit ? "Edit" : "Raw").tag(JSONMode.raw)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch jsonMode {
            case .pretty:
                if let pretty = ValueFormatting.prettyJSON(text) {
                    readOnlyText(pretty)
                } else {
                    readOnlyText(text)
                }
            case .raw:
                textEditor
            }
            if let error = ValueFormatting.jsonError(text), !text.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }
}

/// Binary values: size, image preview when the bytes are an image, hex dump, and Save to File.
private struct BinaryFieldView: View {
    let data: Data
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ValueFormatting.byteCount(data.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save to File…", action: save).controlSize(.small)
            }
            if let image = NSImage(data: data), image.isValid {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .background(.quaternary.opacity(0.4))
            }
            ScrollView(.horizontal) {
                Text(ValueFormatting.hexDump(data, limit: 1024))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

#if DEBUG
    #Preview("Inspector – editable") {
        RowInspectorView(
            row: PreviewData.inspectorRow,
            editing: InspectorEditing(
                canEdit: { _ in true }, set: { _, _ in },
                choices: { $0 == 4 ? ["draft", "published", "archived"] : nil })
        )
        .frame(width: 340, height: 900)
    }

    #Preview("Inspector – read-only") {
        RowInspectorView(row: PreviewData.inspectorRow, editing: nil)
            .frame(width: 340, height: 900)
    }

    #Preview("Inspector – no selection") {
        RowInspectorView(row: nil, editing: nil)
            .frame(width: 340, height: 400)
    }

    #Preview("Binary field") {
        BinaryFieldView(data: Data(base64Encoded: PreviewData.tinyPNG) ?? Data(), name: "avatar")
            .padding()
            .frame(width: 340)
    }
#endif
