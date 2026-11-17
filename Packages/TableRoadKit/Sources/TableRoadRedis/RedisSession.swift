import Foundation
import Network
import TableRoadCore

/// A RESP2 reply.
public indirect enum RESPValue: Sendable, Hashable {
    case simple(String)
    case error(String)
    case integer(Int64)
    case bulk(Data?)
    case array([RESPValue]?)

    public var string: String? {
        switch self {
        case .simple(let text), .error(let text): text
        case .integer(let number): String(number)
        case .bulk(let data): data.map { String(decoding: $0, as: UTF8.self) }
        case .array: nil
        }
    }

    public var array: [RESPValue] {
        if case .array(let values) = self { return values ?? [] }
        return []
    }

    public var integer: Int64? {
        switch self {
        case .integer(let number): number
        default: string.flatMap { Int64($0) }
        }
    }

    /// How redis-cli would print it (for the console).
    public func formatted(indent: String = "") -> String {
        switch self {
        case .simple(let text): return text
        case .error(let text): return "(error) " + text
        case .integer(let number): return "(integer) \(number)"
        case .bulk(nil), .array(nil): return "(nil)"
        case .bulk(let data?): return "\"" + String(decoding: data, as: UTF8.self) + "\""
        case .array(let values?):
            if values.isEmpty { return "(empty array)" }
            return values.enumerated().map { index, value in
                let prefix = "\(index + 1)) "
                return (index == 0 ? "" : indent) + prefix
                    + value.formatted(indent: indent + String(repeating: " ", count: prefix.count))
            }.joined(separator: "\n")
        }
    }
}

public struct RedisConnectConfig: Sendable, Hashable {
    public var host: String
    public var port: Int
    /// ACL user (Redis 6+); empty uses the default user.
    public var username: String
    public var password: String?
    public var database: Int
    public var useTLS: Bool

    public init(
        host: String, port: Int = 6379, username: String = "", password: String? = nil, database: Int = 0,
        useTLS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.useTLS = useTLS
    }

    public init(profile: ConnectionProfile, password: String?) {
        self.init(
            host: profile.host, port: profile.port, username: profile.username, password: password,
            database: profile.database.flatMap { Int($0) } ?? 0,
            useTLS: profile.tls != .disable && profile.tls != .prefer)
    }
}

/// A key in the browser.
public struct RedisKey: Sendable, Hashable, Identifiable {
    public var name: String
    public var type: String
    /// Seconds to live; nil = no expiry.
    public var ttl: Int?
    public var id: String { name }

    public init(name: String, type: String, ttl: Int?) {
        self.name = name
        self.type = type
        self.ttl = ttl
    }
}

/// A key's value, by type.
public enum RedisValue: Sendable, Hashable {
    case string(String)
    case hash([(field: String, value: String)])
    case list([String])
    case set([String])
    case zset([(member: String, score: String)])
    case stream([(id: String, fields: [(String, String)])])
    case missing
    case unsupported(String)

    public static func == (lhs: RedisValue, rhs: RedisValue) -> Bool { lhs.description == rhs.description }
    public func hash(into hasher: inout Hasher) { hasher.combine(description) }

    var description: String {
        switch self {
        case .string(let text): "s:" + text
        case .hash(let pairs): "h:" + pairs.map { $0.field + "=" + $0.value }.joined(separator: ",")
        case .list(let items): "l:" + items.joined(separator: ",")
        case .set(let items): "S:" + items.joined(separator: ",")
        case .zset(let items): "z:" + items.map { $0.member + "=" + $0.score }.joined(separator: ",")
        case .stream(let entries): "x:" + entries.map(\.id).joined(separator: ",")
        case .missing: "missing"
        case .unsupported(let type): "u:" + type
        }
    }
}

