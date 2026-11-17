import Foundation

/// Runs a schedule's before/after script: with bash in the home folder, or with the interpreter its `#!` line names.
/// Output goes to the run's log. A non-zero exit or the timeout fails the run.
enum ScriptRunner {
    static func run(_ script: String, environment: [String: String], timeout: Int, log: RunLog) async throws {
        #if os(macOS)
            let file = FileManager.default.temporaryDirectory.appending(path: "tableroad-script-\(UUID().uuidString)")
            try Data(script.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let process = Process()
            if script.hasPrefix("#!") {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                process.executableURL = file
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [file.path]
            }
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice

            let collector = OutputCollector()
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { collector.append(data) }
            }

            let status: Int32 = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                    process.terminationHandler = { finished in
                        continuation.resume(returning: finished.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                        return
                    }
                    // Stops the script once the timeout passes (the exit is then reported as a timeout below).
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(max(timeout, 1))) {
                        if process.isRunning {
                            collector.timedOut = true
                            process.terminate()
                        }
                    }
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            output.fileHandleForReading.readabilityHandler = nil
            collector.append(output.fileHandleForReading.readDataToEndOfFile())
            let text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { log.write(text) }
            try Task.checkCancellation()
            if collector.timedOut { throw BackupError("The script didn't finish within \(timeout) seconds.") }
            guard status == 0 else {
                let last = text.split(separator: "\n").last.map { ": \($0)" } ?? ""
                throw BackupError("The script exited with status \(status)\(last)")
            }
        #else
            throw BackupError("Scripts can only run on macOS.")
        #endif
    }
}

/// Gathers a process's output from its reader thread.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var _timedOut = false

    var timedOut: Bool {
        get { lock.withLock { _timedOut } }
        set { lock.withLock { _timedOut = newValue } }
    }

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
