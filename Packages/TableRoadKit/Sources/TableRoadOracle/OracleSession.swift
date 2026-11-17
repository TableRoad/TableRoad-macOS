import Foundation
import TableRoadCore
import TableRoadSQL

/// Oracle spelling: double-quoted identifiers, `:n` binds, `OFFSET … FETCH NEXT … ROWS ONLY` paging (12c+).
/// TableRoad's "databases" are schemas (users that own objects).
public struct OracleDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func stringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public func placeholder(_ index: Int) -> String { ":\(index)" }

    public func bytesLiteral(_ data: Data) -> String {
        "HEXTORAW('" + data.map { String(format: "%02X", $0) }.joined() + "')"
    }

    /// 1/0 work for NUMBER flags and for 23ai BOOLEAN columns alike.
    public func booleanLiteral(_ value: Bool) -> String { value ? "1" : "0" }

    /// A schema is a user; a schema-only account owns objects but can't log in.
    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DDLError.emptyName }
        guard trimmed.utf8.count <= 128 else { throw DDLError.nameTooLong }
        return "CREATE USER \(quoteIdentifier(trimmed)) NO AUTHENTICATION"
    }

    public func dropDatabaseSQL(_ name: String) -> String { "DROP USER \(quoteIdentifier(name)) CASCADE" }

    public func useDatabaseSQL(_ name: String) -> String? {
        "ALTER SESSION SET CURRENT_SCHEMA = \(quoteIdentifier(name))"
    }

    public func pagingClause(limit: Int, offset: Int, ordered: Bool) -> String {
        " OFFSET \(max(offset, 0)) ROWS FETCH NEXT \(max(limit, 0)) ROWS ONLY"
    }
}

/// Settings for one Oracle connection. The profile's database field holds the service name (e.g. `FREEPDB1`).
public struct OracleConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var serviceName: String
    public var useTLS: Bool
    public var bootstrapSQL: String?

    public init(
        host: String, port: Int = 1521, username: String, password: String?, serviceName: String,
        useTLS: Bool = false, bootstrapSQL: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.serviceName = serviceName
        self.useTLS = useTLS
        self.bootstrapSQL = bootstrapSQL
    }

    public init(profile: ConnectionProfile, password: String?) {
        self.init(
            host: profile.host, port: profile.port, username: profile.username, password: password,
            serviceName: profile.database.flatMap { $0.isEmpty ? nil : $0 } ?? "FREEPDB1",
            useTLS: profile.tls == .require || profile.tls == .verifyCA || profile.tls == .verifyFull,
            bootstrapSQL: profile.bootstrapSQL.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            })
    }
}

