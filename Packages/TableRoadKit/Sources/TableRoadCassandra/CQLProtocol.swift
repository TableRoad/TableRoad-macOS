import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import TableRoadCore

// The CQL native protocol, version 4 (Cassandra 2.2 and later; 3.x–5.x all speak it).
// Frame: version(1) flags(1) stream(2) opcode(1) length(4) body(length).

enum CQLOpcode: UInt8 {
    case error = 0x00
    case startup = 0x01
    case ready = 0x02
    case authenticate = 0x03
    case options = 0x05
    case supported = 0x06
    case query = 0x07
    case result = 0x08
    case prepare = 0x09
    case execute = 0x0A
    case register = 0x0B
    case event = 0x0C
    case batch = 0x0D
    case authChallenge = 0x0E
    case authResponse = 0x0F
    case authSuccess = 0x10
}

struct CQLFrame: Sendable {
    var flags: UInt8
    var stream: Int16
    var opcode: UInt8
    var body: ByteBuffer
}

struct CQLRequest: Sendable {
    var opcode: CQLOpcode
    var body: ByteBuffer
    var response: EventLoopPromise<CQLFrame>
}

/// Splits the byte stream into frames.
struct CQLFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = CQLFrame
    static let headerLength = 9

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= Self.headerLength,
            let length = buffer.getInteger(at: buffer.readerIndex + 5, as: UInt32.self)
        else { return .needMoreData }
        guard length < 256 << 20 else {
            throw DatabaseError(.connection, "The server sent a frame that is too large (\(length) bytes).")
        }
        guard buffer.readableBytes >= Self.headerLength + Int(length) else { return .needMoreData }
        _ = buffer.readInteger(as: UInt8.self)  // version
        let flags = buffer.readInteger(as: UInt8.self)!
        let stream = buffer.readInteger(as: Int16.self)!
        let opcode = buffer.readInteger(as: UInt8.self)!
        _ = buffer.readInteger(as: UInt32.self)
        var body = buffer.readSlice(length: Int(length))!
        // Tracing id and warnings come before the message body; we never ask for tracing or custom payloads.
        if flags & 0x02 != 0 { _ = body.readSlice(length: 16) }
        if flags & 0x08 != 0 { _ = body.readStringList() }
        if flags & 0x04 != 0 { _ = body.readBytesMap() }
        context.fireChannelRead(wrapInboundOut(CQLFrame(flags: flags, stream: stream, opcode: opcode, body: body)))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws
        -> DecodingState
    {
        while try decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }
}

/// Matches responses to requests by stream id (requests may be in flight concurrently).
final class CQLClientHandler: ChannelDuplexHandler {
    typealias InboundIn = CQLFrame
    typealias OutboundIn = CQLRequest
    typealias OutboundOut = ByteBuffer

    private var pending: [Int16: EventLoopPromise<CQLFrame>] = [:]
    private var nextStream: Int16 = 0

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)
        var stream = nextStream
        while pending[stream] != nil { stream = stream == Int16.max ? 0 : stream + 1 }
        nextStream = stream == Int16.max ? 0 : stream + 1
        pending[stream] = request.response
        var buffer = context.channel.allocator.buffer(
            capacity: CQLFrameDecoder.headerLength + request.body.readableBytes)
        buffer.writeInteger(UInt8(0x04))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(stream)
        buffer.writeInteger(request.opcode.rawValue)
        buffer.writeInteger(UInt32(request.body.readableBytes))
        var body = request.body
        buffer.writeBuffer(&body)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.stream >= 0 else { return }  // server-pushed events
        pending.removeValue(forKey: frame.stream)?.succeed(frame)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(DatabaseError(.connection, "The connection to the server was closed."))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(CQLConnection.mapTransportError(error))
        context.close(promise: nil)
    }

    private func failAll(_ error: any Error) {
        let waiting = pending
        pending = [:]
        for promise in waiting.values { promise.fail(error) }
    }
}

/// One socket to a Cassandra node. Requests are multiplexed by stream id, so it is safe to use concurrently.
final class CQLConnection: Sendable {
    let channel: any Channel
    let isEncrypted: Bool

