import Foundation
import TableRoadCore
import TableRoadSQL
import TableRoadTransfer

/// What a run needs from the app: connections by id (with their saved passwords), and where logs go.
public struct BackupContext: Sendable {
    public var connect: @Sendable (UUID) async throws -> any SQLClient
    public var connectionName: @Sendable (UUID) -> String?
    /// How each connection's scripts split into statements (DELIMITER for MySQL, dollar quotes for PostgreSQL).
    public var syntax: @Sendable (UUID) -> StatementSplitter.Syntax
    public var logDirectory: URL
    public var temporaryDirectory: URL

    public init(
        connect: @escaping @Sendable (UUID) async throws -> any SQLClient,
        connectionName: @escaping @Sendable (UUID) -> String?,
        syntax: @escaping @Sendable (UUID) -> StatementSplitter.Syntax, logDirectory: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.connect = connect
        self.connectionName = connectionName
        self.syntax = syntax
        self.logDirectory = logDirectory
        self.temporaryDirectory = temporaryDirectory
    }
}

/// Progress of a run, for the schedule list and the Sync database window.
public struct BackupProgress: Sendable, Hashable {
    /// "Dumping shop (3 of 5 tables)", "Restoring orders.sql.gz"…
    public var step: String
    /// 0…1 when known.
    public var fraction: Double?

    public init(step: String, fraction: Double? = nil) {
        self.step = step
        self.fraction = fraction
    }
}

