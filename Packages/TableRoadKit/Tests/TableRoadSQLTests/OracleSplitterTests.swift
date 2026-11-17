import Testing

@testable import TableRoadSQL

@Suite struct OracleSplitterTests {
    let oracle = StatementSplitter(syntax: .oracle)

    static let script = """
        CREATE TABLE t (id NUMBER, note VARCHAR2(20));
        INSERT INTO t VALUES (1, 'a;b');
        CREATE OR REPLACE PROCEDURE add_row(p NUMBER) AS
        BEGIN
          INSERT INTO t VALUES (p, q'[it's; fine]');
          COMMIT;
        END;
        /
        DECLARE
          n NUMBER := 10 / 2;
        BEGIN
          add_row(n);
        END;
        /
        SELECT * FROM t
        /
        SELECT 2 FROM dual;
        """

    static let expected = [
        "CREATE TABLE t (id NUMBER, note VARCHAR2(20))",
        "INSERT INTO t VALUES (1, 'a;b')",
        "CREATE OR REPLACE PROCEDURE add_row(p NUMBER) AS\nBEGIN\n  INSERT INTO t VALUES (p, q'[it's; fine]');\n"
            + "  COMMIT;\nEND;",
        "DECLARE\n  n NUMBER := 10 / 2;\nBEGIN\n  add_row(n);\nEND;",
        "SELECT * FROM t",
        "SELECT 2 FROM dual",
    ]

    @Test func splitsSQLAndPLSQLBlocks() {
        #expect(oracle.split(Self.script).map(\.text) == Self.expected)
    }

    @Test func typesAreSQLButTypeBodiesArePLSQL() {
        let script = """
            CREATE TYPE point AS OBJECT (x NUMBER, y NUMBER);
            CREATE TYPE BODY point AS MEMBER FUNCTION len RETURN NUMBER IS BEGIN RETURN 0; END; END;
            /
            """
        #expect(oracle.split(script).count == 2)
    }

    @Test func blockWithoutSlashRunsToTheEnd() {
        #expect(oracle.split("BEGIN NULL; END;").map(\.text) == ["BEGIN NULL; END;"])
        #expect(oracle.split("-- note\nbegin\n  null;\nend;\n").count == 1)
    }

    @Test func slashIsOnlyATerminatorAloneOnALine() {
        #expect(oracle.split("SELECT 4\n/ 2 FROM dual;").map(\.text) == ["SELECT 4\n/ 2 FROM dual"])
        #expect(oracle.split("SELECT 1 FROM dual\n/* c */;").count == 1)
    }

    @Test func streamingMatchesWholeScript() {
        for chunkSize in [1, 3, 7, 50] {
            var splitter = StreamingStatementSplitter(syntax: .oracle)
            var statements: [String] = []
            var index = Self.script.startIndex
            while index < Self.script.endIndex {
                let end =
                    Self.script.index(index, offsetBy: chunkSize, limitedBy: Self.script.endIndex)
                    ?? Self.script.endIndex
                statements += splitter.feed(String(Self.script[index..<end]))
                index = end
            }
            statements += splitter.finish()
            #expect(statements == Self.expected, "chunk size \(chunkSize)")
        }
    }

    @Test func plsqlDetection() {
        #expect(StatementSplitter.isOraclePLSQL(["CREATE", "OR", "REPLACE", "EDITIONABLE", "PACKAGE", "BODY"]))
        #expect(StatementSplitter.isOraclePLSQL(["CREATE", "TRIGGER", "X"]))
        #expect(!StatementSplitter.isOraclePLSQL(["CREATE", "TABLE", "X"]))
        #expect(!StatementSplitter.isOraclePLSQL(["SELECT"]))
    }
}
