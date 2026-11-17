import Testing

@testable import TableRoadSQL

@Suite struct StatementSplitterTests {
    let mysql = StatementSplitter(syntax: .mysql)

    @Test func splitsSimpleStatements() {
        #expect(mysql.split("SELECT 1; SELECT 2;\n  SELECT 3").map(\.text) == ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    @Test func ignoresDelimitersInsideQuotesAndComments() {
        let script = """
            SELECT 'a;b', "c;d", `e;f` FROM t; -- trailing; comment
            # hash; comment
            SELECT 'it''s; fine', 'back\\';slash' /* block; comment */ FROM u;
            """
        let texts = mysql.split(script).map(\.text)
        #expect(texts.count == 2)
        #expect(texts[0] == "SELECT 'a;b', \"c;d\", `e;f` FROM t")
        // Comments after a delimiter lead into the next statement; they're harmless to send.
        #expect(texts[1].hasPrefix("-- trailing; comment\n# hash; comment\nSELECT 'it''s; fine'"))
        #expect(texts[1].hasSuffix("/* block; comment */ FROM u"))
    }

    @Test func keepsCQLBatchesTogether() {
        let cql = StatementSplitter(syntax: .cql)
        let script = """
            // a; comment
            BEGIN UNLOGGED BATCH
              INSERT INTO t (a) VALUES (1);
              INSERT INTO t (a) VALUES ('x;y');
            APPLY BATCH;
            /* note */ begin batch insert into t (a) values (2); apply batch;
            SELECT * FROM t; CREATE FUNCTION f(a int) RETURNS NULL ON NULL INPUT RETURNS int LANGUAGE java AS $$ return a; $$
            """
        let texts = cql.split(script).map(\.text)
        #expect(texts.count == 4)
        #expect(texts[0].hasPrefix("// a; comment\nBEGIN UNLOGGED BATCH"))
        #expect(texts[0].hasSuffix("APPLY BATCH"))
        #expect(texts[1] == "/* note */ begin batch insert into t (a) values (2); apply batch")
        #expect(texts[3].hasSuffix("$$ return a; $$"))
        var streaming = StreamingStatementSplitter(syntax: .cql)
        #expect(streaming.feed("BEGIN BATCH INSERT INTO t (a) VALUES (1);").isEmpty)
        #expect(
            streaming.feed(" APPLY BATCH; SELECT 1;") == [
                "BEGIN BATCH INSERT INTO t (a) VALUES (1); APPLY BATCH", "SELECT 1",
            ])
    }

    @Test func dropsCommentOnlyFragments() {
        #expect(mysql.split("SELECT 1; -- just a note\n").map(\.text) == ["SELECT 1"])
        #expect(mysql.split("/* nothing */ ;; ").isEmpty)
    }

    @Test func handlesDelimiterCommand() {
        let script = """
            DELIMITER $$
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$
            DELIMITER ;
            CALL p();
            """
        #expect(mysql.split(script).map(\.text) == ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "CALL p()"])
    }

    @Test func postgresDollarQuoting() {
        let pg = StatementSplitter(syntax: .postgres)
        let script = "CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql; SELECT 2"
        #expect(pg.split(script).count == 2)
    }

    @Test func runsHighlightedTextOrStatementAtCaret() {
        let script = "SELECT 1;\nSELECT 2;\nSELECT 3"
        // Selection of part of one statement runs exactly what's highlighted.
        #expect(mysql.scriptToRun(in: script, selection: 10..<18) == "SELECT 2")
        // Selection spanning two statements runs both (the editor splits it again).
        #expect(mysql.scriptToRun(in: script, selection: 10..<script.utf16.count) == "SELECT 2;\nSELECT 3")
        // No selection: the statement under the caret.
        #expect(mysql.scriptToRun(in: script, selection: 13..<13) == "SELECT 2")
        // Whitespace/comment-only selection runs nothing.
        #expect(mysql.scriptToRun(in: "-- hi\nSELECT 1", selection: 0..<5) == nil)
        // Out-of-range selections are clamped rather than crashing.
        #expect(mysql.scriptToRun(in: script, selection: 500..<900) == "SELECT 3")
        // Non-ASCII text uses UTF-16 offsets like NSTextView.
        let emoji = "SELECT '🚗';\nSELECT 2"
        #expect(mysql.scriptToRun(in: emoji, selection: 0..<12) == "SELECT '🚗';")
    }

    @Test func statementAtCaret() {
        let script = "SELECT 1;\nSELECT 2;\nSELECT 3"
        #expect(mysql.statement(at: 12, in: script)?.text == "SELECT 2")
        #expect(mysql.statement(at: 0, in: script)?.text == "SELECT 1")
        #expect(mysql.statement(at: script.utf16.count, in: script)?.text == "SELECT 3")
    }
}

@Suite struct MySQLDialectTests {
    let dialect = MySQLDialect(flavor: .mysql)

    @Test func quotesIdentifiers() {
        #expect(dialect.quoteIdentifier("users") == "`users`")
        #expect(dialect.quoteIdentifier("we`ird") == "`we``ird`")
        #expect(dialect.qualified("shop", "orders") == "`shop`.`orders`")
    }

    @Test func stringLiteralsEscapeForSQLMode() {
        #expect(dialect.stringLiteral("it's") == "'it''s'")
        #expect(dialect.stringLiteral(#"a\b"#) == #"'a\\b'"#)
        #expect(dialect.stringLiteral("'; DROP TABLE x; --") == "'''; DROP TABLE x; --'")
        #expect(dialect.stringLiteral("") == "''")
        // Under NO_BACKSLASH_ESCAPES a backslash is literal and must not be doubled.
        let noBackslash = MySQLDialect(flavor: .mysql, backslashEscapes: false)
        #expect(noBackslash.stringLiteral(#"a\b'"#) == #"'a\b'''"#)
    }

    @Test func pageQuery() {
        let query = PageQuery(
            database: "shop", table: "orders", sort: [.init(column: "total", ascending: false)], limit: 300, offset: 600
        )
        #expect(query.selectSQL(dialect) == "SELECT * FROM `shop`.`orders` ORDER BY `total` DESC LIMIT 300 OFFSET 600")
        #expect(query.countSQL(dialect) == "SELECT COUNT(*) FROM `shop`.`orders`")
    }
}
