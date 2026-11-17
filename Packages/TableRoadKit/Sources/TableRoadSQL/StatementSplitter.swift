import Foundation

/// Splits a SQL script into statements, respecting quotes, comments and MySQL `DELIMITER` lines.
public struct StatementSplitter: Sendable {
    public struct Statement: Sendable, Hashable {
        /// Statement text without the terminating delimiter, trimmed.
        public var text: String
        /// UTF-16 offsets into the original script (what NSTextView uses), including leading whitespace/comments.
        public var range: Range<Int>
    }

    public enum Syntax: Sendable {
        /// `#` comments, backtick identifiers, backslash escapes in strings, `DELIMITER` command.
        case mysql
        /// `$tag$` dollar quoting, no `#` comments.
        case postgres
        /// SQL Server: `[bracketed]` identifiers, and `GO` on a line of its own separates batches (like `;`).
        case sqlserver
        /// Cassandra CQL: PostgreSQL rules plus `//` comments; `BEGIN BATCH … APPLY BATCH` stays one statement.
        case cql
        /// `q'[…]'` quoting; PL/SQL blocks (DECLARE/BEGIN, CREATE PROCEDURE …) run until a line holding only `/`,
        /// which also ends ordinary statements (SQL*Plus style).
        case oracle
    }

    public var syntax: Syntax

    public init(syntax: Syntax) {
        self.syntax = syntax
    }

    public func split(_ script: String) -> [Statement] {
        scan(Array(script.utf16), delimiter: Array(";".utf16), final: true).statements
    }

    /// Scans `chars` starting with `delimiter` in force. With `final` false (streaming), only statements that are
    /// definitely finished are returned; `tailStart` is where the unfinished remainder begins, and `delimiter` is
    /// the one in force there (so a `DELIMITER $$` block can span chunks).
    func scan(_ chars: [UInt16], delimiter startDelimiter: [UInt16], final: Bool) -> (
        statements: [Statement], tailStart: Int, delimiter: [UInt16]
    ) {
        var statements: [Statement] = []
        var delimiter = startDelimiter
        var start = 0
        var i = 0
        var atLineStart = true
        // Oracle: whether the statement's first keywords were examined, and whether they start a PL/SQL block.
        var blockChecked = false
        var inBlock = false

        func emit(upTo end: Int, next: Int) {
            let text = String(decoding: chars[start..<end], as: UTF16.self)
            let trimmed = Self.trimmingComments(text, syntax: syntax)
            if !trimmed.isEmpty {
                statements.append(Statement(text: trimmed, range: start..<end))
            }
            start = next
            blockChecked = false
            inBlock = false
        }

        scanning: while i < chars.count {
            let c = chars[i]

            // DELIMITER command (MySQL client syntax) must start a line.
            if syntax == .mysql, atLineStart, let (newDelimiter, lineEnd) = Self.delimiterCommand(chars, at: i) {
                // Streaming: the line may continue in the next chunk ("DELIMITER $" of "$$"), so wait for its end.
                if !final && Self.skipToLineEnd(chars, from: i) == chars.count { break scanning }
                emit(upTo: i, next: lineEnd)
                delimiter = newDelimiter
                i = lineEnd
                atLineStart = true
                continue
            }
            // GO (sqlcmd/SSMS batch separator) on a line of its own.
            if syntax == .sqlserver, atLineStart, let lineEnd = Self.goCommand(chars, at: i) {
                if !final && lineEnd == chars.count { break scanning }
                emit(upTo: i, next: lineEnd)
                i = lineEnd
                atLineStart = true
                continue
            }
            // Oracle: a line holding only "/" ends the statement (or PL/SQL block) before it.
            if syntax == .oracle, atLineStart, let lineEnd = Self.slashLine(chars, at: i) {
                if !final && lineEnd == chars.count && chars.last != 0x0A { break scanning }
                emit(upTo: i, next: lineEnd)
                i = lineEnd
                atLineStart = true
                continue
            }
            if c == 0x0A { atLineStart = true } else if !Self.isSpace(c) { atLineStart = false }

            if syntax == .oracle, !blockChecked, !Self.isSpace(c), !Self.startsComment(chars, at: i) {
                guard let words = Self.leadingWords(chars, from: i, count: 6, final: final) else { break scanning }
                blockChecked = true
                inBlock = Self.isOraclePLSQL(words)
            }

            switch c {
            case 0x27 where syntax == .oracle && Self.isQQuote(chars, at: i):  // q'[…]'
                i = Self.skipQQuoted(chars, from: i)
                continue
            case 0x27, 0x22,
                0x60 where c != 0x60 || syntax == .mysql:  // ' " `
                i = Self.skipQuoted(chars, from: i, quote: c, backslashEscapes: syntax == .mysql && c != 0x60)
                continue
            case 0x2D where i + 1 < chars.count && chars[i + 1] == 0x2D:  // --
                i = Self.skipToLineEnd(chars, from: i)
                continue
            case 0x23 where syntax == .mysql:  // #
                i = Self.skipToLineEnd(chars, from: i)
                continue
            case 0x2F where syntax == .cql && i + 1 < chars.count && chars[i + 1] == 0x2F:  // //
                i = Self.skipToLineEnd(chars, from: i)
                continue
            case 0x2F where i + 1 < chars.count && chars[i + 1] == 0x2A:  // /*
                i = Self.skipBlockComment(chars, from: i)
                continue
            case 0x5B where syntax == .sqlserver:  // [identifier], ]] escapes ]
                i = Self.skipQuoted(chars, from: i, quote: 0x5D, backslashEscapes: false)
                continue
            case 0x24 where syntax == .postgres || syntax == .cql:  // $tag$
                if let end = Self.skipDollarQuoted(chars, from: i) {
                    i = end
                    continue
                }
            default:
                break
            }

            if syntax == .cql, chars[i...].starts(with: delimiter), Self.isOpenBatch(chars[start..<i]) {
                i += delimiter.count
                continue
            }
            if !inBlock, chars[i...].starts(with: delimiter) {
                // Streaming: a delimiter that ends the chunk might be the start of a longer one ("$" vs "$$").
                emit(upTo: i, next: i + delimiter.count)
                i += delimiter.count
                continue
            }
            i += 1
        }
        if final {
            emit(upTo: chars.count, next: chars.count)
            return (statements, chars.count, delimiter)
        }
        return (statements, start, delimiter)
    }

