import Foundation
import TableRoadCore
import TableRoadMySQL
import TableRoadSQL

public struct ImportFailure: Sendable, Hashable, Identifiable {
    public let id = UUID()
    /// 1-based statement number in the file.
    public var statement: Int
    /// The start of the statement.
    public var sql: String
    public var message: String
}

public struct ImportProgress: Sendable, Hashable {
    public var bytesRead: Int64
    public var totalBytes: Int64
    public var statements: Int
    public var failures: Int

    public init(bytesRead: Int64, totalBytes: Int64, statements: Int, failures: Int) {
        self.bytesRead = bytesRead
        self.totalBytes = totalBytes
        self.statements = statements
        self.failures = failures
    }
}

public struct ImportResult: Sendable, Hashable {
    public var statements: Int
    public var failures: [ImportFailure]
    /// True when the import stopped at the first error.
    public var stoppedOnError: Bool
}

/// Runs a SQL dump (`.sql`, or gzip-compressed `.sql.gz`) statement by statement, reading it in chunks.
public enum SQLDumpImport {
    static let chunkSize = 1 << 20
    static let maxStatementLength = 512 << 20
    static let maxRecordedFailures = 200

    public static func run(
        file: URL, database: String?, stopOnError: Bool, syntax: StatementSplitter.Syntax = .mysql,
        connect: @Sendable () async throws -> any SQLClient,
        progress: @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportResult {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let totalBytes = Int64(
            (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)??.int64Value ?? 0)
        let session = try await connect()
        defer { Task { await session.close() } }
        if let database { try await session.useDatabase(database) }

        var splitter = StreamingStatementSplitter(syntax: syntax)
        var inflater: Inflater?
        var carry = Data()
        var bytesRead: Int64 = 0
        var count = 0
        var failures: [ImportFailure] = []
        var failureCount = 0

        func execute(_ statements: [String]) async throws -> Bool {
            for statement in statements {
                try Task.checkCancellation()
                count += 1
                do {
                    try await session.run(statement)
                } catch {
                    let databaseError = error as? DatabaseError
                    if databaseError?.category == .connection { throw error }
                    failureCount += 1
                    if failures.count < maxRecordedFailures {
                        failures.append(
                            ImportFailure(
                                statement: count, sql: String(statement.prefix(300)),
                                message: databaseError?.message ?? error.localizedDescription))
                    }
                    if stopOnError { return false }
                }
            }
            return true
        }

        var first = true
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            bytesRead += Int64(chunk.count)
            if first {
                first = false
                if chunk.starts(with: [0x1F, 0x8B]) { inflater = try Inflater() }
            }
            let bytes = try inflater?.decompress(chunk) ?? chunk
            let text = try decodeUTF8(carry + bytes, carry: &carry)
            let statements = splitter.feed(text)
            guard splitter.pendingLength < maxStatementLength else { throw TransferError.statementTooLarge }
            if try await !execute(statements) {
                return ImportResult(statements: count, failures: failures, stoppedOnError: true)
            }
            progress(
                ImportProgress(bytesRead: bytesRead, totalBytes: totalBytes, statements: count, failures: failureCount))
        }
        guard carry.isEmpty else { throw TransferError.notUTF8 }
        if try await !execute(splitter.finish()) {
            return ImportResult(statements: count, failures: failures, stoppedOnError: true)
        }
        progress(
            ImportProgress(bytesRead: bytesRead, totalBytes: totalBytes, statements: count, failures: failureCount))
        return ImportResult(statements: count, failures: failures, stoppedOnError: false)
    }

    /// Decodes the complete UTF-8 prefix of `data`; an unfinished character at the end goes to `carry`.
    static func decodeUTF8(_ data: Data, carry: inout Data) throws -> String {
        var cut = data.endIndex
        // Step back over continuation bytes (10xxxxxx) to the start of the last character.
        var index = data.endIndex
        var continuation = 0
        while index > data.startIndex, continuation < 4 {
            index -= 1
            let byte = data[index]
            if byte & 0xC0 == 0x80 {
                continuation += 1
                continue
            }
            let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if continuation + 1 < length { cut = index }
            break
        }
        carry = Data(data[cut...])
        guard let text = String(data: Data(data[..<cut]), encoding: .utf8) else { throw TransferError.notUTF8 }
        return text
    }
}
