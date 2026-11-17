import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO
import TableRoadCore
import TableRoadSQL

/// Settings for one PostgreSQL connection (also Redshift, CockroachDB, Greenplum).
public struct PostgresConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    /// The database to connect to (PostgreSQL can't switch databases on a connection). Defaults to the user name.
    public var database: String?
    public var tls: TLSMode
    public var tlsFiles: TLSFiles
    public var bootstrapSQL: String?
    public var kind: DatabaseKind

    public init(
        host: String, port: Int = 5432, username: String, password: String?, database: String? = nil,
        tls: TLSMode = .prefer, tlsFiles: TLSFiles = TLSFiles(), bootstrapSQL: String? = nil,
        kind: DatabaseKind = .postgres
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
        self.tlsFiles = tlsFiles
        self.bootstrapSQL = bootstrapSQL
        self.kind = kind
    }

    public init(profile: ConnectionProfile, password: String?) {
        self.init(
            host: profile.host, port: profile.port, username: profile.username, password: password,
            database: profile.database.flatMap { $0.isEmpty ? nil : $0 }, tls: profile.tls, tlsFiles: profile.tlsFiles,
            bootstrapSQL: profile.bootstrapSQL.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }, kind: profile.kind)
    }
}

/// A PostgreSQL connection. Reads use the simple-query protocol (text results, so every type displays);
/// writes with parameters use the extended protocol with untyped text values that the server coerces.
public actor PostgresSession: SQLClient {
    private let connection: PostgresConnection
    private let config: PostgresConnectConfig
    private let lock = AsyncSerialLock()
    private let logger = Logger(label: "tableroad.postgres")

    public let kind: DatabaseKind
    public let serverVersion: String
    public nonisolated let processID: UInt64
    public nonisolated let isEncrypted: Bool
    public nonisolated let tlsCipher: String?
    /// The database this connection is attached to (schemas are listed as "databases").
    public nonisolated let databaseName: String
    public private(set) var currentDatabase: String?

    public nonisolated var sqlDialect: any SQLDialect { PostgresDialect() }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: true, createDatabases: true, databaseNoun: "schema")
    }

    public static func connect(_ config: PostgresConnectConfig) async throws -> PostgresSession {
        let connection = try await openConnection(config)
        do {
            if let bootstrap = config.bootstrapSQL {
                for statement in StatementSplitter(syntax: .postgres).split(bootstrap) {
                    do {
                        _ = try await connection.simpleQuery(statement.text).get()
                    } catch {
                        throw DatabaseError(
                            .query, "Bootstrap command failed (\(statement.text)): \(mapError(error).message)")
                    }
                }
            }
            let info = try await textRows(
                connection,
                "SELECT version(), pg_backend_pid()::text, current_database()::text, current_schema()::text, "
                    + "COALESCE((SELECT ssl::text || '|' || COALESCE(cipher, '') FROM pg_stat_ssl "
                    + "WHERE pid = pg_backend_pid()), 'false|')")
            guard let row = info.first, row.count >= 5 else {
                throw DatabaseError(.connection, "The server didn't describe itself.")
            }
            let ssl = (row[4] ?? "false|").split(separator: "|", omittingEmptySubsequences: false)
            return PostgresSession(
                connection: connection, config: config, version: Self.shortVersion(row[0] ?? ""),
                pid: UInt64(row[1] ?? "") ?? 0, database: row[2] ?? "", schema: row[3],
                cipher: ssl.first == "true" ? String(ssl.dropFirst().first ?? "TLS") : nil)
        } catch {
            try? await connection.close()
            throw mapError(error)
        }
    }

    private init(
        connection: PostgresConnection, config: PostgresConnectConfig, version: String, pid: UInt64, database: String,
        schema: String?, cipher: String?
    ) {
        self.connection = connection
        self.config = config
        self.serverVersion = version
        self.processID = pid
        self.databaseName = database
        self.currentDatabase = schema
        self.isEncrypted = cipher != nil
        self.tlsCipher = cipher.map { $0.isEmpty ? "TLS" : $0 }
        // CockroachDB/Redshift report themselves in version(); keep the profile's engine otherwise.
        let lowered = version.lowercased()
        kind =
            lowered.contains("cockroach") ? .cockroach : lowered.contains("redshift") ? .redshift : config.kind
    }

    deinit {
        let connection = connection
        Task { try? await connection.close() }
    }

    /// "PostgreSQL 17.2 (Debian …) on aarch64…" → "17.2".
    static func shortVersion(_ full: String) -> String {
        let parts = full.split(separator: " ")
        if parts.count >= 2, parts[0] == "PostgreSQL" { return String(parts[1]) }
        if let range = full.range(of: #"v?\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            return String(full[range])
        }
        return full
    }

    static func openConnection(_ config: PostgresConnectConfig) async throws -> PostgresConnection {
        let tls: PostgresConnection.Configuration.TLS
        switch config.tls {
        case .disable:
            tls = .disable
        case .prefer:
            tls = try .prefer(makeContext(.none, files: config.tlsFiles))
        case .require:
            tls = try .require(makeContext(.none, files: config.tlsFiles))
        case .verifyCA:
            tls = try .require(makeContext(.noHostnameVerification, files: config.tlsFiles))
        case .verifyFull:
            tls = try .require(makeContext(.fullVerification, files: config.tlsFiles))
        }
        var configuration = PostgresConnection.Configuration(
            host: config.host, port: config.port, username: config.username, password: config.password,
            database: config.database ?? config.username, tls: tls)
        configuration.options.connectTimeout = .seconds(15)
        do {
            return try await PostgresConnection.connect(
                configuration: configuration, id: Int.random(in: 1...Int.max),
                logger: Logger(label: "tableroad.postgres"))
        } catch {
            throw mapError(error)
        }
    }

    static func makeContext(_ verification: CertificateVerification, files: TLSFiles) throws -> NIOSSLContext {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = verification
        func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        do {
            if let ca = files.caCertPath { tls.trustRoots = .file(expand(ca)) }
            if let cert = files.clientCertPath {
                tls.certificateChain = try NIOSSLCertificate.fromPEMFile(expand(cert)).map { .certificate($0) }
            }
            if let key = files.clientKeyPath { tls.privateKey = .file(expand(key)) }
            return try NIOSSLContext(configuration: tls)
        } catch {
            throw DatabaseError(.tls, "Couldn't set up TLS: \(error)")
        }
    }

    public func close() async {
        try? await connection.close()
    }

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        try await lock.run { try await self.executeLocked(sql) }
    }

    private func executeLocked(_ sql: String) async throws -> QueryOutcome {
        if Self.returnsRows(sql) {
            let rows: [PostgresRow]
            do {
                rows = try await connection.simpleQuery(sql).get()
            } catch {
                throw Self.mapError(error)
            }
            try await refreshSchemaIfNeeded(after: sql)
            return .rows(Self.resultSet(rows))
        }
        do {
            let result = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger).get()
            try await refreshSchemaIfNeeded(after: sql)
            if !result.rows.isEmpty { return .rows(Self.resultSet(result.rows, binary: true)) }
            return .affected(rowCount: UInt64(max(result.metadata.rows ?? 0, 0)))
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "42601" {
            // Several statements in one string aren't allowed in the extended protocol; run them as a script.
            do {
                _ = try await connection.simpleQuery(sql).get()
            } catch {
                throw Self.mapError(error)
            }
            try await refreshSchemaIfNeeded(after: sql)
            return .affected(rowCount: 0)
        } catch {
            throw Self.mapError(error)
        }
    }

    public func run(_ sql: String) async throws {
        try await lock.run {
            do {
                _ = try await self.connection.simpleQuery(sql).get()
            } catch {
                throw Self.mapError(error)
            }
            try await self.refreshSchemaIfNeeded(after: sql)
        }
    }

    /// Statements that produce a result set (read with the simple protocol, as text).
    static func returnsRows(_ sql: String) -> Bool {
        let head = sql.drop(while: { $0.isWhitespace || $0 == "(" }).prefix(8).uppercased()
        let readers = ["SELECT", "WITH", "SHOW", "VALUES", "TABLE", "EXPLAIN", "FETCH"]
        if readers.contains(where: { head.hasPrefix($0) }) { return true }
        return sql.range(of: #"\bRETURNING\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func refreshSchemaIfNeeded(after sql: String) async throws {
        let lowered = sql.lowercased()
        guard lowered.contains("search_path") else { return }
        let rows = try await Self.textRows(connection, "SELECT current_schema()::text")
        currentDatabase = rows.first?.first ?? currentDatabase
    }

    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        try await lock.run { try await self.transactionLocked(statements) }
    }

    private func transactionLocked(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        do {
            _ = try await connection.simpleQuery("BEGIN").get()
        } catch {
            throw TransactionError(statementIndex: 0, underlying: Self.mapError(error))
        }
        var affected: [UInt64] = []
        for (index, statement) in statements.enumerated() {
            do {
                var binds = PostgresBindings()
                for parameter in statement.parameters {
                    switch parameter {
                    case .text(let value): try binds.append(UntypedText(value))
                    case .null: binds.appendNull()
                    }
                }
                let result = try await connection.query(
                    PostgresQuery(unsafeSQL: statement.sql, binds: binds), logger: logger
                ).get()
                affected.append(UInt64(max(result.metadata.rows ?? 0, 0)))
            } catch {
                _ = try? await connection.simpleQuery("ROLLBACK").get()
                throw TransactionError(statementIndex: index, underlying: Self.mapError(error))
            }
        }
        do {
            _ = try await connection.simpleQuery("COMMIT").get()
        } catch {
            let mapped = Self.mapError(error)
            if mapped.category == .connection {
                throw TransactionError(statementIndex: statements.count, underlying: mapped, commitOutcomeUnknown: true)
            }
            _ = try? await connection.simpleQuery("ROLLBACK").get()
            throw TransactionError(statementIndex: statements.count, underlying: mapped)
        }
        return affected
    }

    /// Cancels the running statement from a second connection (pg_cancel_backend).
    public nonisolated func cancelCurrentQuery() async throws {
        try await signal(processID, function: "pg_cancel_backend")
    }

    private nonisolated func signal(_ pid: UInt64, function: String) async throws {
        let other = try await Self.openConnection(config)
        defer { Task { try? await other.close() } }
        do {
            _ = try await other.simpleQuery("SELECT \(function)(\(pid))").get()
        } catch {
            throw Self.mapError(error)
        }
    }

    public func processList() async throws -> [ServerProcess] {
        let rows = try await textRows(
            """
            SELECT pid::text, COALESCE(usename, '')::text, COALESCE(client_addr::text, 'local'), datname::text,
                COALESCE(backend_type, ''),
                COALESCE(EXTRACT(EPOCH FROM now() - COALESCE(query_start, backend_start))::bigint, 0)::text,
                state, query
            FROM pg_stat_activity ORDER BY pid
            """)
        return rows.compactMap { row in
            guard let pid = row[0].flatMap({ UInt64($0) }) else { return nil }
            let state = row[6]
            return ServerProcess(
                id: pid, user: row[1] ?? "", host: row[2] ?? "", database: row[3],
                command: state == "active" ? "Query" : (state == nil ? (row[4] ?? "") : "Idle"),
                seconds: Int(row[5] ?? "0") ?? 0, state: state,
                info: state == "active" || state?.hasPrefix("idle in") == true ? row[7] : nil)
        }
    }

    public func kill(processID: UInt64, connection: Bool) async throws {
        try await signal(processID, function: connection ? "pg_terminate_backend" : "pg_cancel_backend")
    }

    // MARK: Introspection

    /// Switches the schema (search_path). Databases themselves need a new connection.
    public func useDatabase(_ name: String) async throws {
        try await run("SET search_path TO \(PostgresDialect().quoteIdentifier(name))")
        currentDatabase = name
    }

    /// Schemas of the connected database.
    public func databases() async throws -> [String] {
        try await textRows(
            "SELECT nspname::text FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_toast%' AND nspname NOT LIKE 'pg\\_temp%' "
                + "ORDER BY nspname"
        ).compactMap { $0.first ?? nil }
    }

    public func tables(in database: String) async throws -> [TableInfo] {
        let q = PostgresDialect()
        let rows = try await textRows(
            """
            SELECT c.relname::text, c.relkind::text, GREATEST(c.reltuples, 0)::bigint::text
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(q.stringLiteral(database)) AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
            ORDER BY c.relname
            """)
        return rows.map { row in
            let kind: TableInfo.Kind = ["v", "m"].contains(row[1] ?? "") ? .view : .table
            return TableInfo(name: row[0] ?? "", kind: kind, estimatedRowCount: row[2].flatMap { Int($0) })
        }
    }

    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        let q = PostgresDialect()
        let rows = try await textRows(
            """
            SELECT a.attname::text, format_type(a.atttypid, a.atttypmod), (NOT a.attnotnull)::text,
                COALESCE((SELECT true FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary
                    AND a.attnum = ANY(i.indkey)), false)::text,
                pg_get_expr(d.adbin, d.adrelid), a.attidentity::text, a.attgenerated::text,
                col_description(c.oid, a.attnum), co.collname::text
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_collation co ON co.oid = a.attcollation AND co.collname <> 'default'
            WHERE n.nspname = \(q.stringLiteral(database)) AND c.relname = \(q.stringLiteral(table))
                AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """)
        return rows.map { row in
            let defaultValue = row[4]
            var extra: String?
            if row[5] == "a" || row[5] == "d" {
                extra = "identity"
            } else if row[6] == "s" {
                extra = "STORED GENERATED"
            } else if let defaultValue, defaultValue.hasPrefix("nextval(") {
                extra = "serial"
            }
            return ColumnDetail(
                name: row[0] ?? "", type: row[1] ?? "", isNullable: row[2] == "true", isPrimaryKey: row[3] == "true",
                defaultValue: extra == "serial" ? nil : defaultValue, extra: extra,
                comment: row[7].flatMap { $0.isEmpty ? nil : $0 }, collation: row[8])
        }
    }

    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        let q = PostgresDialect()
        let rows = try await textRows(
            """
            SELECT c.reltuples::bigint::text, pg_relation_size(c.oid)::text, pg_indexes_size(c.oid)::text,
                obj_description(c.oid, 'pg_class'), am.amname::text
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_am am ON am.oid = c.relam
            WHERE n.nspname = \(q.stringLiteral(database)) AND c.relname = \(q.stringLiteral(table))
            """)
        guard let row = rows.first else { throw DatabaseError(.query, "Table \(table) not found.") }
        // reltuples is -1 ("never analysed") on new tables; treat that as unknown.
        let estimate = row[0].flatMap { Int($0) }
        return TableStatus(
            estimatedRows: estimate.flatMap { $0 > 0 ? $0 : nil }, dataBytes: row[1].flatMap { Int($0) },
            indexBytes: row[2].flatMap { Int($0) }, engine: row[4].map { $0 == "heap" ? "PostgreSQL (heap)" : $0 },
            comment: row[3].flatMap { $0.isEmpty ? nil : $0 })
    }

    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let q = PostgresDialect()
        let rows = try await textRows(
            """
            SELECT ic.relname::text, am.amname::text, ix.indisunique::text, ix.indisprimary::text, k.n::text,
                pg_get_indexdef(ix.indexrelid, k.n, true)
            FROM pg_index ix
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_namespace ns ON ns.oid = t.relnamespace
            JOIN pg_class ic ON ic.oid = ix.indexrelid
            JOIN pg_am am ON am.oid = ic.relam
            CROSS JOIN LATERAL generate_series(1, ix.indnkeyatts) AS k(n)
            WHERE ns.nspname = \(q.stringLiteral(database)) AND t.relname = \(q.stringLiteral(table))
            ORDER BY ix.indisprimary DESC, ic.relname, k.n
            """)
        var result: [IndexDetail] = []
        for row in rows {
            let name = row[0] ?? ""
            let column = row[5] ?? ""
            if let last = result.indices.last, result[last].name == name || (row[3] == "true" && result[last].isPrimary)
            {
                result[last].columns.append(column)
            } else {
                result.append(
                    IndexDetail(
                        name: row[3] == "true" ? "PRIMARY" : name, algorithm: (row[1] ?? "").uppercased(),
                        isUnique: row[2] == "true", columns: [column]))
            }
        }
        return result
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] {
        let q = PostgresDialect()
        let rows = try await textRows(
            """
            SELECT con.conname::text, a.attname::text, fn.nspname::text, ft.relname::text, fa.attname::text, con.confupdtype::text,
                con.confdeltype::text
            FROM pg_constraint con
            JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_class ft ON ft.oid = con.confrelid JOIN pg_namespace fn ON fn.oid = ft.relnamespace
            CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(col, fcol, pos)
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.col
            JOIN pg_attribute fa ON fa.attrelid = ft.oid AND fa.attnum = k.fcol
            WHERE con.contype = 'f' AND n.nspname = \(q.stringLiteral(database))
                AND t.relname = \(q.stringLiteral(table))
            ORDER BY con.conname, k.pos
            """)
        var keys: [ForeignKeyDetail] = []
        for row in rows {
            let name = row[0] ?? ""
            if let last = keys.indices.last, keys[last].name == name {
                keys[last].columns.append(row[1] ?? "")
                keys[last].referencedColumns.append(row[4] ?? "")
            } else {
                keys.append(
                    ForeignKeyDetail(
                        name: name, columns: [row[1] ?? ""], referencedDatabase: row[2] ?? "",
                        referencedTable: row[3] ?? "", referencedColumns: [row[4] ?? ""],
                        onUpdate: Self.action(row[5]), onDelete: Self.action(row[6])))
            }
        }
        return keys
    }

    static func action(_ code: String?) -> String {
        switch code {
        case "r": "RESTRICT"
        case "c": "CASCADE"
        case "n": "SET NULL"
        case "d": "SET DEFAULT"
        default: "NO ACTION"
        }
    }

    /// PostgreSQL has no SHOW CREATE TABLE, so the statement is assembled from the catalog. Names are unqualified
    /// (a dump runs under SET search_path), sequences become serial columns, and indexes and foreign keys follow.
    public func createStatement(of table: String, in database: String) async throws -> String {
        let q = PostgresDialect()
        let kindRows = try await textRows(
            """
            SELECT c.relkind::text, pg_get_viewdef(c.oid, true) FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(q.stringLiteral(database)) AND c.relname = \(q.stringLiteral(table))
            """)
        guard let kindRow = kindRows.first else { throw DatabaseError(.query, "\(table) not found.") }
        if kindRow[0] == "v" || kindRow[0] == "m" {
            let materialized = kindRow[0] == "m" ? "MATERIALIZED " : ""
            return "CREATE \(materialized)VIEW \(q.quoteIdentifier(table)) AS\n"
                + (kindRow[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                    in: CharacterSet(charactersIn: ";"))
        }
        let columns = try await columns(of: table, in: database)
        var lines = columns.map { column -> String in
            var type = column.type
            if column.extra == "serial" {
                type = type == "bigint" ? "bigserial" : type == "smallint" ? "smallserial" : "serial"
            }
            var line = "  \(q.quoteIdentifier(column.name)) \(type)"
            if column.extra == "identity" { line += " GENERATED BY DEFAULT AS IDENTITY" }
            if let collation = column.collation { line += " COLLATE \(q.quoteIdentifier(collation))" }
            if !column.isNullable { line += " NOT NULL" }
            if let value = column.defaultValue {
                line +=
                    column.extra == "STORED GENERATED" ? " GENERATED ALWAYS AS (\(value)) STORED" : " DEFAULT \(value)"
            }
            return line
        }
        let constraints = try await textRows(
            """
            SELECT con.conname::text, pg_get_constraintdef(con.oid, true), con.contype::text FROM pg_constraint con
            JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = \(q.stringLiteral(database)) AND t.relname = \(q.stringLiteral(table))
                AND con.contype IN ('p', 'u', 'c')
            ORDER BY con.contype = 'p' DESC, con.conname
            """)
        for constraint in constraints {
            lines.append("  CONSTRAINT \(q.quoteIdentifier(constraint[0] ?? "")) \(constraint[1] ?? "")")
        }
        var sql = "CREATE TABLE \(q.quoteIdentifier(table)) (\n" + lines.joined(separator: ",\n") + "\n)"
        // Indexes that aren't behind a constraint, then foreign keys (as ALTERs, so table order doesn't matter
        // as long as the referenced table exists by the time they run).
        let indexes = try await textRows(
            """
            SELECT pg_get_indexdef(ix.indexrelid) FROM pg_index ix
            JOIN pg_class t ON t.oid = ix.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = \(q.stringLiteral(database)) AND t.relname = \(q.stringLiteral(table))
                AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = ix.indexrelid)
            ORDER BY 1
            """)
        for index in indexes {
            if let definition = index.first ?? nil {
                sql += ";\n" + Self.unqualify(definition, schema: database)
            }
        }
        let foreign = try await textRows(
            """
            SELECT con.conname::text, pg_get_constraintdef(con.oid, true) FROM pg_constraint con
            JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = \(q.stringLiteral(database)) AND t.relname = \(q.stringLiteral(table))
                AND con.contype = 'f'
            ORDER BY con.conname
            """)
        for key in foreign {
            sql +=
                ";\nALTER TABLE \(q.quoteIdentifier(table)) ADD CONSTRAINT \(q.quoteIdentifier(key[0] ?? "")) "
                + Self.unqualify(key[1] ?? "", schema: database)
        }
        return sql
    }

    /// Drops "schema." prefixes for the table's own schema, so the DDL can be replayed into another schema.
    static func unqualify(_ sql: String, schema: String) -> String {
        let quoted = PostgresDialect().quoteIdentifier(schema)
        return sql.replacingOccurrences(of: " \(quoted).", with: " ").replacingOccurrences(of: " \(schema).", with: " ")
    }

    public func characterSets() async throws -> [CharacterSetInfo] { [] }

    // MARK: Helpers

    private func textRows(_ sql: String) async throws -> [[String?]] {
        try await lock.run { try await Self.textRows(self.connection, sql) }
    }

    static func textRows(_ connection: PostgresConnection, _ sql: String) async throws -> [[String?]] {
        do {
            return try await connection.simpleQuery(sql).get().map { row in
                row.map { cell in cell.bytes.map { String(buffer: $0) } }
            }
        } catch {
            throw mapError(error)
        }
    }

    static func resultSet(_ rows: [PostgresRow], binary: Bool = false) -> ResultSet {
        guard let first = rows.first else { return .empty }
        let columns = first.map { cell in
            ResultColumn(name: cell.columnName, typeName: typeName(cell.dataType))
        }
        let values = rows.map { row in row.map { cell in PostgresValueDecoder.decode(cell) } }
        return ResultSet(columns: columns, rows: values)
    }

    static func typeName(_ type: PostgresDataType) -> String {
        switch type {
        case .bool: "BOOL"
        case .int2: "INT2"
        case .int4: "INT4"
        case .int8: "INT8"
        case .numeric: "NUMERIC"
        case .float4: "FLOAT4"
        case .float8: "FLOAT8"
        case .bytea: "BYTEA"
        case .json: "JSON"
        case .jsonb: "JSONB"
        case .uuid: "UUID"
        case .date: "DATE"
        case .time: "TIME"
        case .timestamp: "TIMESTAMP"
        case .timestamptz: "TIMESTAMPTZ"
        default: type.knownSQLName?.uppercased() ?? "OID \(type.rawValue)"
        }
    }

    static func serverError(state: String, message: String) -> DatabaseError {
        let category: DatabaseError.Category =
            switch state {
            case "28P01", "28000": .authentication
            case "57014": .cancelled
            case let code where code.hasPrefix("08") || code == "57P01": .connection
            default: .query
            }
        return DatabaseError(category, message + (state.isEmpty ? "" : " (\(state))"))
    }

    static func mapError(_ error: any Error) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if let error = error as? PSQLError {
            if let info = error.serverInfo {
                return serverError(state: info[.sqlState] ?? "", message: info[.message] ?? "Server error")
            }
            switch error.code {
            case .queryCancelled: return DatabaseError(.cancelled, "The query was cancelled.")
            case .serverClosedConnection, .connectionError, .uncleanShutdown, .clientClosedConnection:
                let detail = error.underlying.map { ": \($0)" } ?? ""
                return DatabaseError(.connection, "Couldn't reach the server\(detail)")
            case .failedToAddSSLHandler, .sslUnsupported:
                return DatabaseError(.tls, "TLS failed: \(error.underlying.map { "\($0)" } ?? "\(error)")")
            default:
                return DatabaseError(.query, "\(error)")
            }
        }
        if let error = error as? PostgresError {
            switch error {
            case .server(let response):
                return serverError(
                    state: response.fields[.sqlState] ?? "", message: response.fields[.message] ?? "\(error)")
            case .connectionClosed:
                return DatabaseError(.connection, "The server closed the connection.")
            case .protocol(let message):
                return DatabaseError(.connection, "Protocol error: \(message)")
            }
        }
        if let error = error as? NIOSSLError {
            return DatabaseError(.tls, "TLS failed: \(error)")
        }
        return DatabaseError(.connection, error.localizedDescription)
    }
}