/// An Oracle Database session over TableRoad's own thin client (no Oracle client libraries). Statements run with
/// autocommit, like the other engines; edits from the grid run in one transaction.
public actor OracleSession: SQLClient {
    private let connection: OracleConnection
    private let lock = AsyncSerialLock()
    private let dialect = OracleDialect()
    public let kind: DatabaseKind = .oracle
    public let serverVersion: String
    /// SID << 32 | serial#.
    public nonisolated let processID: UInt64
    public nonisolated let isEncrypted: Bool
    public nonisolated var tlsCipher: String? { isEncrypted ? "TLS" : nil }
    private nonisolated let canListSessions: Bool
    public private(set) var currentDatabase: String?
    private var ddlTransformsSet = false

    public nonisolated var sqlDialect: any SQLDialect { OracleDialect() }
    public nonisolated var capabilities: ClientCapabilities {
        ClientCapabilities(processList: canListSessions, createDatabases: false, databaseNoun: "schema", cancel: true)
    }

    public static func connect(_ config: OracleConnectConfig) async throws -> OracleSession {
        try await connect(config, disableEndOfResponse: false)
    }

    static func connect(_ config: OracleConnectConfig, disableEndOfResponse: Bool) async throws -> OracleSession {
        let endpoint = OracleEndpoint(
            host: config.host, port: config.port, serviceName: config.serviceName, useTLS: config.useTLS)
        let connection = try await OracleConnection.open(endpoint, disableEndOfResponse: disableEndOfResponse)
        do {
            try await connection.authenticate(user: config.username, password: config.password ?? "")
            // Text formats the grid shows and accepts back when edited.
            _ = try await connection.execute(
                """
                ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS' \
                NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF' \
                NLS_TIMESTAMP_TZ_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM' \
                NLS_NUMERIC_CHARACTERS = '.,'
                """, isQuery: false, isPLSQL: false, commit: false)
            let info = try await connection.execute(
                "SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM dual", isQuery: true, isPLSQL: false,
                commit: false)
            let schema = info.rows.first?.first?.displayText
            let canListSessions =
                (try? await connection.execute(
                    "SELECT COUNT(*) FROM v$session WHERE ROWNUM = 1", isQuery: true, isPLSQL: false, commit: false))
                != nil
            if let bootstrap = config.bootstrapSQL {
                for statement in OracleSQL.split(bootstrap) {
                    let prepared = OracleSQL.prepare(statement)
                    do {
                        _ = try await connection.execute(
                            prepared.text, isQuery: prepared.isQuery, isPLSQL: prepared.isPLSQL, commit: true)
                    } catch let error as DatabaseError {
                        throw DatabaseError(
                            error.category, "Startup SQL failed: \(error.message)", code: error.code)
                    }
                }
            }
            let sessionData = await connection.sessionData
            let sid = sessionData["AUTH_SESSION_ID"].flatMap { UInt64($0) } ?? 0
            let serial = sessionData["AUTH_SERIAL_NUM"].flatMap { UInt64($0) } ?? 0
            return OracleSession(
                connection: connection, version: await connection.serverVersion, schema: schema,
                processID: sid << 32 | serial, encrypted: config.useTLS, canListSessions: canListSessions)
        } catch {
            await connection.close()
            throw error
        }
    }

    private init(
        connection: OracleConnection, version: String, schema: String?, processID: UInt64, encrypted: Bool,
        canListSessions: Bool
    ) {
        self.connection = connection
        serverVersion = version
        currentDatabase = schema
        self.processID = processID
        isEncrypted = encrypted
        self.canListSessions = canListSessions
    }

    public func close() async {
        await lock.run { await self.connection.close() }
    }

    // MARK: Statements

    public func execute(_ sql: String) async throws -> QueryOutcome {
        try await lock.run { try await self.executeLocked(sql, commit: true) }
    }

    private func executeLocked(_ sql: String, commit: Bool) async throws -> QueryOutcome {
        let statement = OracleSQL.prepare(sql)
        guard !statement.text.isEmpty else { return .affected(rowCount: 0) }
        let result = try await connection.execute(
            statement.text, isQuery: statement.isQuery, isPLSQL: statement.isPLSQL, commit: commit && !statement.isQuery
        )
        if statement.changesSchema { await refreshCurrentSchema() }
        guard statement.isQuery, let columns = result.columns else { return .affected(rowCount: result.rowCount) }
        return .rows(
            ResultSet(
                columns: columns.map { ResultColumn(name: $0.name, typeName: $0.typeName) }, rows: result.rows))
    }

    private func refreshCurrentSchema() async {
        if let result = try? await connection.execute(
            "SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM dual", isQuery: true, isPLSQL: false, commit: false),
            let schema = result.rows.first?.first?.displayText
        {
            currentDatabase = schema
        }
    }

    public func run(_ sql: String) async throws {
        for statement in OracleSQL.split(sql) {
            _ = try await execute(statement)
        }
    }

    public func executeTransaction(_ statements: [ParameterizedStatement]) async throws -> [UInt64] {
        try await lock.run {
            var affected: [UInt64] = []
            for (index, statement) in statements.enumerated() {
                do {
                    let outcome = try await self.executeLocked(
                        OracleSQL.inline(statement, dialect: self.dialect), commit: false)
                    if case .affected(let count) = outcome { affected.append(count) } else { affected.append(0) }
                } catch {
                    let underlying = error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription)
                    try? await self.connection.rollback()
                    throw TransactionError(statementIndex: index, underlying: underlying)
                }
            }
            do {
                try await self.connection.commit()
            } catch {
                let underlying = error as? DatabaseError ?? DatabaseError(.query, error.localizedDescription)
                throw TransactionError(
                    statementIndex: statements.count, underlying: underlying,
                    commitOutcomeUnknown: underlying.category == .connection)
            }
            return affected
        }
    }

    /// Not queued behind the running statement: sends an interrupt marker on the same connection.
    public func cancelCurrentQuery() async throws {
        await connection.interrupt()
    }

    // MARK: Sessions

    public func processList() async throws -> [ServerProcess] {
        guard canListSessions else {
            throw DatabaseError(.unsupported, "Listing sessions needs SELECT access to V$SESSION.")
        }
        let rows = try await strings(
            """
            SELECT s.sid, s.serial#, s.username, s.machine, s.schemaname, s.status, s.last_call_et, s.event,
                   q.sql_text
            FROM v$session s LEFT JOIN v$sql q ON q.sql_id = s.sql_id AND q.child_number = s.sql_child_number
            WHERE s.type = 'USER' ORDER BY s.sid
            """)
        return rows.compactMap { row in
            guard let sid = row[0].flatMap({ UInt64($0) }), let serial = row[1].flatMap({ UInt64($0) }) else {
                return nil
            }
            let active = row[5] == "ACTIVE"
            return ServerProcess(
                id: sid << 32 | serial, user: row[2] ?? "", host: row[3] ?? "", database: row[4],
                command: active ? "Query" : "Sleep", seconds: row[6].flatMap { Int($0) } ?? 0,
                state: active ? row[7] : nil, info: active ? row[8] : nil)
        }
    }

    /// `ALTER SYSTEM CANCEL SQL` (statement only, 18c+) or `ALTER SYSTEM KILL SESSION`.
    public func kill(processID: UInt64, connection: Bool) async throws {
        let target = "'\(processID >> 32), \(processID & 0xffff_ffff)'"
        _ = try await execute(
            connection ? "ALTER SYSTEM KILL SESSION \(target) IMMEDIATE" : "ALTER SYSTEM CANCEL SQL \(target)")
    }

    // MARK: Catalog

    public func useDatabase(_ name: String) async throws {
        _ = try await execute("ALTER SESSION SET CURRENT_SCHEMA = \(dialect.quoteIdentifier(name))")
        currentDatabase = name
    }

    /// Schemas that own tables or views (plus the current one), without Oracle-maintained accounts.
    public func databases() async throws -> [String] {
        try await strings(
            """
            SELECT username FROM all_users u
            WHERE (u.oracle_maintained = 'N'
                   AND EXISTS (SELECT 1 FROM all_objects o WHERE o.owner = u.username
                               AND o.object_type IN ('TABLE', 'VIEW')))
               OR u.username = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
               OR u.username = USER
            ORDER BY username
            """
        ).compactMap { $0[0] }
    }

    public func tables(in database: String) async throws -> [TableInfo] {
        let owner = dialect.stringLiteral(database)
        return try await strings(
            """
            SELECT table_name, 'TABLE', num_rows FROM all_tables
            WHERE owner = \(owner) AND nested = 'NO' AND secondary = 'N' AND dropped = 'NO'
              AND (iot_type IS NULL OR iot_type = 'IOT')
            UNION ALL
            SELECT view_name, 'VIEW', NULL FROM all_views WHERE owner = \(owner)
            ORDER BY 1
            """
        ).map { row in
            TableInfo(
                name: row[0] ?? "", kind: row[1] == "VIEW" ? .view : .table,
                estimatedRowCount: row[2].flatMap { Int($0) })
        }
    }

    public func columns(of table: String, in database: String) async throws -> [ColumnDetail] {
        let owner = dialect.stringLiteral(database)
        let name = dialect.stringLiteral(table)
        let primary = Set(
            try await strings(
                """
                SELECT cc.column_name FROM all_constraints k
                JOIN all_cons_columns cc ON cc.owner = k.owner AND cc.constraint_name = k.constraint_name
                WHERE k.owner = \(owner) AND k.table_name = \(name) AND k.constraint_type = 'P'
                """
            ).compactMap { $0[0] })
        return try await strings(
            """
            SELECT c.column_name, c.data_type, c.data_length, c.data_precision, c.data_scale, c.nullable,
                   c.data_default, c.char_used, c.char_length, m.comments, c.identity_column, c.virtual_column
            FROM all_tab_cols c
            LEFT JOIN all_col_comments m
              ON m.owner = c.owner AND m.table_name = c.table_name AND m.column_name = c.column_name
            WHERE c.owner = \(owner) AND c.table_name = \(name) AND c.hidden_column = 'NO'
            ORDER BY c.column_id
            """
        ).map { row in
            let column = row[0] ?? ""
            var extra: String?
            if row[10] == "YES" { extra = "identity" } else if row[11] == "YES" { extra = "VIRTUAL GENERATED" }
            return ColumnDetail(
                name: column,
                type: Self.columnType(
                    dataType: row[1] ?? "", length: row[2], precision: row[3], scale: row[4], charUsed: row[7],
                    charLength: row[8]),
                isNullable: row[5] == "Y", isPrimaryKey: primary.contains(column),
                defaultValue: row[6].flatMap {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty || trimmed.uppercased() == "NULL" ? nil : trimmed
                },
                extra: extra, comment: row[9])
        }
    }

    /// The column's type as written in DDL, e.g. `VARCHAR2(50 CHAR)`, `NUMBER(10,2)`, `RAW(16)`.
    static func columnType(
        dataType: String, length: String?, precision: String?, scale: String?, charUsed: String?, charLength: String?
    ) -> String {
        switch dataType {
        case "VARCHAR2", "CHAR":
            return "\(dataType)(\(charLength ?? length ?? "1")\(charUsed == "C" ? " CHAR" : ""))"
        case "NVARCHAR2", "NCHAR":
            return "\(dataType)(\(charLength ?? length ?? "1"))"
        case "RAW", "UROWID":
            return "\(dataType)(\(length ?? "1"))"
        case "NUMBER":
            switch (precision, scale) {
            case (nil, nil): return "NUMBER"
            case (nil, let scale?): return "NUMBER(*,\(scale))"
            case (let precision?, "0"), (let precision?, nil): return "NUMBER(\(precision))"
            case (let precision?, let scale?): return "NUMBER(\(precision),\(scale))"
            }
        case "FLOAT":
            return precision.map { "FLOAT(\($0))" } ?? "FLOAT"
        default:
            return dataType
        }
    }

    public func tableStatus(of table: String, in database: String) async throws -> TableStatus {
        let owner = dialect.stringLiteral(database)
        let name = dialect.stringLiteral(table)
        let rows = try await strings(
            """
            SELECT t.num_rows, t.avg_row_len, o.created, o.last_ddl_time, c.comments, o.object_type
            FROM all_objects o
            LEFT JOIN all_tables t ON t.owner = o.owner AND t.table_name = o.object_name
            LEFT JOIN all_tab_comments c ON c.owner = o.owner AND c.table_name = o.object_name
            WHERE o.owner = \(owner) AND o.object_name = \(name) AND o.object_type IN ('TABLE', 'VIEW')
            """)
        guard let row = rows.first else { throw DatabaseError(.query, "Table \(table) not found.") }
        var status = TableStatus(
            estimatedRows: row[0].flatMap { Int($0) }, engine: row[5] == "VIEW" ? "VIEW" : "HEAP",
            createdAt: row[2], updatedAt: row[3], comment: row[4])
        if let sizes = try? await segmentBytes(of: table, in: database) {
            status.dataBytes = sizes.data
            status.indexBytes = sizes.index
        }
        return status
    }

    /// Table and index segment sizes (USER_SEGMENTS for the session's own schema, DBA_SEGMENTS when readable).
    private func segmentBytes(of table: String, in database: String) async throws -> (data: Int, index: Int) {
        let name = dialect.stringLiteral(table)
        let owner = dialect.stringLiteral(database)
        let own = try await strings("SELECT USER FROM dual").first?[0] == database
        let segments = own ? "user_segments s" : "dba_segments s"
        let ownerFilter = own ? "" : " AND s.owner = \(owner)"
        let indexOwner = own ? "" : " AND i.owner = \(owner)"
        let row = try await strings(
            """
            SELECT (SELECT NVL(SUM(s.bytes), 0) FROM \(segments)
                    WHERE s.segment_name = \(name) AND s.segment_type LIKE 'TABLE%'\(ownerFilter)),
                   (SELECT NVL(SUM(s.bytes), 0) FROM \(segments)
                    JOIN all_indexes i ON i.index_name = s.segment_name AND i.owner = \(owner)
                    WHERE i.table_name = \(name) AND s.segment_type LIKE 'INDEX%'\(ownerFilter)\(indexOwner))
            FROM dual
            """
        ).first
        return (row?[0].flatMap { Int($0) } ?? 0, row?[1].flatMap { Int($0) } ?? 0)
    }

    public func tableSizes(in database: String) async throws -> [String: Int64] {
        let own = (try? await strings("SELECT USER FROM dual").first?[0]) == database
        let source = own ? "user_segments" : "dba_segments"
        let filter = own ? "" : " AND owner = \(dialect.stringLiteral(database))"
        guard
            let rows = try? await strings(
                """
                SELECT segment_name, SUM(bytes) FROM \(source)
                WHERE segment_type LIKE 'TABLE%'\(filter) GROUP BY segment_name
                """)
        else { return [:] }
        var sizes: [String: Int64] = [:]
        for row in rows {
            if let name = row[0], let bytes = row[1].flatMap({ Int64($0) }) { sizes[name] = bytes }
        }
        return sizes
    }

    /// Indexes with their columns in order; the primary key's index is reported as `PRIMARY`.
    public func indexes(of table: String, in database: String) async throws -> [IndexDetail] {
        let owner = dialect.stringLiteral(database)
        let name = dialect.stringLiteral(table)
        let rows = try await strings(
            """
            SELECT i.index_name, i.index_type, i.uniqueness, c.column_name, i.distinct_keys,
                   CASE WHEN k.constraint_name IS NOT NULL THEN 'Y' ELSE 'N' END
            FROM all_indexes i
            JOIN all_ind_columns c ON c.index_owner = i.owner AND c.index_name = i.index_name
            LEFT JOIN all_constraints k ON k.owner = i.table_owner AND k.table_name = i.table_name
              AND k.constraint_type = 'P' AND k.index_name = i.index_name
            WHERE i.table_owner = \(owner) AND i.table_name = \(name)
            ORDER BY CASE WHEN k.constraint_name IS NOT NULL THEN 0 ELSE 1 END, i.index_name, c.column_position
            """)
        var result: [IndexDetail] = []
        var lastName: String?
        for row in rows {
            let indexName = row[0] ?? ""
            if indexName == lastName, let last = result.indices.last {
                result[last].columns.append(row[3] ?? "")
                continue
            }
            lastName = indexName
            result.append(
                IndexDetail(
                    name: row[5] == "Y" ? "PRIMARY" : indexName, algorithm: row[1] ?? "NORMAL",
                    isUnique: row[2] == "UNIQUE", columns: [row[3] ?? ""], cardinality: row[4].flatMap { Int($0) }))
        }
        return result
    }

    public func foreignKeys(of table: String, in database: String) async throws -> [ForeignKeyDetail] {
        let owner = dialect.stringLiteral(database)
        let name = dialect.stringLiteral(table)
        let rows = try await strings(
            """
            SELECT k.constraint_name, c.column_name, r.owner, r.table_name, rc.column_name, k.delete_rule
            FROM all_constraints k
            JOIN all_constraints r ON r.owner = k.r_owner AND r.constraint_name = k.r_constraint_name
            JOIN all_cons_columns c ON c.owner = k.owner AND c.constraint_name = k.constraint_name
            JOIN all_cons_columns rc ON rc.owner = r.owner AND rc.constraint_name = r.constraint_name
              AND rc.position = c.position
            WHERE k.owner = \(owner) AND k.table_name = \(name) AND k.constraint_type = 'R'
            ORDER BY k.constraint_name, c.position
            """)
        var result: [ForeignKeyDetail] = []
        for row in rows {
            let constraint = row[0] ?? ""
            if let last = result.indices.last, result[last].name == constraint {
                result[last].columns.append(row[1] ?? "")
                result[last].referencedColumns.append(row[4] ?? "")
                continue
            }
            result.append(
                ForeignKeyDetail(
                    name: constraint, columns: [row[1] ?? ""], referencedDatabase: row[2] ?? database,
                    referencedTable: row[3] ?? "", referencedColumns: [row[4] ?? ""], onUpdate: "NO ACTION",
                    onDelete: row[5] ?? "NO ACTION"))
        }
        return result
    }

    /// DBMS_METADATA's DDL without storage clauses.
    public func createStatement(of table: String, in database: String) async throws -> String {
        let owner = dialect.stringLiteral(database)
        let name = dialect.stringLiteral(table)
        if !ddlTransformsSet {
            _ = try? await execute(
                """
                BEGIN
                  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'SEGMENT_ATTRIBUTES', FALSE);
                  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'STORAGE', FALSE);
                  DBMS_METADATA.SET_TRANSFORM_PARAM(DBMS_METADATA.SESSION_TRANSFORM, 'PRETTY', TRUE);
                END;
                """)
            ddlTransformsSet = true
        }
        let kind =
            try await strings(
                """
                SELECT object_type FROM all_objects
                WHERE owner = \(owner) AND object_name = \(name) AND object_type IN ('TABLE', 'VIEW')
                """
            ).first?[0] ?? "TABLE"
        guard
            let ddl = try await strings(
                "SELECT DBMS_METADATA.GET_DDL(\(dialect.stringLiteral(kind)), \(name), \(owner)) FROM dual"
            ).first?[0]
        else { throw DatabaseError(.query, "No CREATE statement for \(table).") }
        return ddl.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func characterSets() async throws -> [CharacterSetInfo] { [] }

    /// Runs a catalog query and returns its cells as text.
    private func strings(_ sql: String) async throws -> [[String?]] {
        guard case .rows(let result) = try await execute(sql) else { return [] }
        return result.rows.map { $0.map(\.displayText) }
    }
}

