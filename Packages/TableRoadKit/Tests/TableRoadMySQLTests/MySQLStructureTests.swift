import Foundation
import TableRoadCore
import Testing

@testable import TableRoadMySQL

@Suite(.enabled(if: TestServer.available, "Start docker/compose.yml to run MySQL integration tests"))
struct MySQLStructureTests {
    @Test(arguments: TestServer.allCases)
    func tableStatusReportsSizesAndEstimate(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let status = try await session.tableStatus(of: "orders", in: "tableroad")
        #expect(status.engine == "InnoDB")
        #expect((status.dataBytes ?? 0) > 0)
        #expect((status.indexBytes ?? 0) > 0)
        #expect(status.totalBytes == (status.dataBytes ?? 0) + (status.indexBytes ?? 0))
        // Only check it's present: InnoDB's estimate is approximate, and MariaDB reports 0 for the freshly seeded
        // 10,000-row table until statistics are recalculated. (Why the browser never trusts small estimates.)
        #expect(status.estimatedRows != nil)
        #expect(try await session.tableStatus(of: "inspector_demo", in: "tableroad").autoIncrement != nil)
    }

    @Test(arguments: TestServer.allCases)
    func statusQueryLeavesStatsExpiryUnchanged(server: TestServer) async throws {
        guard server == .mysql else { return }
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        _ = try await session.tableStatus(of: "orders", in: "tableroad")
        guard case .rows(let result) = try await session.execute("SELECT @@SESSION.information_schema_stats_expiry")
        else {
            Issue.record("expected rows")
            return
        }
        #expect(result.rows.first?.first?.displayText == "86400")
    }

    @Test(arguments: TestServer.allCases)
    func missingTableStatusThrows(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        await #expect(throws: DatabaseError.self) {
            _ = try await session.tableStatus(of: "no_such_table", in: "tableroad")
        }
    }

    @Test(arguments: TestServer.allCases)
    func indexesGroupColumnsInOrder(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let orders = try await session.indexes(of: "orders", in: "tableroad")
        #expect(orders.map(\.name) == ["PRIMARY", "orders_customer_idx"])
        #expect(orders[0].isUnique && orders[0].isPrimary && orders[0].columns == ["id"])
        #expect(!orders[1].isUnique && orders[1].columns == ["customer_id"])
        #expect(orders[1].algorithm == "BTREE")

        let customers = try await session.indexes(of: "customers", in: "tableroad")
        #expect(customers.first { $0.name == "email" }?.isUnique == true)
    }

    @Test(arguments: TestServer.allCases)
    func foreignKeysResolveReferences(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let keys = try await session.foreignKeys(of: "orders", in: "tableroad")
        #expect(keys.count == 1)
        #expect(keys.first?.name == "orders_customer_fk")
        #expect(keys.first?.columns == ["customer_id"])
        #expect(keys.first?.referencedTable == "customers")
        #expect(keys.first?.referencedColumns == ["id"])
        #expect(try await session.foreignKeys(of: "customers", in: "tableroad").isEmpty)
    }

    /// MariaDB hides REFERENTIAL_CONSTRAINTS from SELECT-only users (a common read-only setup); the keys must still
    /// be found, with their rules taken from the DDL.
    @Test(arguments: TestServer.allCases)
    func foreignKeysVisibleToSelectOnlyUsers(server: TestServer) async throws {
        let root = try await MySQLSession.connect(server.rootConfig)
        _ = try await root.execute("CREATE USER IF NOT EXISTS 'tableroad_ro'@'%' IDENTIFIED BY 'tableroad'")
        _ = try await root.execute("GRANT SELECT ON tableroad.* TO 'tableroad_ro'@'%'")
        await root.close()

        let session = try await MySQLSession.connect(server.config(username: "tableroad_ro"))
        defer { Task { await session.close() } }
        let keys = try await session.foreignKeys(of: "orders", in: "tableroad")
        #expect(keys.map(\.name) == ["orders_customer_fk"])
        #expect(keys.first?.referencedTable == "customers")
        // The default rule: MySQL 8 reports it as NO ACTION, MariaDB (from the DDL) as RESTRICT.
        #expect(["RESTRICT", "NO ACTION"].contains(keys.first?.onDelete ?? ""))
    }

    @Test func foreignKeyRulesParsedFromCreateStatement() {
        let ddl = """
            CREATE TABLE `crm_companies` (
              `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
              KEY `crm_companies_parent_foreign` (`parent_id`),
              CONSTRAINT `crm_companies_parent_foreign` FOREIGN KEY (`parent_id`) REFERENCES `crm_companies` (`id`) ON DELETE SET NULL,
              CONSTRAINT `odd``name` FOREIGN KEY (`a`, `b`) REFERENCES `other` (`x`, `y`) ON DELETE CASCADE ON UPDATE NO ACTION,
              CONSTRAINT `plain` FOREIGN KEY (`c`) REFERENCES `third` (`id`)
            ) ENGINE=InnoDB
            """
        let rules = MySQLSession.foreignKeyRules(inCreateStatement: ddl)
        #expect(rules.count == 3)
        #expect(rules["crm_companies_parent_foreign"]?.onDelete == "SET NULL")
        #expect(rules["crm_companies_parent_foreign"]?.onUpdate == "RESTRICT")
        #expect(rules["odd`name"]?.onDelete == "CASCADE")
        #expect(rules["odd`name"]?.onUpdate == "NO ACTION")
        #expect(rules["plain"]?.onDelete == "RESTRICT")
    }

    @Test(arguments: TestServer.allCases)
    func columnsIncludeCharsetAndCollation(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let columns = try await session.columns(of: "customers", in: "tableroad")
        let email = try #require(columns.first { $0.name == "email" })
        #expect(email.characterSet != nil && email.collation != nil)
        #expect(columns.first { $0.name == "id" }?.characterSet == nil)
    }

    @Test(arguments: TestServer.allCases)
    func createStatement(server: TestServer) async throws {
        let session = try await MySQLSession.connect(server.config())
        defer { Task { await session.close() } }
        let ddl = try await session.createStatement(of: "orders", in: "tableroad")
        #expect(ddl.hasPrefix("CREATE TABLE `orders`"))
        #expect(ddl.contains("orders_customer_fk"))
    }
}
