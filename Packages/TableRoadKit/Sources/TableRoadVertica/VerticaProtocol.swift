import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import TableRoadCore

/// Vertica's frontend/backend protocol: PostgreSQL's v3 framing with Vertica extensions (protocol 3.16 startup,
/// SHA-512 password hashing, a richer RowDescription). Values are requested in text format.
struct VerticaMessage {
    var type: UInt8
    var body: ByteBuffer
}

enum VerticaProtocol {
    /// What the client asks for (3.16), sent as a binary startup parameter after the fixed 3.5 header.
    static let requestedVersion: UInt32 = 3 << 16 | 16
    static let fixedVersion: UInt32 = 3 << 16 | 5
    static let sslRequestCode: UInt32 = 80_877_103
    static let cancelRequestCode: UInt32 = 80_877_102

    static func startup(user: String, database: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: 256)
        body.writeInteger(fixedVersion)
        body.writeString("protocol_version")
        body.writeInteger(UInt8(0))
        body.writeInteger(requestedVersion)
        body.writeInteger(UInt8(0))
        let parameters: [(String, String)] = [
            ("user", user), ("database", database), ("client_type", "TableRoad"), ("client_version", "1.0"),
            ("client_label", "TableRoad"), ("client_os", "macOS"),
            ("client_pid", String(ProcessInfo.processInfo.processIdentifier)), ("autocommit", "on"),
            ("binary_data_protocol", "0"), ("protocol_compat", "VER"),
        ]
        for (key, value) in parameters {
            body.writeString(key)
            body.writeInteger(UInt8(0))
            body.writeString(value)
            body.writeInteger(UInt8(0))
        }
        body.writeInteger(UInt8(0))
        return untyped(body, allocator: allocator)
    }

    static func untyped(_ body: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = body
        var out = allocator.buffer(capacity: body.readableBytes + 4)
        out.writeInteger(UInt32(body.readableBytes + 4))
        out.writeBuffer(&body)
        return out
    }

    static func typed(_ type: Character, _ body: ByteBuffer, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = body
        var out = allocator.buffer(capacity: body.readableBytes + 5)
        out.writeInteger(type.asciiValue!)
        out.writeInteger(UInt32(body.readableBytes + 4))
        out.writeBuffer(&body)
        return out
    }

    static func query(_ sql: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: sql.utf8.count + 1)
        body.writeString(sql)
        body.writeInteger(UInt8(0))
        return typed("Q", body, allocator: allocator)
    }

    /// The password reply for an authentication request (cleartext, MD5 or SHA-512 hashes).
    static func password(
        code: UInt32, payload: ByteBuffer, user: String, password: String, allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        var payload = payload
        var text: String
        switch code {
        case 3:
            text = password
        case 5, 65541:  // MD5: md5(md5(password + user) hex + salt)
            guard let salt = payload.readBytes(length: 4) else { throw protocolError }
            let first = Insecure.MD5.hash(data: Data(password.utf8) + Data(user.utf8)).hex
            text = "md5" + Insecure.MD5.hash(data: Data(first.utf8) + Data(salt)).hex
        case 65536, 66048:  // SHA-512: sha512(sha512(password + usersalt) hex + salt)
            guard let salt = payload.readBytes(length: 4), let length = payload.readInteger(as: UInt32.self),
                length == 16, let userSalt = payload.readBytes(length: 16)
            else { throw protocolError }
            let first = SHA512.hash(data: Data(password.utf8) + Data(userSalt)).hex
            text = "sha512" + SHA512.hash(data: Data(first.utf8) + Data(salt)).hex
        case 9:
            throw DatabaseError(.authentication, "The password has expired.")
        default:
            throw DatabaseError(
                .authentication, "This server asks for an authentication method TableRoad doesn't support (\(code)).")
        }
        var body = allocator.buffer(capacity: text.utf8.count + 1)
        body.writeString(text)
        body.writeInteger(UInt8(0))
        return typed("p", body, allocator: allocator)
    }

    static let protocolError = DatabaseError(.connection, "The server sent something TableRoad didn't expect.")

    /// ErrorResponse / NoticeResponse fields: code letter → value.
    static func fields(_ body: ByteBuffer) -> [Character: String] {
        var body = body
        var fields: [Character: String] = [:]
        while let code = body.readInteger(as: UInt8.self), code != 0 {
            fields[Character(UnicodeScalar(code))] = body.readNullTerminatedString() ?? ""
        }
        return fields
    }

    static func error(_ body: ByteBuffer) -> DatabaseError {
        let fields = fields(body)
        let message = fields["M"] ?? "Unknown error"
        let sqlState = fields["C"] ?? ""
        let category: DatabaseError.Category =
            sqlState.hasPrefix("28")
            ? .authentication
            : sqlState == "57014"
                ? .cancelled
                : sqlState.hasPrefix("08") || sqlState.hasPrefix("57") ? .connection : .query
        return DatabaseError(category, message, code: fields["V"].flatMap { Int($0) })
    }
}