    private init(channel: any Channel, isEncrypted: Bool) {
        self.channel = channel
        self.isEncrypted = isEncrypted
    }

    struct Endpoint: Sendable {
        var host: String
        var port: Int
        var username: String?
        var password: String?
        var tls: NIOSSLContext?
    }

    /// Connects, sends STARTUP and authenticates (SASL PLAIN, as PasswordAuthenticator expects).
    static func open(_ endpoint: Endpoint) async throws -> CQLConnection {
        let tls = endpoint.tls
        let serverName = Self.isIPAddress(endpoint.host) ? nil : endpoint.host
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    if let tls {
                        try pipeline.addHandler(NIOSSLClientHandler(context: tls, serverHostname: serverName))
                    }
                    try pipeline.addHandler(ByteToMessageHandler(CQLFrameDecoder()))
                    try pipeline.addHandler(CQLClientHandler())
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            throw DatabaseError(
                .connection, "Couldn't reach \(endpoint.host):\(endpoint.port): \(Self.describe(error))")
        }
        let connection = CQLConnection(channel: channel, isEncrypted: tls != nil)
        do {
            try await connection.handshake(endpoint)
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }

    private func handshake(_ endpoint: Endpoint) async throws {
        var body = channel.allocator.buffer(capacity: 32)
        body.writeStringMap(["CQL_VERSION": "3.0.0"])
        let response = try await send(.startup, body, timeout: .seconds(15))
        switch CQLOpcode(rawValue: response.opcode) {
        case .ready:
            return
        case .authenticate:
            guard let username = endpoint.username, !username.isEmpty else {
                throw DatabaseError(.authentication, "The server requires a user name and password.")
            }
            var token = Data([0])
            token.append(Data(username.utf8))
            token.append(0)
            token.append(Data((endpoint.password ?? "").utf8))
            var auth = channel.allocator.buffer(capacity: token.count + 4)
            auth.writeInteger(Int32(token.count))
            auth.writeBytes(token)
            let reply = try await send(.authResponse, auth, timeout: .seconds(15))
            guard reply.opcode == CQLOpcode.authSuccess.rawValue else {
                throw DatabaseError(.authentication, "The server asked for more than a user name and password.")
            }
        default:
            throw DatabaseError(.connection, "The server didn't answer like Cassandra.")
        }
    }

    /// Sends one request and waits for its response; ERROR responses are thrown as `DatabaseError`.
    func send(_ opcode: CQLOpcode, _ body: ByteBuffer, timeout: TimeAmount? = nil) async throws -> CQLFrame {
        let promise = channel.eventLoop.makePromise(of: CQLFrame.self)
        channel.writeAndFlush(CQLRequest(opcode: opcode, body: body, response: promise)).whenFailure {
            promise.fail(Self.mapTransportError($0))
        }
        if let timeout {
            let task = channel.eventLoop.scheduleTask(in: timeout) {
                promise.fail(DatabaseError(.connection, "The server didn't respond in time."))
            }
            promise.futureResult.whenComplete { _ in task.cancel() }
        }
        var frame = try await promise.futureResult.get()
        if frame.opcode == CQLOpcode.error.rawValue { throw Self.serverError(&frame.body) }
        return frame
    }

    func close() async {
        try? await channel.close().get()
    }

    // MARK: Requests

    /// QUERY with result paging. Consistency ONE (what cqlsh uses by default).
    func query(_ cql: String, pageSize: Int32 = 5000, pagingState: ByteBuffer? = nil) async throws -> CQLResult {
        var body = channel.allocator.buffer(capacity: cql.utf8.count + 32)
        body.writeLongString(cql)
        body.writeInteger(UInt16(0x0001))
        body.writeInteger(UInt8(0x04 | (pagingState == nil ? 0 : 0x08)))
        body.writeInteger(pageSize)
        if var state = pagingState {
            body.writeInteger(Int32(state.readableBytes))
            body.writeBuffer(&state)
        }
        var frame = try await send(.query, body)
        return try CQLResult.decode(&frame.body)
    }