/// Oracle statement text handling: splitting scripts, classifying statements and inlining parameters.
enum OracleSQL {
    struct Prepared {
        var text: String
        var isQuery: Bool
        var isPLSQL: Bool
        var changesSchema: Bool
    }

    static func split(_ script: String) -> [String] {
        StatementSplitter(syntax: .oracle).split(script).map(\.text)
    }

    /// Strips the terminator (`;` for SQL; a trailing `/` line for PL/SQL, which keeps its `END;`) and classifies
    /// the statement by its first keywords.
    static func prepare(_ sql: String) -> Prepared {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("/"), let range = text.range(of: #"\n\s*/$"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = keywords(text, count: 6)
        let isPLSQL = isPLSQLBlock(words)
        if !StatementSplitter.isOraclePLSQL(words) {
            while text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        }
        let first = words.first ?? ""
        let isQuery = first == "SELECT" || first == "WITH"
        let changesSchema = first == "ALTER" && words.count > 3 && words[1] == "SESSION" && words[2] == "SET"
        return Prepared(text: text, isQuery: isQuery, isPLSQL: isPLSQL, changesSchema: changesSchema)
    }

    /// Statements ending in `END;` that must keep their semicolons: anonymous blocks, CALL and stored code.
    static func isPLSQLBlock(_ words: [String]) -> Bool {
        words.first == "CALL" || StatementSplitter.isOraclePLSQL(words)
    }

    /// The first `count` words, uppercased, skipping leading comments and parentheses.
    static func keywords(_ sql: String, count: Int) -> [String] {
        var words: [String] = []
        var current = ""
        var scalars = sql.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        var previous: Unicode.Scalar?
        func flush() {
            if !current.isEmpty {
                words.append(current.uppercased())
                current = ""
            }
        }
        while words.count < count, let c = pending ?? scalars.next() {
            pending = nil
            if c == "-" && previous == "-" {
                current = ""
                while let next = scalars.next(), next != "\n" {}
            } else if c == "*" && previous == "/" {
                var last: Unicode.Scalar?
                while let next = scalars.next() {
                    if last == "*" && next == "/" { break }
                    last = next
                }
            } else if CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$" || c == "#" {
                current.unicodeScalars.append(c)
            } else {
                flush()
            }
            previous = c
        }
        flush()
        return Array(words.prefix(count))
    }

    /// Writes `:n` parameters in as literals (outside quotes and comments), in one left-to-right pass so a value
    /// containing `:1` is never re-substituted.
    static func inline(_ statement: ParameterizedStatement, dialect: OracleDialect) -> String {
        let chars = Array(statement.sql)
        var output = ""
        var index = 0
        var quote: Character?
        while index < chars.count {
            let c = chars[index]
            if let q = quote {
                output.append(c)
                if c == q { quote = nil }
                index += 1
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                output.append(c)
                index += 1
                continue
            }
            if c == ":", index + 1 < chars.count, chars[index + 1].isNumber {
                var end = index + 1
                while end < chars.count, chars[end].isNumber { end += 1 }
                if let number = Int(String(chars[(index + 1)..<end])), number >= 1,
                    number <= statement.parameters.count
                {
                    switch statement.parameters[number - 1] {
                    case .text(let value): output += dialect.stringLiteral(value)
                    case .null: output += "NULL"
                    }
                    index = end
                    continue
                }
            }
            output.append(c)
            index += 1
        }
        return output
    }
}
