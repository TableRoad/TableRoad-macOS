import Darwin
import Foundation
import Network
import TableRoadCore

/// A byte stream to the listener. Plain TCP uses a BSD socket so a call can be interrupted with TCP urgent data
/// (Oracle's out-of-band break, which Network.framework can't send); TLS uses Network.framework without it.
protocol OracleTransport: AnyObject, Sendable {
    var supportsUrgentData: Bool { get }
    func send(_ data: Data) async throws
    func receive() async throws -> [UInt8]
    /// Sends one byte of TCP urgent data (the out-of-band break).
    func sendUrgent()
    func close()
}

/// Plain TCP over a blocking BSD socket; reads and writes run on their own dispatch queues so the cooperative pool
/// never blocks.
final class SocketTransport: OracleTransport, @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "tableroad.oracle.read")
    private let writeQueue = DispatchQueue(label: "tableroad.oracle.write")
    private let lock = NSLock()
    private var closed = false

    var supportsUrgentData: Bool { true }

    private init(fd: Int32) { self.fd = fd }

    static func connect(host: String, port: Int, timeout: TimeInterval = 15) async throws -> SocketTransport {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(
                        returning: SocketTransport(fd: try open(host: host, port: port, timeout: timeout)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func open(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        guard status == 0, let first = info else {
            throw DatabaseError(.connection, "Couldn't resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(info) }
        var lastError = ECONNREFUSED
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            candidate = address.pointee.ai_next
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            // Non-blocking connect so the timeout applies, then back to blocking I/O.
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var result = Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
            if result != 0 && errno == EINPROGRESS {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                result = poll(&poller, 1, Int32(timeout * 1000)) == 1 ? 0 : -1
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                if result == 0 {
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    if error != 0 {
                        result = -1
                        errno = error
                    }
                } else {
                    errno = ETIMEDOUT
                }
            }
            if result == 0 {
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            lastError = errno
            Darwin.close(fd)
        }
        throw DatabaseError(
            .connection, "Couldn't reach \(host):\(port): \(String(cString: strerror(lastError)))")
    }

    func send(_ data: Data) async throws {
        let fd = fd
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                var offset = 0
                let failure: Int32? = data.withUnsafeBytes { buffer in
                    while offset < buffer.count {
                        let sent = Darwin.send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                        if sent < 0 {
                            if errno == EINTR { continue }
                            return errno
                        }
                        offset += sent
                    }
                    return nil
                }
                if let failure {
                    continuation.resume(
                        throwing: DatabaseError(.connection, "Send failed: \(String(cString: strerror(failure)))"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func receive() async throws -> [UInt8] {
        let fd = fd
        return try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let count = recv(fd, &buffer, buffer.count, 0)
                    if count > 0 {
                        continuation.resume(returning: Array(buffer.prefix(count)))
                    } else if count == 0 {
                        continuation.resume(throwing: DatabaseError(.connection, "The server closed the connection."))
                    } else if errno == EINTR {
                        continue
                    } else {
                        continuation.resume(
                            throwing: DatabaseError(.connection, "Receive failed: \(String(cString: strerror(errno)))"))
                    }
                    return
                }
            }
        }
    }

    func sendUrgent() {
        var byte = UInt8(ascii: "!")
        _ = Darwin.send(fd, &byte, 1, MSG_OOB)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        // Wakes a pending recv; the descriptor is released once both queues are idle.
        shutdown(fd, SHUT_RDWR)
        let fd = fd
        let readQueue = readQueue
        writeQueue.async { readQueue.async { Darwin.close(fd) } }
    }

    deinit { close() }
}

/// TLS (TCPS) over Network.framework. No urgent data, so calls can't be interrupted.
final class TLSTransport: OracleTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tableroad.oracle.tls")

    var supportsUrgentData: Bool { false }

    private init(connection: NWConnection) { self.connection = connection }

    static func connect(host: String, port: Int) async throws -> TLSTransport {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 2484,
            using: NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp))
        let transport = TLSTransport(connection: connection)
        try await transport.start()
        return transport
    }

    private func start() async throws {
        let connection = connection
        let queue = queue
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

    func send(_ data: Data) async throws {
        let connection = connection
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

    func receive() async throws -> [UInt8] {
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: DatabaseError(.connection, error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if isComplete {
                    continuation.resume(throwing: DatabaseError(.connection, "The server closed the connection."))
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func sendUrgent() {}

    func close() { connection.cancel() }
}

/// Lets exactly one callback resume a continuation.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
