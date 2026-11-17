import AppKit
import SwiftUI
import TableRoadCore

/// Columns of the table (read-only), TablePlus-style: name/primary key header, search, then a grid.
struct StructurePaneView: View {
    let model: TableBrowserModel
    @State private var search = ""

    var body: some View {
        StructureContainer(model: model) { structure in
            VStack(spacing: 0) {
                PaneHeader(table: model.table, search: $search, prompt: "Search for column…") {
                    if !structure.primaryKey.isEmpty {
                        Text("Primary").foregroundStyle(.secondary)
                        ForEach(structure.primaryKey, id: \.self) { name in
                            Text(name)
                                .font(.callout.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                Divider()
                let result = structure.columnsResult(database: model.database, matching: search)
                DataGridView(result: result, revision: AnyHashable(result))
            }
        }
    }
}

/// Indexes, then foreign keys (read-only).
struct IndexesPaneView: View {
    let model: TableBrowserModel
    @State private var search = ""

    var body: some View {
        StructureContainer(model: model) { structure in
            VStack(spacing: 0) {
                PaneHeader(table: model.table, search: $search, prompt: "Search for index…") { EmptyView() }
                Divider()
                let indexes = structure.indexesResult(matching: search)
                DataGridView(result: indexes, revision: AnyHashable(indexes))
                if !structure.foreignKeys.isEmpty {
                    Divider()
                    Text("Foreign Keys")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.bar)
                    Divider()
                    let keys = structure.foreignKeysResult(database: model.database)
                    DataGridView(result: keys, revision: AnyHashable(keys))
                        .frame(height: min(CGFloat(keys.rows.count) * 24 + 40, 200))
                }
            }
        }
    }
}

/// The CREATE statement, selectable, with Copy.
struct DDLPaneView: View {
    let model: TableBrowserModel

    var body: some View {
        StructureContainer(model: model) { structure in
            ScrollView([.vertical, .horizontal]) {
                Text(structure.ddl)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(structure.ddl, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .padding(10)
                .help("Copy the CREATE statement")
            }
        }
    }
}

/// Loading / error / loaded states shared by the definition panes.
private struct StructureContainer<Content: View>: View {
    let model: TableBrowserModel
    @ViewBuilder var content: (TableStructure) -> Content

    var body: some View {
        if let structure = model.structure {
            content(structure)
        } else if let error = model.structureError {
            ContentUnavailableView {
                Label("Couldn't Load the Structure", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await model.loadStructure() } }
            }
        } else {
            ProgressView("Loading structure…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await model.loadStructure() }
        }
    }
}

/// "Name [table]   …extras…   [search]".
private struct PaneHeader<Extras: View>: View {
    let table: String
    @Binding var search: String
    let prompt: String
    @ViewBuilder var extras: Extras

    var body: some View {
        HStack(spacing: 8) {
            Text("Name").foregroundStyle(.secondary)
            Text(table)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            extras
            Spacer()
            TextField(prompt, text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Inspector content when no row is selected: sizes, estimate, engine and comment.
struct TableDetailsView: View {
    let model: TableBrowserModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.table).font(.headline)
                if let status = model.status {
                    field("Data size", status.dataBytes.map(ValueFormatting.byteCount))
                    field("Index size", status.indexBytes.map(ValueFormatting.byteCount))
                    field("Total size", status.totalBytes.map(ValueFormatting.byteCount))
                    field("Free space", status.freeBytes.map(ValueFormatting.byteCount))
                    field("Rows (estimate)", status.estimatedRows.map { "~" + $0.formatted() })
                    field("Auto increment", status.autoIncrement.map { $0.formatted(.number.grouping(.never)) })
                    field("Engine", status.engine)
                    field("Collation", status.collation)
                    field("Created", status.createdAt)
                    field("Updated", status.updatedAt)
                    field("Comment", status.comment)
                    Text("Sizes and row counts are the storage engine's estimates.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Table details aren't available.").foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "EMPTY")
                .font(.callout.monospaced())
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(value == nil ? 1 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
        }
    }
}

#if DEBUG
    #Preview("Table details") {
        TableDetailsView(model: .preview())
            .frame(width: 320, height: 600)
    }

    #Preview("Structure pane") {
        StructurePaneView(model: .preview(pane: .structure))
            .frame(width: 1000, height: 300)
    }

    #Preview("Indexes pane") {
        IndexesPaneView(model: .preview(pane: .indexes))
            .frame(width: 900, height: 360)
    }

    #Preview("DDL pane") {
        DDLPaneView(model: .preview(pane: .ddl))
            .frame(width: 800, height: 320)
    }
#endif
