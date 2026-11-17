import Darwin
import Foundation
import TableRoadCore
import TableRoadMySQL
import TableRoadSQL
import Testing

@testable import TableRoadTransfer

/// Docker servers from docker/compose.yml (root account: these tests create and drop databases).
enum Server: String, CaseIterable, CustomTestStringConvertible {
    case mysql, mariadb
    var port: Int { self == .mysql ? 13306 : 13307 }
    var testDescription: String { rawValue }

    var config: MySQLConnectConfig {
        MySQLConnectConfig(
            host: "127.0.0.1", port: port, username: "root", password: "tableroad", database: "tableroad",
            tls: .prefer)
    }

    @Sendable func connect() async throws -> MySQLSession { try await MySQLSession.connect(config) }

    static let available: Bool = allCases.allSatisfy { server in
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(server.port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

@Suite(.enabled(if: Server.available, "Start docker/compose.yml to run transfer integration tests"), .serialized)
struct TransferIntegrationTests {
    func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tableroad-transfer-\(UUID().uuidString)-\(name)")
    }

    func checksum(_ session: MySQLSession, _ qualified: String) async throws -> String {
        guard case .rows(let result) = try await session.execute("CHECKSUM TABLE \(qualified)") else { return "" }
        return result.rows.first?[1].displayText ?? ""
    }

    @Test(arguments: Server.allCases, [false, true])
    func sqlDumpRoundTrip(server: Server, gzip: Bool) async throws {
        let tables = ["customers", "orders", "inspector_demo"]
        let file = temp(gzip ? "dump.sql.gz" : "dump.sql")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await TableExport.run(
            items: tables.map { ExportItem(database: "tableroad", table: $0) }, kind: .sql(gzip: gzip),
            destination: file, connect: server.connect)
        #expect(result.rows == 5_000 + 10_000 + 2)

        let admin = try await server.connect()
        let target = "tr_import_\(UInt32.random(in: 0...UInt32.max))"
        try await admin.run("CREATE DATABASE `\(target)`")
        do {
            let imported = try await SQLDumpImport.run(
                file: file, database: target, stopOnError: true, connect: server.connect)
            #expect(imported.failures.isEmpty, "\(imported.failures.first?.message ?? "")")
            for table in tables {
                let original = try await checksum(admin, "`tableroad`.`\(table)`")
                let copy = try await checksum(admin, "`\(target)`.`\(table)`")
                #expect(original == copy, "\(table) differs after the round trip")
            }
        } catch {
            Issue.record(error)
        }
        try await admin.run("DROP DATABASE `\(target)`")
        await admin.close()
    }

    @Test(arguments: Server.allCases)
    func compositeKeyPagingAndCSVFolder(server: Server) async throws {
        let admin = try await server.connect()
        let database = "tr_ck_\(UInt32.random(in: 0...UInt32.max))"
        try await admin.run("CREATE DATABASE `\(database)`")
        try await admin.run(
            "CREATE TABLE `\(database)`.ck (a INT, b INT, v VARCHAR(20), g INT AS (a + b) VIRTUAL, "
                + "t DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (a, b))")
        // 3 × 1700 rows: batches of 2,000 split inside runs of equal `a`.
        try await admin.run(
            "INSERT INTO `\(database)`.ck (a, b, v) SELECT a.n, b.n, CONCAT('v', a.n, '-', b.n) FROM "
                + "(SELECT 1 n UNION SELECT 2 UNION SELECT 3) a, "
                + "(SELECT d1.d + d2.d * 10 + d3.d * 100 + d4.d * 1000 n FROM "
                + "(SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d1, "
                + "(SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d2, "
                + "(SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d3, "
                + "(SELECT 0 d UNION SELECT 1) d4 WHERE d1.d + d2.d * 10 + d3.d * 100 + d4.d * 1000 < 1700) b")
        let folder = temp("csv")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let result = try await TableExport.run(
                items: [
                    ExportItem(database: database, table: "ck", columns: ["v"]),  // key columns not exported
                    ExportItem(database: "tableroad", table: "customers"),
                ],
                kind: .csv(CSVOptions()), destination: folder, connect: server.connect)
            #expect(result.files.count == 2)
            let ck = try String(contentsOf: folder.appending(path: "\(database).ck.csv"), encoding: .utf8)
            let lines = ck.split(separator: "\n")
            #expect(lines.count == 1 + 5_100)
            #expect(lines.first == "v")
            #expect(Set(lines.dropFirst()).count == 5_100, "no row exported twice")
            let customers = try String(contentsOf: folder.appending(path: "tableroad.customers.csv"), encoding: .utf8)
            #expect(customers.split(separator: "\n").count == 5_001)

            // SQL leaves out the generated column `g` but keeps `t` (MySQL marks it DEFAULT_GENERATED).
            let dump = temp("ck.sql")
            defer { try? FileManager.default.removeItem(at: dump) }
            _ = try await TableExport.run(
                items: [ExportItem(database: database, table: "ck")], kind: .sql(gzip: false), destination: dump,
                connect: server.connect)
            let sql = try String(contentsOf: dump, encoding: .utf8)
            #expect(sql.contains("INSERT INTO `ck` (`a`, `b`, `v`, `t`) VALUES"))
        } catch {
            Issue.record(error)
        }
        try await admin.run("DROP DATABASE `\(database)`")
        await admin.close()
    }

    @Test(arguments: Server.allCases)
    func jsonAndExcel(server: Server) async throws {
        let json = temp("orders.json")
        let excel = temp("export.xlsx")
        defer {
            try? FileManager.default.removeItem(at: json)
            try? FileManager.default.removeItem(at: excel)
        }
        _ = try await TableExport.run(
            items: [ExportItem(database: "tableroad", table: "orders")], kind: .json, destination: json,
            connect: server.connect)
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]]
        #expect(rows?.count == 10_000)
        #expect(rows?.first?["total"] is NSNumber)

