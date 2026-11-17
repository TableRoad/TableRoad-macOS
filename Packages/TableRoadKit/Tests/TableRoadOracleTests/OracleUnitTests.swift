import Foundation
import TableRoadCore
import TableRoadSQL
import Testing

@testable import TableRoadOracle

struct OracleNumberTests {
    @Test(
        arguments: [
            ("0", [0x80]), ("1", [0xC1, 0x02]), ("5", [0xC1, 0x06]), ("100", [0xC2, 0x02]), ("-5", [0x3E, 0x60, 0x66]),
            ("12.5", [0xC1, 0x0D, 0x33]), ("0.05", [0xC0, 0x06]), ("-1", [0x3E, 0x64, 0x66]),
        ] as [(String, [UInt8])])
    func knownEncodings(text: String, bytes: [UInt8]) {
        #expect(OracleNumber.encode(text) == bytes)
        #expect(OracleNumber.decode(bytes) == text)
    }

    @Test(arguments: [
        "0", "1", "-1", "7", "10", "99", "100", "101", "12345.6789", "-12345.6789", "0.000123", "-0.000123",
        "123456789012345678901234567890", "-98765432109876543210.0123456789", "0.1", "1000000", "3.14159265358979",
        "1" + String(repeating: "0", count: 125), "0." + String(repeating: "0", count: 100) + "1",
    ])
    func roundTrips(text: String) throws {
        let bytes = try #require(OracleNumber.encode(text))
        #expect(OracleNumber.decode(bytes) == text)
    }

    @Test func normalisesInput() {
        #expect(OracleNumber.encode("1.50").flatMap { OracleNumber.decode($0) } == "1.5")
        #expect(OracleNumber.encode("+007").flatMap { OracleNumber.decode($0) } == "7")
        #expect(OracleNumber.encode("12e3").flatMap { OracleNumber.decode($0) } == "12000")
        #expect(OracleNumber.encode("-2.5E-3").flatMap { OracleNumber.decode($0) } == "-0.0025")
        #expect(OracleNumber.encode("abc") == nil)
        #expect(OracleNumber.encode("1e200") == nil)
    }

    @Test func negativeNumbersSortBelowPositive() throws {
        // Oracle's byte order matches numeric order.
        let values = ["-100", "-1.5", "-1", "0", "0.5", "1", "100"]
        let encoded = try values.map { try #require(OracleNumber.encode($0)) }
        #expect(encoded == encoded.sorted { $0.lexicographicallyPrecedes($1) })
    }
}

struct OracleValueTests {
    @Test func timestamps() {
        let date: [UInt8] = [120, 124, 2, 29, 14, 15, 16]
        #expect(OracleValues.timestamp(date, withZone: false, showFraction: false) == "2024-02-29 13:14:15")
        let fraction: [UInt8] = date + [0x07, 0x5B, 0xCD, 0x15]  // 123456789 ns
        #expect(
            OracleValues.timestamp(fraction, withZone: false, showFraction: true) == "2024-02-29 13:14:15.123456789")
        // 07:44:15 UTC at +05:30 is 13:14:15 local.
        let zoned: [UInt8] = [120, 124, 2, 29, 8, 45, 16, 0, 0, 0, 0, 25, 90]
        #expect(OracleValues.timestamp(zoned, withZone: true, showFraction: true) == "2024-02-29 13:14:15 +05:30")
    }

    @Test func intervalsAndFloats() {
        #expect(OracleValues.intervalYM([0x80, 0, 0, 1, 62]) == "+1-02")
        #expect(OracleValues.intervalYM([0x7F, 0xFF, 0xFF, 0xFF, 58]) == "-1-02")
        #expect(OracleValues.intervalDS([0x80, 0, 0, 3, 64, 65, 66, 0xAF, 0x07, 0x2F, 0x40]) == "+3 04:05:06.789")
        #expect(OracleValues.binaryDouble([0xC0, 0x00, 0, 0, 0, 0, 0, 0]) == 2.0)
        #expect(OracleValues.binaryDouble([0x3F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == -2.0)
        #expect(OracleValues.binaryFloat([0xBF, 0xC0, 0, 0]) == 1.5)
    }

    @Test func rowids() {
        #expect(OracleValues.rowid(rba: 0x1234, partition: 7, block: 0x89, slot: 3) == "AAABI0AAHAAAACJAAD")
        #expect(OracleValues.rowid(rba: 0, partition: 0, block: 0, slot: 0) == nil)
    }
}

struct OracleSQLTests {
    @Test func preparesStatements() {
        let select = OracleSQL.prepare("  SELECT 1 FROM dual;  ")
        #expect(select.text == "SELECT 1 FROM dual")
        #expect(select.isQuery)
        #expect(OracleSQL.prepare("(SELECT 1 FROM dual)").isQuery)
        #expect(OracleSQL.prepare("-- note\nWITH a AS (SELECT 1 x FROM dual) SELECT * FROM a").isQuery)
        let block = OracleSQL.prepare("BEGIN NULL; END;\n/")
        #expect(block.text == "BEGIN NULL; END;")
        #expect(block.isPLSQL)
        #expect(OracleSQL.prepare("create or replace procedure p as begin null; end;").text.hasSuffix("end;"))
        #expect(!OracleSQL.prepare("CREATE OR REPLACE TYPE t AS OBJECT (a NUMBER);").text.hasSuffix(";"))
        #expect(OracleSQL.prepare("ALTER SESSION SET CURRENT_SCHEMA = x").changesSchema)
    }

    @Test func inlinesParameters() {
        let statement = ParameterizedStatement(
            sql: "UPDATE \"T\" SET \"A\" = :1, \"B\" = :2 WHERE \"ID\" = :3 AND \"C\" = ':1'",
            parameters: [.text("it's :2"), .null, .text("10")])
        #expect(
            OracleSQL.inline(statement, dialect: OracleDialect())
                == "UPDATE \"T\" SET \"A\" = 'it''s :2', \"B\" = NULL WHERE \"ID\" = '10' AND \"C\" = ':1'")
    }

    @Test func dialect() {
        let dialect = OracleDialect()
        #expect(
            dialect.pagingClause(limit: 10, offset: 20, ordered: false) == " OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY")
        #expect(dialect.quoteIdentifier("a\"b") == "\"a\"\"b\"")
        #expect(dialect.bytesLiteral(Data([0xAB, 0x01])) == "HEXTORAW('AB01')")
        #expect(!dialect.supportsWriteLimit)
        let builder = TableChangeBuilder(database: "S", table: "T", dialect: dialect)
        let delete = builder.statement(for: .delete(key: RowKey([("ID", "1")])))
        #expect(delete.sql == "DELETE FROM \"S\".\"T\" WHERE \"ID\" = :1")
    }

    @Test func columnTypes() {
        #expect(
            OracleSession.columnType(
                dataType: "NUMBER", length: "22", precision: nil, scale: "0", charUsed: nil, charLength: nil)
                == "NUMBER(*,0)")
        #expect(
            OracleSession.columnType(
                dataType: "VARCHAR2", length: "400", precision: nil, scale: nil, charUsed: "C", charLength: "100")
                == "VARCHAR2(100 CHAR)")
        #expect(
            OracleSession.columnType(
                dataType: "NVARCHAR2", length: "100", precision: nil, scale: nil, charUsed: "C", charLength: "50")
                == "NVARCHAR2(50)")
    }
}