    /// The statement containing (or immediately before) a UTF-16 caret offset.
    public func statement(at offset: Int, in script: String) -> Statement? {
        let statements = split(script)
        return statements.first { $0.range.contains(offset) || $0.range.upperBound == offset }
            ?? statements.last { $0.range.upperBound <= offset }
    }

    /// What ⌘↩ runs: the highlighted text when there is a selection (which may hold several statements),
    /// otherwise the statement under the caret. `selection` is in UTF-16 offsets, as NSTextView reports.
    public func scriptToRun(in script: String, selection: Range<Int>) -> String? {
        let length = script.utf16.count
        let lower = min(max(selection.lowerBound, 0), length)
        let upper = min(max(selection.upperBound, lower), length)
        if lower < upper {
            let utf16 = script.utf16
            let start = utf16.index(utf16.startIndex, offsetBy: lower)
            let end = utf16.index(utf16.startIndex, offsetBy: upper)
            let selected = String(script[start..<end])
            return split(selected).isEmpty ? nil : selected
        }
        return statement(at: lower, in: script)?.text
    }

    // MARK: - Scanning helpers

    // MARK: - Oracle

    /// The offset after a line holding only `/` (and spaces) starting at `start`, or nil.
    static func slashLine(_ chars: [UInt16], at start: Int) -> Int? {
        var i = start
        while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        guard i < chars.count, chars[i] == 0x2F else { return nil }
        i += 1
        while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 || chars[i] == 0x0D { i += 1 }
        if i == chars.count { return i }
        return chars[i] == 0x0A ? i + 1 : nil
    }

    static func startsComment(_ chars: [UInt16], at i: Int) -> Bool {
        guard i + 1 < chars.count else { return chars[i] == 0x2D || chars[i] == 0x2F }
        return (chars[i] == 0x2D && chars[i + 1] == 0x2D) || (chars[i] == 0x2F && chars[i + 1] == 0x2A)
    }

    static func isWordChar(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24
            || c == 0x23
    }

