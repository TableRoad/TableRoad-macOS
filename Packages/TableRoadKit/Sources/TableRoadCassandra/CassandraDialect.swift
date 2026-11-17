import Foundation
import TableRoadCore
import TableRoadSQL

/// CQL spelling: double-quoted identifiers, `''` escapes, keyspaces as databases.
///
/// Paging convention: CQL has no OFFSET, so `pagingClause` asks for `LIMIT offset+limit … ALLOW FILTERING` and
/// appends the comment `/* tableroad:offset=N */`. `CassandraSession.execute` strips that comment and drops the
/// first N rows. ALLOW FILTERING lets the filter bar use non-key columns.
public struct CassandraDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func stringLiteral(_ value: String) -> String { CQLLiteral.quote(value) }

    public func bytesLiteral(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    public func booleanLiteral(_ value: Bool) -> String { value ? "true" : "false" }

    public func createDatabaseSQL(_ name: String, characterSet: String?, collation: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DDLError.emptyName }
        return "CREATE KEYSPACE \(quoteIdentifier(trimmed)) "
            + "WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}"
    }

    public func dropDatabaseSQL(_ name: String) -> String { "DROP KEYSPACE \(quoteIdentifier(name))" }
    public func useDatabaseSQL(_ name: String) -> String? { "USE \(quoteIdentifier(name))" }

    /// CQL's LIKE (SASI/SAI indexes only) has no escape character.
    public var likeEscapeCharacter: String { "" }
    public var likeEscapeClause: String { "" }
    public var supportsKeysetPaging: Bool { false }

    public func pagingClause(limit: Int, offset: Int, ordered: Bool) -> String {
        " LIMIT \(max(1, max(limit, 0) + max(offset, 0))) ALLOW FILTERING" + Self.offsetMarker(max(offset, 0))
    }

    static func offsetMarker(_ offset: Int) -> String { " /* tableroad:offset=\(offset) */" }

    /// Strips a trailing paging comment: the statement without it, and the rows to skip (nil if there was none).
    static func extractOffset(_ cql: String) -> (String, Int?) {
        guard let range = cql.range(of: #"\s*/\* tableroad:offset=(\d+) \*/\s*$"#, options: .regularExpression)
        else { return (cql, nil) }
        let digits = cql[range].filter(\.isNumber)
        return (String(cql[..<range.lowerBound]), Int(digits))
    }
}

/// Just enough CQL tokenising to find literals, identifiers and `?` markers outside strings and comments.
struct CQLToken {
    enum Kind: Equatable { case word, quotedIdentifier, string, symbol }
    var kind: Kind
    /// Identifier name (unquoted), string contents (unescaped), or the raw text.
    var value: String
    var range: Range<String.Index>
}

enum CQLScanner {
    static func tokens(_ cql: String) -> [CQLToken] {
        var tokens: [CQLToken] = []
        var index = cql.startIndex
        func peek(_ offset: Int) -> Character? {
            cql.index(index, offsetBy: offset, limitedBy: cql.endIndex).flatMap { $0 < cql.endIndex ? cql[$0] : nil }
        }
        while index < cql.endIndex {
            let character = cql[index]
            let start = index
            if character.isWhitespace {
                index = cql.index(after: index)
            } else if character == "-" && peek(1) == "-" || character == "/" && peek(1) == "/" {
                index = cql[index...].firstIndex(of: "\n") ?? cql.endIndex
            } else if character == "/" && peek(1) == "*" {
                index =
                    cql.range(of: "*/", range: cql.index(index, offsetBy: 2)..<cql.endIndex)?.upperBound ?? cql.endIndex
            } else if character == "'" || character == "\"" {
                var value = ""
                index = cql.index(after: index)
                while index < cql.endIndex {
                    if cql[index] == character {
                        let next = cql.index(after: index)
                        if next < cql.endIndex && cql[next] == character {
                            value.append(character)
                            index = cql.index(after: next)
                            continue
                        }
                        index = next
                        break
                    }
                    value.append(cql[index])
                    index = cql.index(after: index)
                }
                tokens.append(
                    CQLToken(kind: character == "'" ? .string : .quotedIdentifier, value: value, range: start..<index))
            } else if character.isLetter || character.isNumber || character == "_" {
                while index < cql.endIndex, cql[index].isLetter || cql[index].isNumber || cql[index] == "_" {
                    index = cql.index(after: index)
                }
                tokens.append(CQLToken(kind: .word, value: String(cql[start..<index]), range: start..<index))
            } else if "<>=!".contains(character) {
                while index < cql.endIndex, "<>=!".contains(cql[index]) { index = cql.index(after: index) }
                tokens.append(CQLToken(kind: .symbol, value: String(cql[start..<index]), range: start..<index))
            } else {
                index = cql.index(after: index)
                tokens.append(CQLToken(kind: .symbol, value: String(character), range: start..<index))
            }
        }
        return tokens
    }

    /// Unquoted words are case-insensitive in CQL (stored lower-case).
    static func identifier(_ token: CQLToken) -> String? {
        switch token.kind {
        case .word: token.value.lowercased()
        case .quotedIdentifier: token.value
        default: nil
        }
    }

    /// The keyspace (if named) and table after the first FROM.
    static func fromTarget(_ tokens: [CQLToken]) -> (keyspace: String?, table: String)? {
        guard let from = tokens.firstIndex(where: { $0.kind == .word && $0.value.uppercased() == "FROM" }),
            from + 1 < tokens.count, let first = identifier(tokens[from + 1])
        else { return nil }
        if from + 3 < tokens.count, tokens[from + 2].value == ".", let second = identifier(tokens[from + 3]) {
            return (first, second)
        }
        return (nil, first)
    }

    /// Replaces each `?` marker (outside strings and comments) with the matching literal.
    static func substitute(_ cql: String, _ literals: [String]) -> String {
        let markers = tokens(cql).filter { $0.kind == .symbol && $0.value == "?" }
        var output = ""
        var last = cql.startIndex
        for (marker, literal) in zip(markers, literals) {
            output += cql[last..<marker.range.lowerBound] + literal
            last = marker.range.upperBound
        }
        return output + cql[last...]
    }

    static func markerCount(_ cql: String) -> Int {
        tokens(cql).filter { $0.kind == .symbol && $0.value == "?" }.count
    }
}
