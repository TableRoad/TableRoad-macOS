#if DEBUG
    import Foundation
    import TableRoadCore
    import TableRoadStorage

    /// Sample data for SwiftUI previews. Debug-only; nothing here touches a real database or the Keychain.
    enum PreviewData {
        static let profiles: [ConnectionProfile] = [
            ConnectionProfile(
                name: "Production Shop", kind: .mysql, host: "db.example.com", username: "app", database: "shop",
                ssh: SSHConfig(host: "bastion.example.com", username: "deploy", auth: .agent(socketPath: nil)),
                tag: .production, safeMode: .confirmWrites),
            ConnectionProfile(
                name: "Staging", kind: .mariadb, host: "staging.internal", username: "app", database: "shop",
                tag: .staging),
            ConnectionProfile(name: "Local MySQL", kind: .mysql, username: "root", database: "tableroad", tag: .local),
        ]

        /// A store backed by a throwaway file and in-memory secrets.
        @MainActor
        static func store(empty: Bool = false) -> ConnectionStore {
            let file = FileManager.default.temporaryDirectory.appending(path: "tableroad-preview-\(UUID()).json")
            let store = ConnectionStore(fileURL: file, secrets: InMemorySecretStore())
            if !empty {
                for profile in profiles { try? store.save(profile, password: "secret") }
            }
            return store
        }

        static let ordersSchema: [ColumnDetail] = [
            ColumnDetail(name: "id", type: "bigint", isNullable: false, isPrimaryKey: true, extra: "auto_increment"),
            ColumnDetail(name: "customer_id", type: "bigint", isNullable: false, isPrimaryKey: false),
            ColumnDetail(name: "total", type: "decimal(12,2)", isNullable: false, isPrimaryKey: false),
            ColumnDetail(
                name: "status", type: "enum('pending','paid','shipped')", isNullable: false, isPrimaryKey: false,
                defaultValue: "pending"),
            ColumnDetail(
                name: "note", type: "varchar(255)", isNullable: true, isPrimaryKey: false,
                comment: "Optional reviewer note"),
            ColumnDetail(name: "placed_at", type: "datetime(6)", isNullable: false, isPrimaryKey: false),
        ]

        static let orders: ResultSet = {
            let columns = [
                ResultColumn(name: "id", table: "orders", typeName: "BIGINT"),
                ResultColumn(name: "customer_id", table: "orders", typeName: "BIGINT"),
                ResultColumn(name: "total", table: "orders", typeName: "DECIMAL"),
                ResultColumn(name: "status", table: "orders", typeName: "ENUM"),
                ResultColumn(name: "note", table: "orders", typeName: "VARCHAR"),
                ResultColumn(name: "placed_at", table: "orders", typeName: "DATETIME"),
            ]
            let statuses = ["pending", "paid", "shipped"]
            var rows: [[CellValue]] = []
            for id in 1...40 {
                let total = String(format: "%.2f", Double(id) * 12.34)
                let note: CellValue = id % 5 == 0 ? .text("Gift wrap") : .null
                let placed = "2026-11-16 21:06:" + String(format: "%02d", id % 60) + ".643000"
                let row: [CellValue] = [
                    .int(Int64(id)), .int(Int64(900 + id % 37)), .decimal(total), .text(statuses[id % 3]), note,
                    .temporal(placed),
                ]
                rows.append(row)
            }
            return ResultSet(columns: columns, rows: rows)
        }()

        static let summary = ResultSet(
            columns: [ResultColumn(name: "status", typeName: "ENUM"), ResultColumn(name: "n", typeName: "BIGINT")],
            rows: [[.text("shipped"), .int(3334)], [.text("paid"), .int(3334)], [.text("pending"), .int(3332)]])

        static let tables: [TableInfo] = [
            TableInfo(name: "customers", kind: .table), TableInfo(name: "inspector_demo", kind: .table),
            TableInfo(name: "orders", kind: .table), TableInfo(name: "order_totals", kind: .view),
        ]

        /// A row with every kind of field the inspector renders.
        static let inspectorRow: InspectorRow = {
            let png = Data(base64Encoded: tinyPNG) ?? Data()
            return InspectorRow(
                title: "Row 1",
                columns: [
                    ResultColumn(name: "id", typeName: "INT"), ResultColumn(name: "title", typeName: "VARCHAR"),
                    ResultColumn(name: "body", typeName: "TEXT"), ResultColumn(name: "settings", typeName: "JSON"),
                    ResultColumn(name: "status", typeName: "ENUM"), ResultColumn(name: "note", typeName: "VARCHAR"),
                    ResultColumn(name: "avatar", typeName: "BLOB"),
                ],
                values: [
                    .int(1), .text("Release notes"),
                    .text("TableRoad 0.1\n\n- MySQL & MariaDB\n- Filters\n- Inline editing"),
                    .json(#"{"theme":"dark","fonts":{"grid":"SF Mono","size":13},"tags":["beta","mac"]}"#),
                    .text("published"), .null, .bytes(png),
                ],
                details: [
                    ColumnDetail(name: "id", type: "int", isNullable: false, isPrimaryKey: true),
                    ColumnDetail(name: "title", type: "varchar(100)", isNullable: false, isPrimaryKey: false),
                    ColumnDetail(name: "body", type: "text", isNullable: true, isPrimaryKey: false),
                    ColumnDetail(name: "settings", type: "json", isNullable: true, isPrimaryKey: false),
                    ColumnDetail(
                        name: "status", type: "enum('draft','published','archived')", isNullable: false,
                        isPrimaryKey: false),
                    ColumnDetail(
                        name: "note", type: "varchar(255)", isNullable: true, isPrimaryKey: false,
                        comment: "Optional reviewer note"),
                    ColumnDetail(name: "avatar", type: "blob", isNullable: true, isPrimaryKey: false),
                ],
                states: [.normal, .edited, .normal, .normal, .normal, .normal, .normal])
        }()

        /// 1×1 amber PNG, enough to exercise the image preview.
        static let tinyPNG =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/58BAwAI/AL+hc2rNAAAAABJRU5ErkJggg=="
    }
#endif
