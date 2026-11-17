import Foundation
import TableRoadCore
import Testing

@testable import TableRoadSQL

struct ResultExportTests {
    let exporter = ResultExporter(
        columns: ["id", "name", "note"],
        rows: [
            [.int(1), .text("Ann, \"A\""), .null],
            [.int(2), .text("Line1\nLine2"), .text("")],
        ],
        table: "people", dialect: MySQLDialect(flavor: .mysql))

    @Test func csvQuotesWhenNeeded() {
        #expect(
            exporter.render(.csv) == "id,name,note\n1,\"Ann, \"\"A\"\"\",NULL\n2,\"Line1\nLine2\",")
    }

    @Test func tsvFlattensLineBreaksAndCanSkipHeader() {
        #expect(exporter.render(.tsv, includeHeader: false) == "1\tAnn, \"A\"\tNULL\n2\tLine1 Line2\t")
    }

    @Test func sqlInsertEscapesAndKeepsTypes() {
        let sql = exporter.render(.sqlInsert)
        #expect(sql.hasPrefix("INSERT INTO `people` (`id`, `name`, `note`) VALUES (1, 'Ann, \"A\"', NULL);"))
        #expect(sql.contains("VALUES (2, 'Line1\nLine2', '');"))  // a literal line break is valid inside quotes
        #expect(exporter.sqlLiteral(.bytes(Data([0xDE, 0xAD]))) == "X'DEAD'")
        #expect(exporter.sqlLiteral(.bool(true)) == "1")
    }

    @Test func jsonKeepsNullsAndNumbers() throws {
        let data = try #require(exporter.render(.json).data(using: .utf8))
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.count == 2)
        #expect(objects[0]["id"] as? Int == 1)
        #expect(objects[0]["note"] is NSNull)
        #expect(objects[1]["name"] as? String == "Line1\nLine2")
    }

    @Test func markdownEscapesPipes() {
        let table = ResultExporter(
            columns: ["a"], rows: [[.text("x|y")]], dialect: MySQLDialect(flavor: .mysql)
        ).render(.markdown)
        #expect(table == "| a |\n| --- |\n| x\\|y |")
    }
}
