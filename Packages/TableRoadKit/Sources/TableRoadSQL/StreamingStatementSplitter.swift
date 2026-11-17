/// Splits a script that arrives in pieces (e.g. a large dump file read in chunks) into complete statements.
/// Quotes, comments and `DELIMITER` blocks may span chunks.
public struct StreamingStatementSplitter: Sendable {
    private let splitter: StatementSplitter
    private var pending: [UInt16] = []
    private var delimiter: [UInt16] = Array(";".utf16)

    public init(syntax: StatementSplitter.Syntax = .mysql) {
        splitter = StatementSplitter(syntax: syntax)
    }

    /// Statements completed by this chunk, in order.
    public mutating func feed(_ text: String) -> [String] {
        pending.append(contentsOf: text.utf16)
        let result = splitter.scan(pending, delimiter: delimiter, final: false)
        delimiter = result.delimiter
        pending.removeFirst(result.tailStart)
        return result.statements.map(\.text)
    }

    /// Whatever is left at the end of the input (a last statement without a terminator).
    public mutating func finish() -> [String] {
        let result = splitter.scan(pending, delimiter: delimiter, final: true)
        pending = []
        return result.statements.map(\.text)
    }

    /// UTF-16 units buffered for an unfinished statement (lets callers cap runaway statements).
    public var pendingLength: Int { pending.count }
}