    /// PREPARE: tells us the type of each `?` marker.
    func prepare(_ cql: String) async throws -> CQLPrepared {
        var body = channel.allocator.buffer(capacity: cql.utf8.count + 4)
        body.writeLongString(cql)
        var frame = try await send(.prepare, body)
        guard case .prepared(let prepared) = try CQLResult.decode(&frame.body) else {
            throw DatabaseError(.query, "The server didn't prepare the statement.")
        }
        return prepared
    }

    // MARK: Errors

    static func serverError(_ body: inout ByteBuffer) -> DatabaseError {
        let code = body.readInteger(as: Int32.self).map(Int.init) ?? 0
        let message = body.readCQLString() ?? "Unknown server error."
        let category: DatabaseError.Category =
            switch code {
            case 0x0100: .authentication
            case 0x000A: .connection  // protocol error, e.g. an unsupported protocol version
            default: .query
            }
        return DatabaseError(category, message, code: code)
    }

    static func mapTransportError(_ error: any Error) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if error is NIOSSLError || error is BoringSSLError {
            return DatabaseError(.tls, "TLS failed: \(describe(error))")
        }
        return DatabaseError(.connection, describe(error))
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? IOError { return error.description }
        return String(describing: error)
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

// MARK: - Results

struct CQLColumn: Sendable, Hashable {
    var keyspace: String
    var table: String
    var name: String
    var type: CQLType
}

struct CQLRows: Sendable {
    var columns: [CQLColumn]
    var rows: [[CellValue]]
    var pagingState: ByteBuffer?
}

struct CQLPrepared: Sendable {
    var id: ByteBuffer
    var variables: [CQLColumn]
}

enum CQLResult: Sendable {
    case void
    case rows(CQLRows)
    case setKeyspace(String)
    case prepared(CQLPrepared)
    case schemaChange

    static func decode(_ body: inout ByteBuffer) throws -> CQLResult {
        guard let kind = body.readInteger(as: Int32.self) else { throw malformed }
        switch kind {
        case 0x0001: return .void
        case 0x0002:
            let (columns, pagingState) = try readMetadata(&body)
            guard let count = body.readInteger(as: Int32.self) else { throw malformed }
            var rows: [[CellValue]] = []
            rows.reserveCapacity(Int(count))
            for _ in 0..<count {
                var row: [CellValue] = []
                row.reserveCapacity(columns.count)
                for column in columns {
                    guard let length = body.readInteger(as: Int32.self) else { throw malformed }
                    if length < 0 {
                        row.append(.null)
                    } else {
                        guard let value = body.readSlice(length: Int(length)) else { throw malformed }
                        row.append(CQLValues.cell(value, column.type))
                    }
                }
                rows.append(row)
            }
            return .rows(CQLRows(columns: columns, rows: rows, pagingState: pagingState))
        case 0x0003: return .setKeyspace(body.readCQLString() ?? "")
        case 0x0004:
            guard let idLength = body.readInteger(as: UInt16.self), let id = body.readSlice(length: Int(idLength)),
                let flags = body.readInteger(as: Int32.self), let count = body.readInteger(as: Int32.self),
                let keyCount = body.readInteger(as: Int32.self)
            else { throw malformed }
            for _ in 0..<keyCount { _ = body.readInteger(as: UInt16.self) }
            let variables = try readColumnSpecs(&body, flags: flags, count: Int(count))
            return .prepared(CQLPrepared(id: id, variables: variables))
        case 0x0005: return .schemaChange
        default: throw malformed
        }
    }

    private static func readMetadata(_ body: inout ByteBuffer) throws -> ([CQLColumn], ByteBuffer?) {
        guard let flags = body.readInteger(as: Int32.self), let count = body.readInteger(as: Int32.self) else {
            throw malformed
        }
        var pagingState: ByteBuffer?
        if flags & 0x0002 != 0 {
            guard let length = body.readInteger(as: Int32.self) else { throw malformed }
            if length >= 0 { pagingState = body.readSlice(length: Int(length)) }
        }
        if flags & 0x0004 != 0 { return ([], pagingState) }  // no metadata
        return (try readColumnSpecs(&body, flags: flags, count: Int(count)), pagingState)
    }

