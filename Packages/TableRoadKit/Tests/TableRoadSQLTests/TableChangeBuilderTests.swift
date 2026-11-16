import TableRoadCore
import Testing

@testable import TableRoadSQL

@Suite struct TableChangeBuilderTests {
    let builder = TableChangeBuilder(database: "shop", table: "orders", dialect: MySQLDialect(flavor: .mysql))
    let key = RowKey([("id", "42")])

    @Test func update() {
        let change = RowChange.update(
            key: key, set: [ColumnEdit(column: "status", edit: .text("paid")), ColumnEdit(column: "note", edit: .null)])
        let statement = builder.statement(for: change)
        #expect(statement.sql == "UPDATE `shop`.`orders` SET `status` = ?, `note` = NULL WHERE `id` = ? LIMIT 1")
        #expect(statement.parameters == [.text("paid"), .text("42")])
        #expect(
            builder.previewSQL(for: change)
                == "UPDATE `shop`.`orders` SET `status` = 'paid', `note` = NULL WHERE `id` = '42' LIMIT 1;")
    }

    @Test func compositeKeyDelete() {
        let change = RowChange.delete(key: RowKey([("order_id", "1"), ("line", "3")]))
        #expect(
            builder.statement(for: change).sql
                == "DELETE FROM `shop`.`orders` WHERE `order_id` = ? AND `line` = ? LIMIT 1")
    }

    @Test func insertSkipsDefaults() {
        let change = RowChange.insert([
            ColumnEdit(column: "id", edit: .defaultValue), ColumnEdit(column: "total", edit: .text("9.99")),
            ColumnEdit(column: "note", edit: .null),
        ])
        let statement = builder.statement(for: change)
        #expect(statement.sql == "INSERT INTO `shop`.`orders` (`total`, `note`) VALUES (?, NULL)")
        #expect(statement.parameters == [.text("9.99")])
        #expect(
            builder.statement(for: .insert([ColumnEdit(column: "id", edit: .defaultValue)])).sql
                == "INSERT INTO `shop`.`orders` () VALUES ()")
    }

    @Test func previewDoesNotSubstituteInsideIdentifiers() {
        let weird = TableChangeBuilder(database: "d", table: "what?", dialect: MySQLDialect(flavor: .mysql))
        let change = RowChange.update(key: RowKey([("id", "1")]), set: [ColumnEdit(column: "a?", edit: .text("x?"))])
        #expect(weird.previewSQL(for: change) == "UPDATE `d`.`what?` SET `a?` = 'x?' WHERE `id` = '1' LIMIT 1;")
    }
}