/// A parameter sent as untyped text, so the server infers its type from the column (like MySQL's binds).
struct UntypedText: PostgresThrowingDynamicTypeEncodable {
    let value: String
    init(_ value: String) { self.value = value }
    var psqlType: PostgresDataType { PostgresDataType(0) }
    var psqlFormat: PostgresFormat { .text }

    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) throws {
        byteBuffer.writeString(value)
    }
}

/// Maps PostgreSQL values to CellValue. postgres-nio always asks for binary results, so each type is decoded from
/// its binary form and shown as PostgreSQL would print it.
enum PostgresValueDecoder {
    static func decode(_ cell: PostgresCell) -> CellValue {
        guard let bytes = cell.bytes else { return .null }
        if cell.format == .text { return textValue(cell.dataType, String(buffer: bytes)) }
        return value(cell.dataType, bytes)
    }

    /// Text-format values (not normally sent, but handled).
    static func textValue(_ type: PostgresDataType, _ text: String) -> CellValue {
        switch type {
        case .bool: .bool(text == "t")
        case .int2, .int4, .int8, .oid: Int64(text).map { .int($0) } ?? .text(text)
        case .float4, .float8: Double(text).map { .double($0) } ?? .text(text)
        case .numeric: .decimal(text)
        case .json, .jsonb: .json(text)
        case .date, .time, .timestamp, .timestamptz, .timetz, .interval: .temporal(text)
        default: .text(text)
        }
    }

