import Testing

@testable import TableRoadSQL

@Suite struct ColumnFilterTests {
    let dialect = MySQLDialect(flavor: .mysql)

    @Test(arguments: [
        (ColumnFilter.Operator.equals, "5", "`total` = '5'"),
        (.notEquals, "a", "`total` <> 'a'"),
        (.greaterThanOrEqual, "10", "`total` >= '10'"),
        (.contains, "50%_off!", "`total` LIKE '%50!%!_off!!%' ESCAPE '!'"),
        (.beginsWith, "ab", "`total` LIKE 'ab%' ESCAPE '!'"),
        (.endsWith, "ab", "`total` LIKE '%ab' ESCAPE '!'"),
        (.isIn, "1, 2 ,3", "`total` IN ('1', '2', '3')"),
        (.notIn, "x", "`total` NOT IN ('x')"),
        (.isNull, "", "`total` IS NULL"),
        (.isNotNull, "ignored", "`total` IS NOT NULL"),
        (.isEmpty, "", "`total` = ''"),
    ])
    func rendersOperators(op: ColumnFilter.Operator, value: String, expected: String) {
        #expect(ColumnFilter(column: "total", op: op, value: value).condition(dialect) == expected)
    }

    @Test func valuesCannotInject() {
        let filter = ColumnFilter(column: "name", op: .equals, value: "x' OR '1'='1")
        #expect(filter.condition(dialect) == "`name` = 'x'' OR ''1''=''1'")
        let weirdColumn = ColumnFilter(column: "na`me", op: .isNull)
        #expect(weirdColumn.condition(dialect) == "`na``me` IS NULL")
    }

    @Test func inactiveFiltersAreSkipped() {
        #expect(ColumnFilter(column: "a", op: .contains, value: "").condition(dialect) == nil)
        #expect(ColumnFilter(column: "a", op: .isNull, isEnabled: false).condition(dialect) == nil)
        #expect(ColumnFilter(column: "a", op: .isIn, value: " , ").condition(dialect) == nil)
        #expect(ColumnFilter(column: "", op: .rawSQL, value: "  ").condition(dialect) == nil)
        // "= empty string" is a legitimate filter.
        #expect(ColumnFilter(column: "a", op: .equals, value: "").condition(dialect) == "`a` = ''")
    }

    @Test func rawSQLIsParenthesised() {
        #expect(ColumnFilter(column: "", op: .rawSQL, value: "a = 1 OR b = 2").condition(dialect) == "(a = 1 OR b = 2)")
    }

    @Test func filterSetCombinesAndPages() {
        var set = FilterSet(filters: [
            ColumnFilter(column: "status", op: .equals, value: "paid"),
            ColumnFilter(column: "total", op: .greaterThan, value: "100"),
            ColumnFilter(column: "x", op: .contains, value: ""),
        ])
        #expect(set.activeCount == 2)
        #expect(set.whereClause(dialect) == " WHERE `status` = 'paid' AND `total` > '100'")
        set.matchAll = false
        #expect(set.whereClause(dialect) == " WHERE `status` = 'paid' OR `total` > '100'")
        let query = PageQuery(database: "shop", table: "orders", filters: set, limit: 10)
        #expect(
            query.selectSQL(dialect)
                == "SELECT * FROM `shop`.`orders` WHERE `status` = 'paid' OR `total` > '100' LIMIT 10 OFFSET 0")
        #expect(
            query.countSQL(dialect) == "SELECT COUNT(*) FROM `shop`.`orders` WHERE `status` = 'paid' OR `total` > '100'"
        )
        #expect(FilterSet().whereClause(dialect) == "")
    }
}
