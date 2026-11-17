import Foundation
import NIOCore

/// TDS (Tabular Data Stream, MS-TDS) 7.4 messages: what SQL Server speaks on port 1433.
///
/// A message is one or more packets, each with an 8-byte header; the last has the end-of-message status bit.
enum TDSPacketType: UInt8 {
    case sqlBatch = 0x01
    case rpc = 0x03
    case tabularResult = 0x04
    case attention = 0x06
    case login7 = 0x10
    case preLogin = 0x12
}

enum TDS {
    static let headerLength = 8
    static let endOfMessage: UInt8 = 0x01
    /// TDS 7.4 (SQL Server 2012 and later; older servers answer with their own version).
    static let version: UInt32 = 0x7400_0004
    static let defaultPacketSize = 4096

    /// Splits a message payload into packets of at most `packetSize` bytes (header included).
    static func packets(_ type: TDSPacketType, payload: ByteBuffer, packetSize: Int, allocator: ByteBufferAllocator)
        -> ByteBuffer
    {
        var payload = payload
        let chunk = max(packetSize - headerLength, 512)
        var out = allocator.buffer(capacity: payload.readableBytes + headerLength * (payload.readableBytes / chunk + 1))
        var packetID: UInt8 = 1
        repeat {
            let length = min(chunk, payload.readableBytes)
            let last = length == payload.readableBytes
            out.writeInteger(type.rawValue)
            out.writeInteger(last ? endOfMessage : 0)
            out.writeInteger(UInt16(length + headerLength), endianness: .big)
            out.writeInteger(UInt16(0), endianness: .big)  // SPID
            out.writeInteger(packetID)
            out.writeInteger(UInt8(0))  // window
            var slice = payload.readSlice(length: length)!
            out.writeBuffer(&slice)
            packetID &+= 1
        } while payload.readableBytes > 0
        return out
    }

    // MARK: PRELOGIN

    enum Encryption: UInt8 {
        /// Encrypt the login packet only.
        case off = 0
        case on = 1
        case notSupported = 2
        case required = 3
    }

    static func preLogin(encryption: Encryption, allocator: ByteBufferAllocator) -> ByteBuffer {
        // VERSION, ENCRYPTION, INSTOPT, THREADID, MARS: 5 option headers of 5 bytes, then the terminator.
        let options: [(token: UInt8, data: [UInt8])] = [
            (0x00, [0x10, 0x00, 0x00, 0x00, 0x00, 0x00]),  // client version 16.0.0.0
            (0x01, [encryption.rawValue]),
            (0x02, [0x00]),  // default instance
            (0x03, [0, 0, 0, 0]),
            (0x04, [0x00]),  // no MARS
        ]
        var buffer = allocator.buffer(capacity: 64)
        var offset = options.count * 5 + 1
        for option in options {
            buffer.writeInteger(option.token)
            buffer.writeInteger(UInt16(offset), endianness: .big)
            buffer.writeInteger(UInt16(option.data.count), endianness: .big)
            offset += option.data.count
        }
        buffer.writeInteger(UInt8(0xFF))
        for option in options { buffer.writeBytes(option.data) }
        return buffer
    }

    /// The server's ENCRYPTION choice from its PRELOGIN response.
    static func encryption(inPreLoginResponse payload: ByteBuffer) -> Encryption? {
        var reader = payload
        while let token = reader.readInteger(as: UInt8.self), token != 0xFF {
            guard let offset = reader.readInteger(endianness: .big, as: UInt16.self),
                reader.readInteger(endianness: .big, as: UInt16.self) != nil
            else { return nil }
            if token == 0x01, let value = payload.getInteger(at: payload.readerIndex + Int(offset), as: UInt8.self) {
                return Encryption(rawValue: value)
            }
        }
        return nil
    }

    // MARK: LOGIN7

    struct Login {
        var hostName: String
        var userName: String
        var password: String
        var appName: String
        var serverName: String
        var database: String
        var packetSize: Int
    }