    /// Up to `count` leading words, uppercased; nil when the text ends before they're known (streaming).
    static func leadingWords(_ chars: [UInt16], from start: Int, count: Int, final: Bool) -> [String]? {
        var words: [String] = []
        var i = start
        while words.count < count {
            while i < chars.count, isSpace(chars[i]) { i += 1 }
            let wordStart = i
            while i < chars.count, isWordChar(chars[i]) { i += 1 }
            if i == chars.count && !final { return nil }
            guard i > wordStart else { break }
            words.append(String(decoding: chars[wordStart..<i], as: UTF16.self).uppercased())
            if i == chars.count { break }
        }
        return words
    }

    /// Statements that hold PL/SQL (and so contain `;`): anonymous blocks and stored code.
    public static func isOraclePLSQL(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        if first == "DECLARE" || first == "BEGIN" { return true }
        guard first == "CREATE" else { return false }
        var rest = words.dropFirst()
        if rest.first == "OR", rest.dropFirst().first == "REPLACE" { rest = rest.dropFirst(2) }
        if let word = rest.first, ["EDITIONABLE", "NONEDITIONABLE", "EDITIONING"].contains(word) {
            rest = rest.dropFirst()
        }
        guard let kind = rest.first else { return false }
        // CREATE TYPE … AS OBJECT (…) is plain SQL; type bodies hold PL/SQL.
        if kind == "TYPE" { return rest.dropFirst().first == "BODY" }
        return ["PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "LIBRARY"].contains(kind)
    }

    /// `q'` or `Q'` starting a quoted literal (not the end of an identifier such as `seq'`).
    static func isQQuote(_ chars: [UInt16], at i: Int) -> Bool {
        guard i >= 1, chars[i - 1] == 0x71 || chars[i - 1] == 0x51 else { return false }
        if i >= 2 {
            let before = chars[i - 2]
            // nq'…' (national) is fine; any other identifier character means this isn't a q-quote.
            if isWordChar(before) && before != 0x6E && before != 0x4E { return false }
        }
        return i + 1 < chars.count
    }

    /// Skips `q'X…X'` where X is any character, or a bracket pair.
    static func skipQQuoted(_ chars: [UInt16], from start: Int) -> Int {
        let open = chars[start + 1]
        let close: UInt16 =
            switch open {
            case 0x28: 0x29  // ( )
            case 0x5B: 0x5D  // [ ]
            case 0x7B: 0x7D  // { }
            case 0x3C: 0x3E  // < >
            default: open
            }
        var i = start + 2
        while i + 1 < chars.count {
            if chars[i] == close && chars[i + 1] == 0x27 { return i + 2 }
            i += 1
        }
        return chars.count
    }

    static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }

    /// End of a `GO` line (optionally `GO;` or followed by a comment), or nil if the line isn't one.
    static func goCommand(_ chars: [UInt16], at start: Int) -> Int? {
        var i = start
        while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        guard i + 1 < chars.count, chars[i] | 0x20 == 0x67, chars[i + 1] | 0x20 == 0x6F else { return nil }
        i += 2
        while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 || chars[i] == 0x3B { i += 1 }
        if i + 1 < chars.count, chars[i] == 0x2D, chars[i + 1] == 0x2D { i = skipToLineEnd(chars, from: i) }
        guard i == chars.count || chars[i] == 0x0A || chars[i] == 0x0D else { return nil }
        return skipToLineEnd(chars, from: i) < chars.count ? skipToLineEnd(chars, from: i) + 1 : chars.count
    }

    static func skipQuoted(_ chars: [UInt16], from start: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        var i = start + 1
        while i < chars.count {
            if backslashEscapes && chars[i] == 0x5C {
                i += 2
                continue
            }
            if chars[i] == quote {
                if i + 1 < chars.count && chars[i + 1] == quote {  // doubled quote
                    i += 2
                    continue
                }
                return i + 1
            }
            i += 1
        }
        return chars.count
    }

    static func skipToLineEnd(_ chars: [UInt16], from start: Int) -> Int {
        var i = start
        while i < chars.count && chars[i] != 0x0A { i += 1 }
        return i
    }

    static func skipBlockComment(_ chars: [UInt16], from start: Int) -> Int {
        var i = start + 2
        while i + 1 < chars.count {
            if chars[i] == 0x2A && chars[i + 1] == 0x2F { return i + 2 }
            i += 1
        }
        return chars.count
    }

