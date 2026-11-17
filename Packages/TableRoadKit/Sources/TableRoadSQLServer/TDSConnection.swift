import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import TableRoadCore

/// A complete TDS message (all packets up to end-of-message), as the session reads it.
struct TDSMessage {
    var type: UInt8
    var payload: ByteBuffer
}

/// The socket: writes messages as packets and delivers whole response messages in order.
final class TDSConnection: Sendable {
    let channel: any Channel
    private let messages: AsyncThrowingStream<TDSMessage, any Error>
    private let iterator: IteratorBox

    private init(channel: any Channel, messages: AsyncThrowingStream<TDSMessage, any Error>) {
        self.channel = channel
        self.messages = messages
        iterator = IteratorBox(messages.makeAsyncIterator())
    }

    static func connect(host: String, port: Int, timeout: TimeAmount = .seconds(15)) async throws -> TDSConnection {
        let (stream, continuation) = AsyncThrowingStream<TDSMessage, any Error>.makeStream()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(TDSPacketDecoder()), name: "tds-packets")
                    try channel.pipeline.syncOperations.addHandler(
                        TDSMessageHandler(continuation: continuation), name: "tds-messages")
                }
            }
            .connect(host: host, port: port)
            .get()
        return TDSConnection(channel: channel, messages: stream)
    }

    func send(_ type: TDSPacketType, _ payload: ByteBuffer, packetSize: Int) async throws {
        let packets = TDS.packets(type, payload: payload, packetSize: packetSize, allocator: channel.allocator)
        try await channel.writeAndFlush(packets).get()
    }

    /// The next whole message from the server.
    func receive() async throws -> TDSMessage {
        guard let message = try await iterator.next() else {
            throw DatabaseError(.connection, "The server closed the connection.")
        }
        return message
    }

    /// Wraps the stream in TLS. During the handshake TLS records travel inside PRELOGIN packets; afterwards they
    /// go straight over the socket.
    func startTLS(context: NIOSSLContext, serverHostname: String?) async throws {
        let framer = TDSHandshakeFramer()
        let handshakeDone = channel.eventLoop.makePromise(of: Void.self)
        let watcher = TLSHandshakeWatcher(framer: framer, promise: handshakeDone)
        try await channel.eventLoop.submit {
            let ssl = try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
            let pipeline = self.channel.pipeline.syncOperations
            try pipeline.addHandler(framer, position: .first)
            try pipeline.addHandler(ssl, position: .after(framer))
            try pipeline.addHandler(watcher, position: .after(ssl))
        }.get()
        do {
            try await handshakeDone.futureResult.get()
        } catch {
            throw DatabaseError(.tls, "TLS handshake failed: \(error)")
        }
    }

    func close() async {
        try? await channel.close()
    }
}

/// `AsyncThrowingStream`'s iterator is a struct that must be mutated; the session (an actor) is its only user.
private final class IteratorBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<TDSMessage, any Error>.AsyncIterator
    init(_ iterator: AsyncThrowingStream<TDSMessage, any Error>.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> TDSMessage? { try await iterator.next() }
}

/// Splits the byte stream into TDS packets (header + payload).
struct TDSPacketDecoder: ByteToMessageDecoder {
    typealias InboundOut = (type: UInt8, last: Bool, payload: ByteBuffer)

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= TDS.headerLength,
            let length = buffer.getInteger(at: buffer.readerIndex + 2, endianness: .big, as: UInt16.self)
        else { return .needMoreData }
        guard length >= TDS.headerLength else { throw TDSParseError(message: "Malformed TDS packet") }
        guard buffer.readableBytes >= Int(length) else { return .needMoreData }
        let type = buffer.readInteger(as: UInt8.self)!
        let status = buffer.readInteger(as: UInt8.self)!
        buffer.moveReaderIndex(forwardBy: 6)
        let payload = buffer.readSlice(length: Int(length) - TDS.headerLength)!
        context.fireChannelRead(Self.wrapInboundOut((type, status & TDS.endOfMessage != 0, payload)))
        return .continue
    }
}

/// Joins packets into messages and hands them to the session.
final class TDSMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = (type: UInt8, last: Bool, payload: ByteBuffer)

    private let continuation: AsyncThrowingStream<TDSMessage, any Error>.Continuation
    private var pending: ByteBuffer?

    init(continuation: AsyncThrowingStream<TDSMessage, any Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var packet = unwrapInboundIn(data)
        if pending == nil {
            pending = packet.payload
        } else {
            pending!.writeBuffer(&packet.payload)
        }
        if packet.last, let message = pending {
            pending = nil
            continuation.yield(TDSMessage(type: packet.type, payload: message))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish(throwing: DatabaseError(.connection, "The connection to SQL Server was lost."))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        continuation.finish(throwing: DatabaseError(.connection, "\(error)"))
        context.close(promise: nil)
    }
}

/// Below the TLS handler during the handshake: wraps outgoing TLS records in PRELOGIN packets and unwraps incoming
/// ones. Once the handshake completes it passes bytes straight through.
final class TDSHandshakeFramer: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var passthrough = false
    private var inbound: ByteBuffer?
    private var outbound: ByteBuffer?
    private var outboundPromises: [EventLoopPromise<Void>] = []

    func handshakeCompleted() { passthrough = true }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !passthrough else { return context.fireChannelRead(data) }
        var bytes = unwrapInboundIn(data)
        if inbound == nil { inbound = bytes } else { inbound!.writeBuffer(&bytes) }
        // Strip the packet headers; pass up the TLS bytes inside.
        while var buffer = inbound, buffer.readableBytes >= TDS.headerLength,
            let length = buffer.getInteger(at: buffer.readerIndex + 2, endianness: .big, as: UInt16.self),
            buffer.readableBytes >= Int(length)
        {
            buffer.moveReaderIndex(forwardBy: TDS.headerLength)
            let payload = buffer.readSlice(length: Int(length) - TDS.headerLength)!
            inbound = buffer.readableBytes > 0 ? buffer : nil
            context.fireChannelRead(wrapInboundOut(payload))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !passthrough else { return context.write(data, promise: promise) }
        var bytes = unwrapOutboundIn(data)
        if outbound == nil { outbound = bytes } else { outbound!.writeBuffer(&bytes) }
        if let promise { outboundPromises.append(promise) }
    }

    func flush(context: ChannelHandlerContext) {
        if let payload = outbound {
            outbound = nil
            let packets = TDS.packets(
                .preLogin, payload: payload, packetSize: TDS.defaultPacketSize, allocator: context.channel.allocator)
            let promises = outboundPromises
            outboundPromises = []
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { result in
                for pending in promises {
                    switch result {
                    case .success: pending.succeed()
                    case .failure(let error): pending.fail(error)
                    }
                }
            }
            context.write(wrapOutboundOut(packets), promise: promise)
        }
        context.flush()
    }
}

/// Above the TLS handler: switches the framer to pass-through when the handshake completes, then steps aside.
final class TLSHandshakeWatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let framer: TDSHandshakeFramer
    private let promise: EventLoopPromise<Void>

    init(framer: TDSHandshakeFramer, promise: EventLoopPromise<Void>) {
        self.framer = framer
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            framer.handshakeCompleted()
            promise.succeed()
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }
}