/// Runs one backup, sync or restore: before script, the work, after script. Never throws: the outcome (and any
/// error) is in the returned `BackupRun`, and everything is written to its log file. Cancel the task to stop.
public enum BackupRunner {
    public static func run(
        _ schedule: BackupSchedule, context: BackupContext, runID: UUID = UUID(), startedAt: Date = .now,
        progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }
    ) async -> BackupRun {
        let logURL = context.logDirectory.appending(path: "\(runID.uuidString).log")
        let log = RunLog(url: logURL)
        var run = BackupRun(id: runID, startedAt: startedAt, logFile: logURL.path)
        log.write("Starting “\(schedule.name)”")

        var environment = [
            "TR_SCHEDULE_NAME": schedule.name,
            "TR_RUN_ID": runID.uuidString,
            "TR_LOG_FILE": logURL.path,
        ]
        if let id = schedule.source.connectionID ?? schedule.target.connectionID {
            environment["TR_CONNECTION_NAME"] = context.connectionName(id) ?? ""
        }
        if case .connection(_, let databases) = schedule.source {
            environment["TR_DATABASES"] = databases.map(\.name).joined(separator: "\n")
        }
        if case .folder(let path, _) = schedule.target {
            environment["TR_OUTPUT_DIR"] = path
        }

        var files: [URL] = []
        do {
            if let problem = schedule.problem { throw BackupError(problem) }
            if !schedule.scripts.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                progress(BackupProgress(step: "Running the before script"))
                log.write("Before script")
                try await ScriptRunner.run(
                    schedule.scripts.before, environment: environment, timeout: schedule.scripts.timeout, log: log)
            }
            let outcome = try await perform(schedule, context: context, log: log, progress: progress)
            files = outcome.files
            run.status = .succeeded
            run.message = outcome.summary
        } catch is CancellationError {
            run.status = .cancelled
            run.message = "Cancelled."
        } catch {
            run.status = .failed
            run.message = Self.describe(error)
        }
        log.write(
            run.status == .succeeded
                ? "Succeeded: \(run.message)" : "\(run.status.rawValue.capitalized): \(run.message)")

        if !schedule.scripts.after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && run.status != .cancelled {
            environment["TR_STATUS"] = run.status == .succeeded ? "succeeded" : "failed"
            environment["TR_BACKUP_FILES"] = files.map(\.path).joined(separator: "\n")
            progress(BackupProgress(step: "Running the after script"))
            log.write("After script")
            do {
                try await ScriptRunner.run(
                    schedule.scripts.after, environment: environment, timeout: schedule.scripts.timeout, log: log)
            } catch {
                log.write("After script failed: \(Self.describe(error))")
                if run.status == .succeeded {
                    run.status = .failed
                    run.message = "The after script failed: \(Self.describe(error))"
                }
            }
        }
        run.files = files.map(\.path)
        run.finishedAt = .now
        log.write("Finished")
        return run
    }

    struct Outcome {
        var files: [URL] = []
        var summary: String
    }

    static func perform(
        _ schedule: BackupSchedule, context: BackupContext, log: RunLog,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> Outcome {
        switch (schedule.source, schedule.target) {
        case (.connection(let id, let databases), .folder(let path, let keepLast)):
            return try await backup(
                connection: id, databases: databases, folder: URL(fileURLWithPath: path), keepLast: keepLast,
                context: context, log: log, progress: progress)
        case (.connection(let from, let databases), .connection(let to, let database)):
            return try await sync(
                from: from, databases: databases, to: to, database: database, context: context, log: log,
                progress: progress)
        case (.files(let paths), .connection(let to, let database?)):
            return try await restore(
                files: paths.map { URL(fileURLWithPath: $0) }, to: to, database: database, context: context, log: log,
                progress: progress)
        case (.folder(let path), .connection(let to, let database?)):
            return try await restore(
                files: try dumps(in: URL(fileURLWithPath: path)), to: to, database: database, context: context,
                log: log, progress: progress)
        default:
            throw BackupError(schedule.problem ?? "This combination of source and target isn't supported.")
        }
    }

    // MARK: Backup to a folder

    static func backup(
        connection id: UUID, databases: [DatabaseSelection], folder: URL, keepLast: Int?, context: BackupContext,
        log: RunLog, progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> Outcome {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = timestamp(.now)
        var files: [URL] = []
        var bytes: Int64 = 0
        for (index, selection) in databases.enumerated() {
            try Task.checkCancellation()
            let file = folder.appending(path: "\(safeName(selection.name))_\(stamp).sql.gz")
            log.write("Dumping \(selection.name) to \(file.path)")
            do {
                try await dump(
                    selection, connection: id, to: file, gzip: true, context: context, log: log,
                    progress: { step in
                        progress(
                            BackupProgress(
                                step: "\(selection.name): \(step.step)",
                                fraction: (Double(index) + (step.fraction ?? 0)) / Double(databases.count)))
                    })
            } catch {
                try? FileManager.default.removeItem(at: file)  // no half-written backups
                throw error
            }
            files.append(file)
            bytes += fileSize(file)
            if let keepLast { prune(folder: folder, database: selection.name, keep: keepLast, log: log) }
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return Outcome(
            files: files, summary: "\(databases.count) database\(databases.count == 1 ? "" : "s"), \(size)")
    }

    /// Dumps one database selection to a file on its own connection.
    static func dump(
        _ selection: DatabaseSelection, connection id: UUID, to file: URL, gzip: Bool, createDatabase: Bool? = nil,
        context: BackupContext, log: RunLog, progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws {
        let session = try await context.connect(id)
        let available = try await session.tables(in: selection.name).filter { $0.kind != .systemView }
        await session.close()
        let wanted: [TableInfo]
        if let tables = selection.tables {
            let names = Set(tables)
            wanted = available.filter { names.contains($0.name) }
            for missing in names.subtracting(available.map(\.name)).sorted() {
                log.write("Skipped \(selection.name).\(missing): it no longer exists")
            }
        } else {
            wanted = available
        }
        var options = selection.options
        if let createDatabase { options.createDatabase = createDatabase }
        let items = wanted.map { table in
            ExportItem(
                database: selection.name, table: table.name, isView: table.kind == .view,
                structure: options.structure, drop: options.dropTables && options.structure, data: options.data)
        }
        let result = try await TableExport.run(
            items: items, kind: .sql(gzip: gzip), destination: file, dump: options,
            connect: { try await context.connect(id) },
            progress: { step in
                progress(
                    BackupProgress(
                        step: "\(step.item) (\(step.itemIndex + 1) of \(step.itemCount))",
                        fraction: Double(step.itemIndex) / Double(max(step.itemCount, 1))))
            })
        log.write("Dumped \(items.count) tables and views of \(selection.name), \(result.rows) rows")
    }

    /// Keeps the newest `keep` backups of a database (by the timestamp in their names).
    static func prune(folder: URL, database: String, keep: Int, log: RunLog) {
        let prefix = safeName(database) + "_"
        guard keep > 0,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return }
        // Only files this feature wrote: <database>_<yyyy-MM-dd_HH-mm-ss>.sql.gz.
        let backups = names.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".sql.gz")
                && $0.dropFirst(prefix.count).dropLast(".sql.gz".count).wholeMatch(of: stampPattern) != nil
        }.sorted(by: >)
        for name in backups.dropFirst(keep) {
            do {
                try FileManager.default.removeItem(at: folder.appending(path: name))
                log.write("Deleted old backup \(name)")
            } catch {
                log.write("Couldn't delete old backup \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Sync into another connection

    static func sync(
        from source: UUID, databases: [DatabaseSelection], to target: UUID, database targetDatabase: String?,
        context: BackupContext, log: RunLog, progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> Outcome {
        // A dump is in its server's SQL; it only replays on the same kind of server.
        let probeSource = try await context.connect(source)
        let sourceFamily = probeSource.sqlDialect.family
        await probeSource.close()
        let targetSession = try await context.connect(target)
        let targetFamily = targetSession.sqlDialect.family
        let existing = Set((try? await targetSession.databases()) ?? [])
        defer { Task { await targetSession.close() } }
        guard sourceFamily == targetFamily else {
            throw BackupError(
                "\(context.connectionName(target) ?? "The target") is a different kind of server; syncing works between servers of the same kind."
            )
        }

        for (index, selection) in databases.enumerated() {
            try Task.checkCancellation()
            let destination = targetDatabase ?? selection.name
            let file = context.temporaryDirectory.appending(path: "tableroad-sync-\(UUID().uuidString).sql")
            defer { try? FileManager.default.removeItem(at: file) }
            let count = databases.count
            let name = selection.name
            let report: @Sendable (String, Double) -> Void = { phase, fraction in
                progress(
                    BackupProgress(
                        step: "\(name) → \(destination): \(phase)",
                        fraction: (Double(index) + fraction) / Double(count)))
            }
            log.write("Dumping \(selection.name)")
            try await dump(
                selection, connection: source, to: file, gzip: false, createDatabase: false, context: context, log: log,
                progress: { report($0.step, ($0.fraction ?? 0) / 2) })

            if !existing.contains(destination) {
                log.write("Creating \(destination) on the target")
                try await targetSession.run(
                    targetSession.sqlDialect.createDatabaseSQL(destination, characterSet: nil, collation: nil))
            }
            log.write("Loading into \(destination)")
            let total = Double(max(fileSize(file), 1))
            let result = try await SQLDumpImport.run(
                file: file, database: destination, stopOnError: true, syntax: context.syntax(target),
                connect: { try await context.connect(target) },
                progress: { report("loading", 0.5 + Double($0.bytesRead) / total / 2) })
            if let failure = result.failures.first {
                throw BackupError("Statement \(failure.statement) failed in \(destination): \(failure.message)")
            }
            log.write("Loaded \(result.statements) statements into \(destination)")
        }
        let name = context.connectionName(target) ?? "the target"
        return Outcome(
            summary: "Synced \(databases.count) database\(databases.count == 1 ? "" : "s") into \(name)")
    }

    // MARK: Restore files into a connection

    static func restore(
        files: [URL], to target: UUID, database: String, context: BackupContext, log: RunLog,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> Outcome {
        guard !files.isEmpty else { throw BackupError("There are no .sql or .sql.gz files to restore.") }
        let session = try await context.connect(target)
        let existing = Set((try? await session.databases()) ?? [])
        if !existing.contains(database) {
            log.write("Creating \(database) on the target")
            try await session.run(session.sqlDialect.createDatabaseSQL(database, characterSet: nil, collation: nil))
        }
        await session.close()
        var statements = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            log.write("Restoring \(file.path) into \(database)")
            let total = Double(max(fileSize(file), 1))
            let result = try await SQLDumpImport.run(
                file: file, database: database, stopOnError: true, syntax: context.syntax(target),
                connect: { try await context.connect(target) },
                progress: {
                    progress(
                        BackupProgress(
                            step: "Restoring \(file.lastPathComponent)",
                            fraction: (Double(index) + Double($0.bytesRead) / total) / Double(files.count)))
                })
            if let failure = result.failures.first {
                throw BackupError("\(file.lastPathComponent), statement \(failure.statement): \(failure.message)")
            }
            statements += result.statements
        }
        return Outcome(
            summary:
                "Restored \(files.count) file\(files.count == 1 ? "" : "s") (\(statements) statements) into \(database)"
        )
    }

    /// The .sql / .sql.gz files directly in a folder, by name.
    static func dumps(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".sql") || $0.hasSuffix(".sql.gz") }
            .sorted()
            .map { folder.appending(path: $0) }
    }

    // MARK: Helpers

    nonisolated(unsafe) static let stampPattern = /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}/

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    /// A database name safe as part of a file name.
    static func safeName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "_" : $0 }
        return String(cleaned).isEmpty ? "database" : String(cleaned)
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? BackupError { return error.message }
        if let error = error as? DatabaseError { return error.message }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

public struct BackupError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Appends timestamped lines to a run's log file.
final class RunLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter

    init(url: URL) {
        self.url = url
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = line.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "[\(formatter.string(from: .now))] \($0)\n" }.joined()
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
