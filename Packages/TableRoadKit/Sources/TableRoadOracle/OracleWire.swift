import Foundation

// Oracle Net (TNS) packets and the two-task (TTC) encoding inside them, written from the message formats used by
// python-oracledb's thin mode. Numbers on the wire are big-endian; "universal" integers (ub2/ub4/ub8) are a length
// byte followed by that many big-endian bytes.

enum TNS {
    // Packet types.
    static let connect: UInt8 = 1
    static let accept: UInt8 = 2
    static let refuse: UInt8 = 4
    static let redirect: UInt8 = 5
    static let data: UInt8 = 6
    static let resend: UInt8 = 11
    static let marker: UInt8 = 12
    static let control: UInt8 = 14

    static let headerSize = 8
    static let packetFlagRedirect: UInt8 = 0x04

    // Data packet flags.
    static let dataFlagEOF: UInt16 = 0x0040
    static let dataFlagEndOfResponse: UInt16 = 0x2000

    // Markers.
    static let markerBreak: UInt8 = 1
    static let markerReset: UInt8 = 2
    static let markerInterrupt: UInt8 = 3

    // Protocol versions.
    static let versionDesired: UInt16 = 319
    static let versionMinimum: UInt16 = 300
    static let versionMinAccepted: UInt16 = 315
    static let versionMinLargeSDU: UInt16 = 315
    static let versionMinOOBCheck: UInt16 = 318
    static let versionMinEndOfResponse: UInt16 = 319
    static let acceptFlagEndOfResponse: UInt32 = 0x0200_0000

    // TTC message types.
    static let msgProtocol: UInt8 = 1
    static let msgDataTypes: UInt8 = 2
    static let msgFunction: UInt8 = 3
    static let msgError: UInt8 = 4
    static let msgRowHeader: UInt8 = 6
    static let msgRowData: UInt8 = 7
    static let msgParameter: UInt8 = 8
    static let msgStatus: UInt8 = 9
    static let msgIOVector: UInt8 = 11
    static let msgLobData: UInt8 = 14
    static let msgWarning: UInt8 = 15
    static let msgDescribeInfo: UInt8 = 16
    static let msgPiggyback: UInt8 = 17
    static let msgFlushOutBinds: UInt8 = 19
    static let msgBitVector: UInt8 = 21
    static let msgServerSidePiggyback: UInt8 = 23
    static let msgImplicitResultSet: UInt8 = 27
    static let msgRenegotiate: UInt8 = 28
    static let msgEndOfResponse: UInt8 = 29
    static let msgToken: UInt8 = 33

    // Function codes.
    static let funcAuthPhaseOne: UInt8 = 118
    static let funcAuthPhaseTwo: UInt8 = 115
    static let funcCloseCursors: UInt8 = 105
    static let funcCommit: UInt8 = 14
    static let funcRollback: UInt8 = 15
    static let funcExecute: UInt8 = 94
    static let funcFetch: UInt8 = 5
    static let funcLogoff: UInt8 = 9
    static let funcPing: UInt8 = 147

    // Execute options.
    static let execParse: UInt32 = 0x01
    static let execBind: UInt32 = 0x08
    static let execDefine: UInt32 = 0x10
    static let execExecute: UInt32 = 0x20
    static let execFetch: UInt32 = 0x40
    static let execCommit: UInt32 = 0x100
    static let execNotPLSQL: UInt32 = 0x8000

    // Lengths.
    static let maxShortLength = 252
    static let longLengthIndicator: UInt8 = 254
    static let nullLengthIndicator: UInt8 = 255
    static let chunkSize = 32767
    static let maxLongLength: UInt32 = 0x7fff_ffff

    // Character sets.
    static let charsetUTF8: UInt16 = 873
    static let charsetUTF16: UInt16 = 2000

    // Errors with protocol meaning.
    static let errNoDataFound: UInt32 = 1403
    static let errArrayDMLErrors: UInt32 = 24381

    // Call status.
    static let callStatusTransactionInProgress: UInt32 = 0x02

    // Compile capability indexes and the TTC field versions they gate.
    static let fieldVersion122: UInt8 = 8
    static let fieldVersion122Ext1: UInt8 = 9
    static let fieldVersion181Ext1: UInt8 = 11
    static let fieldVersion201: UInt8 = 14
    static let fieldVersion231: UInt8 = 17
    static let fieldVersion231Ext1: UInt8 = 18
    static let fieldVersion231Ext3: UInt8 = 20
    static let fieldVersion234: UInt8 = 24
    static let fieldVersionMax: UInt8 = 24
}

/// Oracle data type numbers (as sent in column metadata).
enum OracleType {
    static let varchar: UInt8 = 1
    static let number: UInt8 = 2
    static let binaryInteger: UInt8 = 3
    static let long: UInt8 = 8
    static let rowid: UInt8 = 11
    static let date: UInt8 = 12
    static let raw: UInt8 = 23
    static let longRaw: UInt8 = 24
    static let char: UInt8 = 96
    static let binaryFloat: UInt8 = 100
    static let binaryDouble: UInt8 = 101
    static let cursor: UInt8 = 102
    static let object: UInt8 = 109
    static let clob: UInt8 = 112
    static let blob: UInt8 = 113
    static let bfile: UInt8 = 114
    static let json: UInt8 = 119
    static let vector: UInt8 = 127
    static let timestamp: UInt8 = 180
    static let timestampTZ: UInt8 = 181
    static let intervalYM: UInt8 = 182
    static let intervalDS: UInt8 = 183
    static let urowid: UInt8 = 208
    static let timestampLTZ: UInt8 = 231
    static let boolean: UInt8 = 252
}