    static func skipDollarQuoted(_ chars: [UInt16], from start: Int) -> Int? {
        var i = start + 1
        while i < chars.count, chars[i] != 0x24 {
            let c = chars[i]
            let isTagChar =
                (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
            guard isTagChar else { return nil }
            i += 1
        }
        guard i < chars.count else { return nil }
        let tag = Array(chars[start...i])
        var j = i + 1
        while j < chars.count {
            if chars[j...].starts(with: tag) { return j + tag.count }
            j += 1
        }
        return chars.count
    }

    /// A CQL `BEGIN … BATCH` whose `APPLY BATCH` hasn't been reached yet.
    static func isOpenBatch(_ chars: ArraySlice<UInt16>) -> Bool {
        // Only the head and tail matter, so long batches aren't rescanned at every `;`.
        var i = chars.startIndex
        while i < chars.endIndex {
            if isSpace(chars[i]) {
                i += 1
            } else if i + 1 < chars.endIndex,
                (chars[i] == 0x2D && chars[i + 1] == 0x2D)
                    || (chars[i] == 0x2F && chars[i + 1] == 0x2F)
            {
                while i < chars.endIndex && chars[i] != 0x0A { i += 1 }
            } else if i + 1 < chars.endIndex, chars[i] == 0x2F, chars[i + 1] == 0x2A {
                i = chars.startIndex + skipBlockComment(Array(chars[i...]), from: 0) + (i - chars.startIndex)
            } else {
                break
            }
        }
        let head = String(decoding: chars[i..<min(i + 40, chars.endIndex)], as: UTF16.self)
        let begins = #"^BEGIN\s+((UNLOGGED|COUNTER)\s+)?BATCH\b"#
        guard head.range(of: begins, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        let tail = String(decoding: chars[max(i, chars.endIndex - 40)...], as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.range(of: #"\bAPPLY\s+BATCH$"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// Parses `DELIMITER xx` at `start`; returns the new delimiter and the offset after the line.
    static func delimiterCommand(_ chars: [UInt16], at start: Int) -> ([UInt16], Int)? {
        var i = start
        while i < chars.count, chars[i] == 0x20 || chars[i] == 0x09 { i += 1 }
        let keyword = Array("delimiter".utf16)
        guard i + keyword.count < chars.count else { return nil }
        let word = chars[i..<(i + keyword.count)].map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        guard word == keyword, chars[i + keyword.count] == 0x20 || chars[i + keyword.count] == 0x09 else { return nil }
        let lineEnd = skipToLineEnd(chars, from: i)
        let value = String(decoding: chars[(i + keyword.count)..<lineEnd], as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return (Array(value.utf16), min(lineEnd + 1, chars.count))
    }

    /// `/*!40101 … */` and MariaDB's `/*M!100616 … */`: comments to other databases, but code to MySQL/MariaDB
    /// (dumps use them for SET FOREIGN_KEY_CHECKS etc., so they must run).
    static func isVersionedComment(_ chars: [UInt16], at i: Int) -> Bool {
        guard i + 2 < chars.count else { return false }
        if chars[i + 2] == 0x21 { return true }  // /*!
        return i + 3 < chars.count && chars[i + 2] == 0x4D && chars[i + 3] == 0x21  // /*M!
    }

    /// Trims whitespace and leading/trailing comment-only lines so `-- note` alone isn't a statement.
    static func trimmingComments(_ text: String, syntax: Syntax) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let splitter = StatementSplitter(syntax: syntax)
        let chars = Array(trimmed.utf16)
        var i = 0
        var hasCode = false
        while i < chars.count {
            let c = chars[i]
            if isSpace(c) {
                i += 1
            } else if c == 0x2D, i + 1 < chars.count, chars[i + 1] == 0x2D {
                i = skipToLineEnd(chars, from: i)
            } else if c == 0x23, splitter.syntax == .mysql {
                i = skipToLineEnd(chars, from: i)
            } else if c == 0x2F, splitter.syntax == .cql, i + 1 < chars.count, chars[i + 1] == 0x2F {
                i = skipToLineEnd(chars, from: i)
            } else if c == 0x2F, i + 1 < chars.count, chars[i + 1] == 0x2A, !isVersionedComment(chars, at: i) {
                i = skipBlockComment(chars, from: i)
            } else {
                hasCode = true
                break
            }
        }
        return hasCode ? trimmed : ""
    }
}