extension Digest {
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension ByteBuffer {
    mutating func readNullTerminatedString() -> String? {
        guard let end = readableBytesView.firstIndex(of: 0) else { return nil }
        let string = readString(length: end - readerIndex)
        moveReaderIndex(forwardBy: 1)
        return string
    }
}

// MARK: - Socket

/// Messages are a type byte and a length-prefixed body; this splits the stream into them.
struct VerticaMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = VerticaMessage

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 5,
            let length = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt32.self)
        else { return .needMoreData }
        guard buffer.readableBytes >= Int(length) + 1 else { return .needMoreData }
        let type = buffer.readInteger(as: UInt8.self)!
        buffer.moveReaderIndex(forwardBy: 4)
        let body = buffer.readSlice(length: Int(length) - 4)!
        context.fireChannelRead(wrapInboundOut(VerticaMessage(type: type, body: body)))
        return .continue
    }
}

final class VerticaMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = VerticaMessage
    private let continuation: AsyncThrowingStream<VerticaMessage, any Error>.Continuation

    init(continuation: AsyncThrowingStream<VerticaMessage, any Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish(throwing: DatabaseError(.connection, "The connection to Vertica was lost."))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        continuation.finish(throwing: DatabaseError(.connection, "\(error)"))
        context.close(promise: nil)
    }
}

/// Reads the single-byte answer to an SSLRequest before any messages flow.
final class SSLAnswerHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<UInt8>

    init(promise: EventLoopPromise<UInt8>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        promise.succeed(buffer.readInteger(as: UInt8.self) ?? 0)
        context.pipeline.syncOperations.removeHandler(self, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(error)
    }
}

final class VerticaConnection: Sendable {
    let channel: any Channel
    private let iterator: IteratorBox

    private init(channel: any Channel, stream: AsyncThrowingStream<VerticaMessage, any Error>) {
        self.channel = channel
        iterator = IteratorBox(stream.makeAsyncIterator())
    }

    /// Connects, optionally upgrading to TLS first (SSLRequest).
    static func connect(host: String, port: Int, tls: NIOSSLContext?, required: Bool, serverHostname: String?)
        async throws -> (VerticaConnection, Bool)
    {
        let (stream, continuation) = AsyncThrowingStream<VerticaMessage, any Error>.makeStream()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .connect(host: host, port: port).get()
        var encrypted = false
        if let tls {
            let answer = channel.eventLoop.makePromise(of: UInt8.self)
            try await channel.pipeline.addHandler(SSLAnswerHandler(promise: answer)).get()
            var request = channel.allocator.buffer(capacity: 8)
            request.writeInteger(UInt32(8))
            request.writeInteger(VerticaProtocol.sslRequestCode)
            try await channel.writeAndFlush(request).get()
            if try await answer.futureResult.get() == UInt8(ascii: "S") {
                try await channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(
                        try NIOSSLClientHandler(context: tls, serverHostname: serverHostname), position: .first)
                }.get()
                encrypted = true
            } else if required {
                try? await channel.close()
                throw DatabaseError(.tls, "The server doesn't accept encrypted connections.")
            }
        }
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(VerticaMessageDecoder()))
            try channel.pipeline.syncOperations.addHandler(VerticaMessageHandler(continuation: continuation))
        }.get()
        return (VerticaConnection(channel: channel, stream: stream), encrypted)
    }

    func send(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(buffer).get()
    }

    func receive() async throws -> VerticaMessage {
        guard let message = try await iterator.next() else {
            throw DatabaseError(.connection, "The server closed the connection.")
        }
        return message
    }

    func close() async {
        try? await channel.close()
    }
}

private final class IteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<VerticaMessage, any Error>.AsyncIterator
    init(_ iterator: AsyncThrowingStream<VerticaMessage, any Error>.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> VerticaMessage? { try await iterator.next() }
}