/// A Redis (or Valkey) connection speaking RESP2 over Network.framework. Commands are serialised.
public actor RedisSession {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tableroad.redis")
    private var buffer = Data()
    private let lock = AsyncSerialLock()
    public let config: RedisConnectConfig
    public private(set) var serverVersion = ""
    public private(set) var database: Int
    public nonisolated var isEncrypted: Bool { config.useTLS }

    public static func connect(_ config: RedisConnectConfig) async throws -> RedisSession {
        let session = RedisSession(config: config)
        try await session.start()
        do {
            if let password = config.password, !password.isEmpty {
                let auth = config.username.isEmpty ? ["AUTH", password] : ["AUTH", config.username, password]
                _ = try await session.command(auth)
            }
            if config.database != 0 { _ = try await session.command(["SELECT", String(config.database)]) }
            let info = try await session.command(["INFO", "server"]).string ?? ""
            await session.setVersion(
                Self.infoField("redis_version", in: info) ?? Self.infoField("valkey_version", in: info) ?? "")
        } catch {
            await session.close()
            throw error
        }
        return session
    }

    private init(config: RedisConnectConfig) {
        self.config = config
        self.database = config.database
        let parameters: NWParameters = config.useTLS ? .tls : .tcp
        connection = NWConnection(
            host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: UInt16(clamping: config.port)) ?? 6379,
            using: parameters)
    }

    private func setVersion(_ version: String) { serverVersion = version }

    static func infoField(_ name: String, in info: String) -> String? {
        for line in info.split(whereSeparator: \.isNewline) where line.hasPrefix(name + ":") {
            return String(line.dropFirst(name.count + 1))
        }
        return nil
    }

    private func start() async throws {
        let queue = queue
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if resumed.claim() {
                        connection.cancel()
                        continuation.resume(
                            throwing: DatabaseError(
                                .connection, "Couldn't reach \(connection.endpoint): \(error.localizedDescription)"))
                    }
                case .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: DatabaseError(.connection, "Connection closed."))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func close() {
        connection.cancel()
    }

    // MARK: Commands

    /// Sends one command and returns its reply. Error replies throw.
    @discardableResult
    public func command(_ arguments: [String]) async throws -> RESPValue {
        let reply = try await lock.run { try await self.roundTrip(arguments) }
        if case .error(let message) = reply {
            let category: DatabaseError.Category =
                message.hasPrefix("NOAUTH") || message.hasPrefix("WRONGPASS") ? .authentication : .query
            throw DatabaseError(category, message)
        }
        if arguments.first?.uppercased() == "SELECT", let index = arguments.dropFirst().first.flatMap({ Int($0) }) {
            database = index
        }
        return reply
    }

    /// Like `command`, but returns error replies instead of throwing (the console shows them).
    public func rawCommand(_ arguments: [String]) async throws -> RESPValue {
        do {
            return try await command(arguments)
        } catch let error as DatabaseError where error.category == .query || error.category == .authentication {
            return .error(error.message)
        }
    }

    private func roundTrip(_ arguments: [String]) async throws -> RESPValue {
        var payload = Data("*\(arguments.count)\r\n".utf8)
        for argument in arguments {
            let bytes = Data(argument.utf8)
            payload.append(Data("$\(bytes.count)\r\n".utf8))
            payload.append(bytes)
            payload.append(Data("\r\n".utf8))
        }
        try await send(payload)
        while true {
            var index = buffer.startIndex
            if let value = try RESPParser.parse(buffer, at: &index) {
                buffer.removeSubrange(buffer.startIndex..<index)
                return value
            }
            buffer.append(try await receive())
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: DatabaseError(.connection, error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: DatabaseError(.connection, error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: DatabaseError(.connection, "The server closed the connection."))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: Browser helpers

    /// Keys matching a pattern, scanned (never KEYS, which blocks the server). Stops after `limit` keys.
    public func scan(pattern: String = "*", limit: Int = 1000) async throws -> (keys: [RedisKey], truncated: Bool) {
        var cursor = "0"
        var names: [String] = []
        repeat {
            let reply = try await command(["SCAN", cursor, "MATCH", pattern.isEmpty ? "*" : pattern, "COUNT", "500"])
            let parts = reply.array
            guard parts.count == 2 else { break }
            cursor = parts[0].string ?? "0"
            names += parts[1].array.compactMap(\.string)
        } while cursor != "0" && names.count < limit
        let truncated = cursor != "0" || names.count > limit
        let chosen = Array(Set(names)).sorted().prefix(limit)
        var keys: [RedisKey] = []
        for name in chosen {
            let type = try await command(["TYPE", name]).string ?? "none"
            let ttl = try await command(["TTL", name]).integer ?? -1
            keys.append(RedisKey(name: name, type: type, ttl: ttl >= 0 ? Int(ttl) : nil))
        }
        return (keys, truncated)
    }

    /// A key's value (collections capped at `limit` items).
    public func value(of key: String, limit: Int = 1000) async throws -> RedisValue {
        let type = try await command(["TYPE", key]).string ?? "none"
        let last = String(limit - 1)
        switch type {
        case "string":
            return .string(try await command(["GET", key]).string ?? "")
        case "hash":
            var cursor = "0"
            var pairs: [(String, String)] = []
            repeat {
                let reply = try await command(["HSCAN", key, cursor, "COUNT", "500"]).array
                guard reply.count == 2 else { break }
                cursor = reply[0].string ?? "0"
                let flat = reply[1].array.compactMap(\.string)
                pairs += stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
            } while cursor != "0" && pairs.count < limit
            return .hash(pairs.sorted { $0.0 < $1.0 }.map { (field: $0.0, value: $0.1) })
        case "list":
            return .list(try await command(["LRANGE", key, "0", last]).array.compactMap(\.string))
        case "set":
            let members = try await command(["SRANDMEMBER", key, String(limit)]).array.compactMap(\.string)
            return .set(members.sorted())
        case "zset":
            let flat = try await command(["ZRANGE", key, "0", last, "WITHSCORES"]).array.compactMap(\.string)
            return .zset(stride(from: 0, to: flat.count - 1, by: 2).map { (member: flat[$0], score: flat[$0 + 1]) })
        case "stream":
            let entries = try await command(["XRANGE", key, "-", "+", "COUNT", String(limit)]).array
            return .stream(
                entries.compactMap { entry in
                    let parts = entry.array
                    guard parts.count == 2, let id = parts[0].string else { return nil }
                    let flat = parts[1].array.compactMap(\.string)
                    return (id: id, fields: stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) })
                })
        case "none":
            return .missing
        default:
            return .unsupported(type)
        }
    }

    public func info() async throws -> [String: String] {
        let text = try await command(["INFO"]).string ?? ""
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// Splits a console line into arguments, honouring "double" and 'single' quotes.
    public static func arguments(_ line: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if let open = quote {
                if character == "\\", open == "\"", let next = iterator.next() {
                    switch next {
                    case "n": current.append("\n")
                    case "t": current.append("\t")
                    default: current.append(next)
                    }
                } else if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken {
                    arguments.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { arguments.append(current) }
        return arguments
    }
}

/// Resumes a continuation once, from callbacks that may fire repeatedly.
private final class ResumeOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Incremental RESP2 parser: returns nil when more bytes are needed.
enum RESPParser {
    static func parse(_ data: Data, at index: inout Data.Index) throws -> RESPValue? {
        guard index < data.endIndex else { return nil }
        let marker = data[index]
        guard let lineEnd = lineEnd(data, from: index + 1) else { return nil }
        let line = String(decoding: data[(index + 1)..<lineEnd], as: UTF8.self)
        let afterLine = lineEnd + 2
        switch marker {
        case UInt8(ascii: "+"):
            index = afterLine
            return .simple(line)
        case UInt8(ascii: "-"):
            index = afterLine
            return .error(line)
        case UInt8(ascii: ":"):
            index = afterLine
            return .integer(Int64(line) ?? 0)
        case UInt8(ascii: "$"):
            guard let length = Int(line) else { throw DatabaseError(.connection, "Bad reply from the server.") }
            if length < 0 {
                index = afterLine
                return .bulk(nil)
            }
            guard data.endIndex >= afterLine + length + 2 else { return nil }
            index = afterLine + length + 2
            return .bulk(Data(data[afterLine..<(afterLine + length)]))
        case UInt8(ascii: "*"):
            guard let count = Int(line) else { throw DatabaseError(.connection, "Bad reply from the server.") }
            if count < 0 {
                index = afterLine
                return .array(nil)
            }
            var position = afterLine
            var values: [RESPValue] = []
            for _ in 0..<count {
                guard let value = try parse(data, at: &position) else { return nil }
                values.append(value)
            }
            index = position
            return .array(values)
        default:
            throw DatabaseError(.connection, "Unexpected reply from the server (is this Redis?).")
        }
    }

    private static func lineEnd(_ data: Data, from start: Data.Index) -> Data.Index? {
        var i = start
        while i + 1 < data.endIndex {
            if data[i] == 0x0D && data[i + 1] == 0x0A { return i }
            i += 1
        }
        return nil
    }
}
