import SwiftUI
import TableRoadCore

/// Node in the JSON outline (paths make stable ids).
struct JSONNode: Identifiable, Hashable {
    let id: String
    let label: String
    let value: JSONValue
    let children: [JSONNode]?

    init(label: String, value: JSONValue, path: String) {
        self.id = path
        self.label = label
        self.value = value
        self.children = value.children?.enumerated().map { offset, child in
            JSONNode(label: child.label, value: child.value, path: path + "/" + String(offset))
        }
    }
}

/// TablePlus-style JSON preview: outline on the left, the selected node's fields on the right (read-only).
struct JSONTreeView: View {
    let root: JSONNode
    @State private var selection: JSONNode.ID?
    /// Open nodes: ROOT and its direct child objects/arrays start expanded, like TablePlus.
    @State private var expanded: Set<JSONNode.ID> = []

    init(value: JSONValue) {
        root = JSONNode(label: "ROOT", value: value, path: "")
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                JSONOutline(node: root, expanded: $expanded)
            }
            .frame(minWidth: 220, idealWidth: 320)
            fields
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            expanded = Set([root.id]).union((root.children ?? []).filter { $0.children != nil }.map(\.id))
            selection = root.children?.first(where: { $0.children != nil })?.id ?? root.id
        }
    }

    private var selectedNode: JSONNode {
        guard let selection else { return root }
        return Self.find(selection, in: root) ?? root
    }

    private static func find(_ id: String, in node: JSONNode) -> JSONNode? {
        if node.id == id { return node }
        for child in node.children ?? [] {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }

    private var fields: some View {
        let node = selectedNode
        let items = node.children ?? [node]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(item.value.typeName).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        let text = Self.fieldText(item.value)
                        Text(text ?? "EMPTY")
                            .font(.callout.monospaced())
                            .foregroundStyle(text == nil ? .tertiary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                    }
                }
            }
            .padding(12)
        }
    }

    /// Value shown in a field box; nil shows a grey EMPTY (null or empty string).
    static func fieldText(_ value: JSONValue) -> String? {
        switch value {
        case .null: nil
        case .string(let text): text.isEmpty ? nil : text
        case .object, .array: value.minified
        default: value.scalarText
        }
    }
}

/// Recursive disclosure rows (List's built-in outline can't start expanded).
private struct JSONOutline: View {
    let node: JSONNode
    @Binding var expanded: Set<JSONNode.ID>

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(node.id) },
                    set: { open in
                        if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                    })
            ) {
                ForEach(children) { JSONOutline(node: $0, expanded: $expanded) }
            } label: {
                JSONNodeRow(node: node)
            }
            .tag(node.id)
        } else {
            JSONNodeRow(node: node).tag(node.id)
        }
    }
}

private struct JSONNodeRow: View {
    let node: JSONNode

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 18)
            Text(node.label)
            if node.children == nil {
                Text(":").foregroundStyle(.secondary)
                Text(node.value.scalarText)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(node.value.scalarText).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch node.value {
        case .object: Text("{}").font(.callout.monospaced().weight(.semibold)).foregroundStyle(.blue)
        case .array: Text("[]").font(.callout.monospaced().weight(.semibold)).foregroundStyle(.blue)
        case .null: Image(systemName: "circle.slash").foregroundStyle(.blue)
        case .bool(let flag): Image(systemName: flag ? "checkmark" : "xmark").foregroundStyle(.blue)
        case .number: Image(systemName: "number").foregroundStyle(.blue)
        case .string: Image(systemName: "textformat").foregroundStyle(.secondary)
        }
    }

    private var valueColor: Color {
        switch node.value {
        case .string: .red
        case .null: .secondary
        default: .blue
        }
    }
}

#if DEBUG
    #Preview("JSON tree") {
        JSONTreeView(
            value: try! JSONValue.parse(
                #"{"vodafone":{"account_number":null,"crm_data_source_id":11,"create_new_account":true},"tags":["a","b"],"note":""}"#
            )
        )
        .frame(width: 760, height: 360)
    }
#endif