    static func value(_ type: PostgresDataType, _ buffer: ByteBuffer) -> CellValue {
        var bytes = buffer
        switch type {
        case .bool:
            return bytes.readInteger(as: UInt8.self).map { .bool($0 != 0) } ?? .null
        case .int2:
            return bytes.readInteger(as: Int16.self).map { .int(Int64($0)) } ?? .null
        case .int4:
            return bytes.readInteger(as: Int32.self).map { .int(Int64($0)) } ?? .null
        case .oid:
            return bytes.readInteger(as: UInt32.self).map { .int(Int64($0)) } ?? .null
        case .int8:
            return bytes.readInteger(as: Int64.self).map { .int($0) } ?? .null
        case .float4:
            return bytes.readInteger(as: UInt32.self).map { .double(Double(Float(bitPattern: $0))) } ?? .null
        case .float8:
            return bytes.readInteger(as: UInt64.self).map { .double(Double(bitPattern: $0)) } ?? .null
        case .numeric:
            let data = PostgresData(type: .numeric, formatCode: .binary, value: buffer)
            return data.numeric.map { .decimal($0.string) } ?? .text("NaN")
        case .bytea:
            return .bytes(Data(bytes.readableBytesView))
        case .json:
            return .json(String(buffer: bytes))
        case .jsonb:
            _ = bytes.readInteger(as: UInt8.self)  // version byte (1)
            return .json(String(buffer: bytes))
        case .uuid:
            guard let raw = bytes.readBytes(length: 16) else { return .null }
            let uuid = raw.withUnsafeBufferPointer { pointer in
                NSUUID(uuidBytes: pointer.baseAddress).uuidString
            }
            return UUID(uuidString: uuid).map { .uuid($0) } ?? .text(uuid)
        case .date:
            return bytes.readInteger(as: Int32.self).map { .temporal(dateString(days: Int($0))) } ?? .null
        case .timestamp:
            return bytes.readInteger(as: Int64.self).map { .temporal(timestampString($0)) } ?? .null
        case .timestamptz:
            return bytes.readInteger(as: Int64.self).map { .temporal(timestampString($0) + "+00") } ?? .null
        case .time:
            return bytes.readInteger(as: Int64.self).map { .temporal(timeString($0)) } ?? .null
        case .timetz:
            guard let micros = bytes.readInteger(as: Int64.self), let zone = bytes.readInteger(as: Int32.self)
            else { return .null }
            return .temporal(timeString(micros) + offsetString(-Int(zone)))
        case .interval:
            guard let micros = bytes.readInteger(as: Int64.self), let days = bytes.readInteger(as: Int32.self),
                let months = bytes.readInteger(as: Int32.self)
            else { return .null }
            return .temporal(intervalString(micros: micros, days: Int(days), months: Int(months)))
        default:
            if let array = arrayText(type, buffer) { return .text(array) }
            // Text-like types (text, varchar, name, enums, citext, xml, inet as text…) are UTF-8 in binary too.
            if let text = String(bytes: bytes.readableBytesView, encoding: .utf8),
                text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            {
                return .text(text)
            }
            return .bytes(Data(bytes.readableBytesView))
        }
    }