        let result = try await TableExport.run(
            items: [
                ExportItem(database: "tableroad", table: "orders"),
                ExportItem(database: "tableroad", table: "inspector_demo"),
            ], kind: .excel, destination: excel, connect: server.connect)
        #expect(result.rows == 10_002)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", excel.path]
        unzip.standardOutput = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
    }

    @Test(arguments: Server.allCases)
    func importErrorsStopOrContinue(server: Server) async throws {
        let admin = try await server.connect()
        let database = "tr_err_\(UInt32.random(in: 0...UInt32.max))"
        try await admin.run("CREATE DATABASE `\(database)`")
        let file = temp("bad.sql")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(
            """
            CREATE TABLE t (id INT PRIMARY KEY);
            INSERT INTO t VALUES (1);
            INSERT INTO missing VALUES (2);
            INSERT INTO t VALUES (3);
            """.utf8
        ).write(to: file)

        let stopped = try await SQLDumpImport.run(
            file: file, database: database, stopOnError: true, connect: server.connect)
        #expect(stopped.stoppedOnError)
        #expect(stopped.failures.first?.statement == 3)
        try await admin.run("DROP TABLE `\(database)`.t")

        let continued = try await SQLDumpImport.run(
            file: file, database: database, stopOnError: false, connect: server.connect)
        #expect(!continued.stoppedOnError)
        #expect(continued.statements == 4)
        #expect(continued.failures.count == 1)
        guard case .rows(let count) = try await admin.execute("SELECT COUNT(*) FROM `\(database)`.t") else { return }
        #expect(count.rows.first?.first?.displayText == "2")
        try await admin.run("DROP DATABASE `\(database)`")
        await admin.close()
    }
}

struct UTF8CarryTests {
    @Test func splitCharacterIsCarried() throws {
        let bytes = Data("abé😀".utf8)  // é = 2 bytes, 😀 = 4 bytes
        var carry = Data()
        // Cut inside the emoji.
        let first = try SQLDumpImport.decodeUTF8(bytes.prefix(bytes.count - 2), carry: &carry)
        #expect(first == "abé")
        #expect(carry.count == 2)
        let second = try SQLDumpImport.decodeUTF8(carry + bytes.suffix(2), carry: &carry)
        #expect(second == "😀")
        #expect(carry.isEmpty)
    }
}
