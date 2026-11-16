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
    }

    public var syntax: Syntax

    public init(syntax: Syntax) {
        self.syntax = syntax
    }

    public func split(_ script: String) -> [Statement] {
        let chars = Array(script.utf16)
        var statements: [Statement] = []
        var delimiter: [UInt16] = Array(";".utf16)
        var start = 0
        var i = 0
        var atLineStart = true

        func emit(upTo end: Int, next: Int) {
            let text = String(decoding: chars[start..<end], as: UTF16.self)
            let trimmed = Self.trimmingComments(text, syntax: syntax)
            if !trimmed.isEmpty {
                statements.append(Statement(text: trimmed, range: start..<end))
            }
            start = next
        }

        while i < chars.count {
            let c = chars[i]

            // DELIMITER command (MySQL client syntax) must start a line.
            if syntax == .mysql, atLineStart, let (newDelimiter, lineEnd) = Self.delimiterCommand(chars, at: i) {
                emit(upTo: i, next: lineEnd)
                delimiter = newDelimiter
                i = lineEnd
                atLineStart = true
                continue
            }
            if c == 0x0A { atLineStart = true } else if !Self.isSpace(c) { atLineStart = false }

            switch c {
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
            case 0x2F where i + 1 < chars.count && chars[i + 1] == 0x2A:  // /*
                i = Self.skipBlockComment(chars, from: i)
                continue
            case 0x24 where syntax == .postgres:  // $tag$
                if let end = Self.skipDollarQuoted(chars, from: i) {
                    i = end
                    continue
                }
            default:
                break
            }

            if chars[i...].starts(with: delimiter) {
                emit(upTo: i, next: i + delimiter.count)
                i += delimiter.count
                continue
            }
            i += 1
        }
        emit(upTo: chars.count, next: chars.count)
        return statements
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

    static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }

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
            } else if c == 0x2F, i + 1 < chars.count, chars[i + 1] == 0x2A {
                i = skipBlockComment(chars, from: i)
            } else {
                hasCode = true
                break
            }
        }
        return hasCode ? trimmed : ""
    }
}
