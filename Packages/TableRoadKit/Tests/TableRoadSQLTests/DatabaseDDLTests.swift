import Testing

@testable import TableRoadSQL

struct DatabaseDDLTests {
    let dialect = MySQLDialect(flavor: .mysql)

    @Test func createQuotesTheNameAndAddsOptions() throws {
        #expect(try dialect.createDatabaseSQL("shop", characterSet: nil, collation: nil) == "CREATE DATABASE `shop`")
        #expect(
            try dialect.createDatabaseSQL(" my`db ", characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci")
                == "CREATE DATABASE `my``db` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci")
    }

    @Test func createRejectsBadInput() {
        #expect(throws: DDLError.emptyName) { try dialect.createDatabaseSQL("  ", characterSet: nil, collation: nil) }
        #expect(throws: DDLError.nameTooLong) {
            try dialect.createDatabaseSQL(String(repeating: "a", count: 65), characterSet: nil, collation: nil)
        }
        #expect(throws: DDLError.invalidOption("utf8; DROP")) {
            try dialect.createDatabaseSQL("x", characterSet: "utf8; DROP", collation: nil)
        }
    }

    @Test func dropQuotesTheName() {
        #expect(dialect.dropDatabaseSQL("a`b") == "DROP DATABASE `a``b`")
    }
}