    /// Binary arrays → PostgreSQL's text form `{a,b,"c d",NULL}`.
    static func arrayText(_ type: PostgresDataType, _ buffer: ByteBuffer) -> String? {
        var bytes = buffer
        guard let dimensions = bytes.readInteger(as: Int32.self), (0...6).contains(dimensions),
            bytes.readInteger(as: Int32.self) != nil,  // has nulls
            let elementOID = bytes.readInteger(as: UInt32.self), elementOID != 0
        else { return nil }
        // Only treat it as an array when the type is a known array of that element (avoids misreading text).
        guard type.knownSQLName.map({ $0.hasSuffix("[]") || $0.hasPrefix("_") }) ?? type.isUserDefined else {
            return nil
        }
        if dimensions == 0 { return "{}" }
        var lengths: [Int] = []
        for _ in 0..<dimensions {
            guard let length = bytes.readInteger(as: Int32.self), bytes.readInteger(as: Int32.self) != nil,
                length >= 0
            else { return nil }
            lengths.append(Int(length))
        }
        let element = PostgresDataType(elementOID)
        func read(_ depth: Int) -> String? {
            var parts: [String] = []
            for _ in 0..<lengths[depth] {
                if depth + 1 < lengths.count {
                    guard let inner = read(depth + 1) else { return nil }
                    parts.append(inner)
                    continue
                }
                guard let length = bytes.readInteger(as: Int32.self) else { return nil }
                if length < 0 {
                    parts.append("NULL")
                    continue
                }
                guard let slice = bytes.readSlice(length: Int(length)) else { return nil }
                let text = value(element, slice).displayText ?? "NULL"
                let needsQuotes = text.isEmpty || text.contains(where: { ",{}\" \\".contains($0) }) || text == "NULL"
                parts.append(
                    needsQuotes
                        ? "\""
                            + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
                                of: "\"", with: "\\\"")
                            + "\"" : text)
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        guard let text = read(0), bytes.readableBytes == 0 else { return nil }
        return text
    }

    // MARK: Dates (PostgreSQL's epoch is 2000-01-01)

    static func dateString(days: Int) -> String {
        // Civil-from-days (Howard Hinnant), shifted from 1970 to 2000.
        let z = days + 10_957 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func timeString(_ micros: Int64) -> String {
        let seconds = micros / 1_000_000
        let fraction = micros % 1_000_000
        var text = String(format: "%02lld:%02lld:%02lld", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        if fraction != 0 {
            var digits = String(format: "%06lld", fraction)
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return text
    }

    static func timestampString(_ micros: Int64) -> String {
        var days = micros / 86_400_000_000
        var rest = micros % 86_400_000_000
        if rest < 0 {
            rest += 86_400_000_000
            days -= 1
        }
        return dateString(days: Int(days)) + " " + timeString(rest)
    }

    static func offsetString(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let value = abs(seconds)
        let minutes = (value / 60) % 60
        return sign + String(format: "%02d", value / 3600) + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }

    static func intervalString(micros: Int64, days: Int, months: Int) -> String {
        var parts: [String] = []
        if months / 12 != 0 { parts.append("\(months / 12) year\(abs(months / 12) == 1 ? "" : "s")") }
        if months % 12 != 0 { parts.append("\(months % 12) mon\(abs(months % 12) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty { parts.append((micros < 0 ? "-" : "") + timeString(abs(micros))) }
        return parts.joined(separator: " ")
    }
}