    private static func readColumnSpecs(_ body: inout ByteBuffer, flags: Int32, count: Int) throws -> [CQLColumn] {
        var keyspace = ""
        var table = ""
        let global = flags & 0x0001 != 0
        if global {
            guard let ks = body.readCQLString(), let t = body.readCQLString() else { throw malformed }
            keyspace = ks
            table = t
        }
        var columns: [CQLColumn] = []
        for _ in 0..<count {
            if !global {
                guard let ks = body.readCQLString(), let t = body.readCQLString() else { throw malformed }
                keyspace = ks
                table = t
            }
            guard let name = body.readCQLString() else { throw malformed }
            columns.append(CQLColumn(keyspace: keyspace, table: table, name: name, type: try CQLType.read(&body)))
        }
        return columns
    }

    static var malformed: DatabaseError { DatabaseError(.connection, "The server sent a malformed response.") }
}

// MARK: - Types

struct CQLField: Sendable, Hashable {
    var name: String
    var type: CQLType
}

indirect enum CQLType: Sendable, Hashable {
    case ascii, bigint, blob, boolean, counter, decimal, double, float, int, timestamp, uuid, varchar, varint
    case timeuuid, inet, date, time, smallint, tinyint, duration
    case list(CQLType)
    case set(CQLType)
    case map(CQLType, CQLType)
    case udt(keyspace: String, name: String, fields: [CQLField])
    case tuple([CQLType])
    case vector(CQLType, Int)
    case custom(String)

    static func read(_ body: inout ByteBuffer) throws -> CQLType {
        guard let id = body.readInteger(as: UInt16.self) else { throw CQLResult.malformed }
        switch id {
        case 0x0000:
            guard let name = body.readCQLString() else { throw CQLResult.malformed }
            return fromMarshal(name)
        case 0x0001: return .ascii
        case 0x0002: return .bigint
        case 0x0003: return .blob
        case 0x0004: return .boolean
        case 0x0005: return .counter
        case 0x0006: return .decimal
        case 0x0007: return .double
        case 0x0008: return .float
        case 0x0009: return .int
        case 0x000B: return .timestamp
        case 0x000C: return .uuid
        case 0x000D: return .varchar
        case 0x000E: return .varint
        case 0x000F: return .timeuuid
        case 0x0010: return .inet
        case 0x0011: return .date
        case 0x0012: return .time
        case 0x0013: return .smallint
        case 0x0014: return .tinyint
        case 0x0015: return .duration
        case 0x0020: return .list(try read(&body))
        case 0x0021: return .map(try read(&body), try read(&body))
        case 0x0022: return .set(try read(&body))
        case 0x0030:
            guard let keyspace = body.readCQLString(), let name = body.readCQLString(),
                let count = body.readInteger(as: UInt16.self)
            else { throw CQLResult.malformed }
            var fields: [CQLField] = []
            for _ in 0..<count {
                guard let field = body.readCQLString() else { throw CQLResult.malformed }
                fields.append(CQLField(name: field, type: try read(&body)))
            }
            return .udt(keyspace: keyspace, name: name, fields: fields)
        case 0x0031:
            guard let count = body.readInteger(as: UInt16.self) else { throw CQLResult.malformed }
            return .tuple(try (0..<count).map { _ in try read(&body) })
        default:
            throw DatabaseError(.query, "Unknown CQL type 0x\(String(id, radix: 16)).")
        }
    }

    /// Custom types arrive as Java class names: `org.apache.cassandra.db.marshal.DurationType`,
    /// `…VectorType(…FloatType, 3)`.
    static func fromMarshal(_ className: String) -> CQLType {
        let short = className.replacingOccurrences(of: "org.apache.cassandra.db.marshal.", with: "")
        if short == "DurationType" { return .duration }
        if short.hasPrefix("VectorType("), short.hasSuffix(")") {
            let inner = short.dropFirst("VectorType(".count).dropLast()
            if let comma = inner.lastIndex(of: ","),
                let size = Int(inner[inner.index(after: comma)...].trimmingCharacters(in: .whitespaces))
            {
                return .vector(fromMarshal(inner[..<comma].trimmingCharacters(in: .whitespaces)), size)
            }
        }
        let simple: [String: CQLType] = [
            "AsciiType": .ascii, "LongType": .bigint, "BytesType": .blob, "BooleanType": .boolean,
            "CounterColumnType": .counter, "DecimalType": .decimal, "DoubleType": .double, "FloatType": .float,
            "Int32Type": .int, "TimestampType": .timestamp, "UUIDType": .uuid, "UTF8Type": .varchar,
            "IntegerType": .varint, "TimeUUIDType": .timeuuid, "InetAddressType": .inet, "SimpleDateType": .date,
            "TimeType": .time, "ShortType": .smallint, "ByteType": .tinyint,
        ]
        return simple[short] ?? .custom(className)
    }

    /// Scalar types by their CQL name (as in `system_schema.columns.type`); nil for collections and UDTs.
    init?(scalarName: String) {
        let table: [String: CQLType] = [
            "ascii": .ascii, "bigint": .bigint, "blob": .blob, "boolean": .boolean, "counter": .counter,
            "decimal": .decimal, "double": .double, "float": .float, "int": .int, "timestamp": .timestamp,
            "uuid": .uuid, "text": .varchar, "varchar": .varchar, "varint": .varint, "timeuuid": .timeuuid,
            "inet": .inet, "date": .date, "time": .time, "smallint": .smallint, "tinyint": .tinyint,
            "duration": .duration,
        ]
        guard let type = table[scalarName.lowercased()] else { return nil }
        self = type
    }

    /// CQL spelling, e.g. `map<text, int>`.
    var name: String {
        switch self {
        case .ascii: "ascii"
        case .bigint: "bigint"
        case .blob: "blob"
        case .boolean: "boolean"
        case .counter: "counter"
        case .decimal: "decimal"
        case .double: "double"
        case .float: "float"
        case .int: "int"
        case .timestamp: "timestamp"
        case .uuid: "uuid"
        case .varchar: "text"
        case .varint: "varint"
        case .timeuuid: "timeuuid"
        case .inet: "inet"
        case .date: "date"
        case .time: "time"
        case .smallint: "smallint"
        case .tinyint: "tinyint"
        case .duration: "duration"
        case .list(let element): "list<\(element.name)>"
        case .set(let element): "set<\(element.name)>"
        case .map(let key, let value): "map<\(key.name), \(value.name)>"
        case .udt(_, let name, _): name
        case .tuple(let types): "tuple<\(types.map(\.name).joined(separator: ", "))>"
        case .vector(let element, let size): "vector<\(element.name), \(size)>"
        case .custom(let name): "'\(name)'"
        }
    }
}

// MARK: - Buffer helpers

extension ByteBuffer {
    mutating func readCQLString() -> String? {
        guard let length = readInteger(as: UInt16.self) else { return nil }
        return readString(length: Int(length))
    }

    mutating func readStringList() -> [String]? {
        guard let count = readInteger(as: UInt16.self) else { return nil }
        var list: [String] = []
        for _ in 0..<count {
            guard let item = readCQLString() else { return nil }
            list.append(item)
        }
        return list
    }

    mutating func readBytesMap() -> [String: ByteBuffer?]? {
        guard let count = readInteger(as: UInt16.self) else { return nil }
        var map: [String: ByteBuffer?] = [:]
        for _ in 0..<count {
            guard let key = readCQLString(), let length = readInteger(as: Int32.self) else { return nil }
            map[key] = length < 0 ? nil : readSlice(length: Int(length))
        }
        return map
    }

    mutating func writeCQLString(_ value: String) {
        writeInteger(UInt16(value.utf8.count))
        writeString(value)
    }

    mutating func writeLongString(_ value: String) {
        writeInteger(Int32(value.utf8.count))
        writeString(value)
    }

    mutating func writeStringMap(_ map: [String: String]) {
        writeInteger(UInt16(map.count))
        for (key, value) in map.sorted(by: { $0.key < $1.key }) {
            writeCQLString(key)
            writeCQLString(value)
        }
    }
}
