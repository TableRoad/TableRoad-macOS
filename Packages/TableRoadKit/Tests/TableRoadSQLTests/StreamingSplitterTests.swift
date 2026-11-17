import Testing

@testable import TableRoadSQL

struct StreamingSplitterTests {
    static let script = """
        /*!40101 SET NAMES utf8mb4 */;
        /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
        -- a comment; with a semicolon
        INSERT INTO t VALUES (1,'a;b'),(2,'it\\'s; fine'),(3,"x;y");
        DELIMITER $$
        CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$
        DELIMITER ;
        SELECT `odd;name` FROM t;
        SELECT 'no terminator'
        """

    static let expected = [
        "/*!40101 SET NAMES utf8mb4 */",
        "/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */",
        "-- a comment; with a semicolon\nINSERT INTO t VALUES (1,'a;b'),(2,'it\\'s; fine'),(3,\"x;y\")",
        "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
        "SELECT `odd;name` FROM t",
        "SELECT 'no terminator'",
    ]

    @Test func wholeScriptKeepsVersionedComments() {
        #expect(StatementSplitter(syntax: .mysql).split(Self.script).map(\.text) == Self.expected)
    }

    /// Every chunk size, so boundaries land inside quotes, comments, "DELIMITER $$" and "$$" itself.
    @Test(arguments: [1, 2, 3, 5, 7, 13, 64])
    func chunkedMatchesWhole(chunkSize: Int) {
        var splitter = StreamingStatementSplitter()
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
        #expect(statements == Self.expected)
    }

    @Test func pendingTracksUnfinishedStatement() {
        var splitter = StreamingStatementSplitter()
        #expect(splitter.feed("SELECT 1; SELECT 'abc") == ["SELECT 1"])
        #expect(splitter.pendingLength > 0)
        #expect(splitter.feed("';") == ["SELECT 'abc'"])
        #expect(splitter.pendingLength == 0 || splitter.finish().isEmpty)
    }
}