/// Builds a TTC message body (the bytes after a data packet's flags).
struct WireWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    mutating func u16le(_ value: UInt16) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8(value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((value >> UInt64(shift)) & 0xff)) }
    }

    /// Universal integer: the number of significant bytes, then the bytes.
    mutating func ub(_ value: UInt64) {
        if value == 0 {
            u8(0)
        } else if value <= 0xff {
            u8(1)
            u8(UInt8(value))
        } else if value <= 0xffff {
            u8(2)
            u16(UInt16(value))
        } else if value <= 0xffff_ffff {
            u8(4)
            u32(UInt32(value))
        } else {
            u8(8)
            u64(value)
        }
    }

    mutating func ub4(_ value: Int) { ub(UInt64(value)) }

    mutating func raw(_ data: some Sequence<UInt8>) { bytes.append(contentsOf: data) }

    /// Length-prefixed bytes; long values are sent in chunks behind the long-length indicator.
    mutating func bytesWithLength(_ data: [UInt8]) {
        if data.count <= TNS.maxShortLength {
            u8(UInt8(data.count))
            raw(data)
        } else {
            u8(TNS.longLengthIndicator)
            var offset = 0
            while offset < data.count {
                let length = min(TNS.chunkSize, data.count - offset)
                ub4(length)
                raw(data[offset..<(offset + length)])
                offset += length
            }
            ub4(0)
        }
    }

    /// An auth key/value pair.
    mutating func keyValue(_ key: String, _ value: String, flags: UInt32 = 0) {
        let keyBytes = Array(key.utf8)
        let valueBytes = Array(value.utf8)
        ub4(keyBytes.count)
        bytesWithLength(keyBytes)
        ub4(valueBytes.count)
        if !valueBytes.isEmpty { bytesWithLength(valueBytes) }
        ub(UInt64(flags))
    }
}

/// Thrown when a response is incomplete; `needed` is the total byte count required to make progress.
struct NeedMoreData: Error {
    var needed: Int
}

/// Reads TTC values from a response's concatenated data-packet payloads.
struct WireReader {
    let bytes: [UInt8]
    var position: Int

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { bytes.count - position }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0 else { throw OracleProtocolError("negative length") }
        guard position + count <= bytes.count else { throw NeedMoreData(needed: position + count) }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) << 8 | UInt16(b[b.startIndex + 1])
    }

    mutating func u16le() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex + 1]) << 8 | UInt16(b[b.startIndex])
    }

    mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Universal integer of at most `maxLength` bytes; the high bit of the length byte marks a negative value.
    private mutating func universal(maxLength: Int) throws -> (value: UInt64, negative: Bool) {
        let lengthByte = try u8()
        let negative = lengthByte & 0x80 != 0
        let length = Int(lengthByte & 0x7f)
        guard length <= maxLength else { throw OracleProtocolError("integer of \(length) bytes (max \(maxLength))") }
        let value = try take(length).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (value, negative)
    }

    mutating func ub1() throws -> UInt8 { try u8() }
    mutating func ub2() throws -> UInt16 { UInt16(truncatingIfNeeded: try universal(maxLength: 2).value) }
    mutating func ub4() throws -> UInt32 { UInt32(truncatingIfNeeded: try universal(maxLength: 4).value) }
    mutating func ub8() throws -> UInt64 { try universal(maxLength: 8).value }

    mutating func sb2() throws -> Int16 {
        let (value, negative) = try universal(maxLength: 2)
        let magnitude = Int16(truncatingIfNeeded: value)
        return negative ? -magnitude : magnitude
    }

    mutating func sb4() throws -> Int32 {
        let (value, negative) = try universal(maxLength: 4)
        let magnitude = Int32(truncatingIfNeeded: value)
        return negative ? -magnitude : magnitude
    }

    mutating func sb8() throws -> Int64 {
        let (value, negative) = try universal(maxLength: 8)
        let magnitude = Int64(truncatingIfNeeded: value)
        return negative ? -magnitude : magnitude
    }

    mutating func sb1() throws -> Int8 { Int8(bitPattern: try u8()) }

    /// Length-prefixed bytes (nil for a zero or NULL length); chunked when the length byte is the long indicator.
    mutating func bytesWithLength() throws -> [UInt8]? {
        let length = try u8()
        if length == 0 || length == TNS.nullLengthIndicator { return nil }
        if length != TNS.longLengthIndicator { return Array(try take(Int(length))) }
        var result: [UInt8] = []
        while true {
            let chunk = Int(try ub4())
            if chunk == 0 { break }
            result.append(contentsOf: try take(chunk))
        }
        return result
    }

    mutating func skipBytesWithLength() throws {
        let length = try u8()
        if length == 0 || length == TNS.nullLengthIndicator { return }
        if length != TNS.longLengthIndicator { return try skip(Int(length)) }
        while true {
            let chunk = Int(try ub4())
            if chunk == 0 { break }
            try skip(chunk)
        }
    }

    /// AL32UTF8 text (the session's character set).
    mutating func string() throws -> String? {
        try bytesWithLength().map { String(decoding: $0, as: UTF8.self) }
    }

    /// A ub4 length followed by a string (used in metadata, where the ub4 says whether the string is present).
    mutating func stringWithUB4Length() throws -> String? {
        try ub4() > 0 ? try string() : nil
    }

    /// Null-terminated bytes (the server banner).
    mutating func nullTerminated() throws -> [UInt8] {
        var result: [UInt8] = []
        while true {
            let byte = try u8()
            if byte == 0 { return result }
            result.append(byte)
        }
    }
}

struct OracleProtocolError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