    static func login7(_ login: Login, allocator: ByteBufferAllocator) -> ByteBuffer {
        let fixedLength = 94
        // In LOGIN7 order; the password is obfuscated, not encrypted (TLS protects it).
        let strings: [(text: String, obfuscate: Bool)] = [
            (login.hostName, false), (login.userName, false), (login.password, true), (login.appName, false),
            (login.serverName, false),
        ]
        let tail: [String] = ["TableRoad", "", login.database]  // client library, language, database
        var data: [UInt8] = []
        var offsets: [(UInt16, UInt16)] = []
        func add(_ text: String, obfuscate: Bool = false) {
            let bytes = utf16LE(text)
            offsets.append((UInt16(fixedLength + data.count), UInt16(bytes.count / 2)))
            data += obfuscate ? bytes.map { (($0 << 4) | ($0 >> 4)) ^ 0xA5 } : bytes
        }
        for (text, obfuscate) in strings { add(text, obfuscate: obfuscate) }
        let extensionOffset = (UInt16(fixedLength + data.count), UInt16(0))
        for text in tail { add(text) }

        var buffer = allocator.buffer(capacity: fixedLength + data.count)
        buffer.writeInteger(UInt32(fixedLength + data.count), endianness: .little)
        buffer.writeInteger(version, endianness: .little)
        buffer.writeInteger(UInt32(login.packetSize), endianness: .little)
        buffer.writeInteger(UInt32(0x0700_0000), endianness: .little)  // client program version
        buffer.writeInteger(UInt32(ProcessInfo.processInfo.processIdentifier), endianness: .little)
        buffer.writeInteger(UInt32(0), endianness: .little)  // connection id
        buffer.writeInteger(UInt8(0xE0))  // OptionFlags1: USE_DB_ON, INIT_DB_FATAL, SET_LANG_ON
        buffer.writeInteger(UInt8(0x03))  // OptionFlags2: INIT_LANG_FATAL, ODBC_ON
        buffer.writeInteger(UInt8(0x00))  // TypeFlags
        buffer.writeInteger(UInt8(0x00))  // OptionFlags3
        buffer.writeInteger(Int32(0), endianness: .little)  // client time zone
        buffer.writeInteger(UInt32(0x0409), endianness: .little)  // client LCID
        for (index, pair) in offsets.enumerated() {
            if index == strings.count {  // the unused/extension slot sits between ServerName and CltIntName
                buffer.writeInteger(extensionOffset.0, endianness: .little)
                buffer.writeInteger(extensionOffset.1, endianness: .little)
            }
            buffer.writeInteger(pair.0, endianness: .little)
            buffer.writeInteger(pair.1, endianness: .little)
        }
        buffer.writeBytes([0, 0, 0, 0, 0, 0])  // client MAC
        let end = UInt16(fixedLength + data.count)
        for _ in 0..<3 {  // SSPI, AtchDBFile, ChangePassword: empty
            buffer.writeInteger(end, endianness: .little)
            buffer.writeInteger(UInt16(0), endianness: .little)
        }
        buffer.writeInteger(UInt32(0), endianness: .little)  // SSPI long length
        buffer.writeBytes(data)
        return buffer
    }

    // MARK: SQL batch

    /// ALL_HEADERS (transaction descriptor) + the statement text in UTF-16.
    static func sqlBatch(_ sql: String, transaction: UInt64, allocator: ByteBufferAllocator) -> ByteBuffer {
        let text = utf16LE(sql)
        var buffer = allocator.buffer(capacity: 22 + text.count)
        buffer.writeInteger(UInt32(22), endianness: .little)  // total header length
        buffer.writeInteger(UInt32(18), endianness: .little)  // this header's length
        buffer.writeInteger(UInt16(2), endianness: .little)  // transaction descriptor header
        buffer.writeInteger(transaction, endianness: .little)
        buffer.writeInteger(UInt32(1), endianness: .little)  // outstanding requests
        buffer.writeBytes(text)
        return buffer
    }

    static func utf16LE(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }
}
