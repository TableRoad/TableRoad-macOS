import Foundation
import TableRoadCore

/// A result column as described by the server, plus the type it is fetched as (LOBs are defined as LONG so their
/// contents arrive inline).
struct OracleColumn: Sendable, Hashable {
    var name: String
    var type: UInt8
    var csfrm: UInt8
    var precision: Int8
    var scale: Int8
    var bufferSize: UInt32
    var size: UInt32
    var nullable: Bool
    var fetchType: UInt8
    /// The schema-qualified type name of object columns (e.g. `SYS.XMLTYPE`).
    var objectType: String?

    /// LOB-like columns need a define (re-describe as LONG / prefetch) before rows are fetched.
    var needsDefine: Bool {
        [OracleType.clob, OracleType.blob, OracleType.json, OracleType.vector].contains(type)
    }

    var typeName: String {
        switch type {
        case OracleType.varchar: csfrm == 2 ? "NVARCHAR2" : "VARCHAR2"
        case OracleType.char: csfrm == 2 ? "NCHAR" : "CHAR"
        case OracleType.number: precision != 0 && scale == -127 ? "FLOAT" : "NUMBER"
        case OracleType.binaryInteger: "BINARY_INTEGER"
        case OracleType.long: "LONG"
        case OracleType.longRaw: "LONG RAW"
        case OracleType.raw: "RAW"
        case OracleType.rowid: "ROWID"
        case OracleType.urowid: "UROWID"
        case OracleType.date: "DATE"
        case OracleType.timestamp: "TIMESTAMP"
        case OracleType.timestampTZ: "TIMESTAMP WITH TIME ZONE"
        case OracleType.timestampLTZ: "TIMESTAMP WITH LOCAL TIME ZONE"
        case OracleType.intervalYM: "INTERVAL YEAR TO MONTH"
        case OracleType.intervalDS: "INTERVAL DAY TO SECOND"
        case OracleType.binaryFloat: "BINARY_FLOAT"
        case OracleType.binaryDouble: "BINARY_DOUBLE"
        case OracleType.clob: csfrm == 2 ? "NCLOB" : "CLOB"
        case OracleType.blob: "BLOB"
        case OracleType.bfile: "BFILE"
        case OracleType.json: "JSON"
        case OracleType.vector: "VECTOR"
        case OracleType.boolean: "BOOLEAN"
        case OracleType.cursor: "REF CURSOR"
        case OracleType.object: objectType ?? "OBJECT"
        default: "TYPE \(type)"
        }
    }
}

/// An ORA- error (or the end-of-call status, which carries the row count when `number` is 0).
struct OracleErrorInfo: Sendable {
    var number: UInt32 = 0
    var message: String?
    var position: Int = 0
    var cursorID: UInt16 = 0
    var rowCount: UInt64 = 0
}

/// What a request is, which decides how PARAMETER messages are read.
enum OracleRequestKind {
    case protocolNegotiation, dataTypes, auth, statement, simple
}

/// Accumulates one server response. Each message is read completely before any state changes, so a parse that runs
/// out of data can be resumed at the last message boundary when more packets arrive.
struct OracleResponse {
    let kind: OracleRequestKind
    let fieldVersion: UInt8
    /// With explicit end-of-response markers, ERROR and STATUS don't end a response.
    let explicitEnd: Bool

    var done = false
    var error = OracleErrorInfo()
    var callStatus: UInt32 = 0
    var warning: String?

    // Negotiation.
    var serverCharset: UInt16 = 0
    var serverNCharset: UInt16 = 0
    var serverCompileCaps: [UInt8] = []
    var serverRuntimeCaps: [UInt8] = []
    var serverBanner = ""

    // Auth.
    var parameters: [String: String] = [:]
    var verifierType: UInt32 = 0

    // Statements.
    var columns: [OracleColumn]?
    var rows: [[CellValue]] = []
    /// The last row decoded (also from earlier fetches): columns marked as repeated copy their value from it.
    var previousRow: [CellValue]?
    var bitVector: [UInt8]?
    var currentSchema: String?
    /// NCHAR data is AL16UTF16 (else the national character set is UTF8).
    var nationalUTF16 = true

    init(kind: OracleRequestKind, fieldVersion: UInt8, explicitEnd: Bool) {
        self.kind = kind
        self.fieldVersion = fieldVersion
        self.explicitEnd = explicitEnd
    }

    var failed: Bool { error.number != 0 && error.number != TNS.errNoDataFound }

    /// Reads messages until the response is complete. Throws `NeedMoreData` (after committing every complete
    /// message, with `reader.position` at the last boundary) when the payload ends early.
    mutating func process(_ reader: inout WireReader, committed: inout Int) throws {
        while !done {
            if explicitEnd && reader.remaining == 0 { return }
            let type = try reader.u8()
            try processMessage(type, &reader)
            committed = reader.position
        }
    }

    private mutating func processMessage(_ type: UInt8, _ r: inout WireReader) throws {
        switch type {
        case TNS.msgProtocol: try readProtocolInfo(&r)
        case TNS.msgDataTypes:
            while try r.u16() != 0 {
                if try r.u16() != 0 { try r.skip(4) }
            }
            done = true
        case TNS.msgError:
            try readErrorInfo(&r)
            if !explicitEnd { done = true }
        case TNS.msgStatus:
            let status = try r.ub4()
            _ = try r.ub2()
            callStatus = status
            if !explicitEnd { done = true }
        case TNS.msgParameter:
            if kind == .auth { try readAuthParameters(&r) } else { try readReturnParameters(&r) }
        case TNS.msgWarning:
            let number = try r.ub2()
            let length = try r.ub2()
            _ = try r.ub2()
            if number != 0 && length > 0 {
                let message = try r.string()
                warning = message
            }
        case TNS.msgServerSidePiggyback: try skipServerPiggyback(&r)
        case TNS.msgDescribeInfo:
            try r.skipBytesWithLength()
            let described = try readDescribeInfo(&r)
            columns = described
        case TNS.msgRowHeader: try readRowHeader(&r)
        case TNS.msgRowData: try readRowData(&r)
        case TNS.msgBitVector:
            _ = try r.ub2()
            let count = ((columns?.count ?? 0) + 7) / 8
            let vector = Array(try r.take(count))
            bitVector = vector
        case TNS.msgIOVector: try skipIOVector(&r)
        case TNS.msgFlushOutBinds: done = true
        case TNS.msgToken: _ = try r.ub8()
        case TNS.msgEndOfResponse: done = true
        case TNS.msgImplicitResultSet:
            throw DatabaseError(.unsupported, "Implicit result sets (DBMS_SQL.RETURN_RESULT) aren't supported yet.")
        case TNS.msgRenegotiate:
            throw DatabaseError(.unsupported, "The server asked to renegotiate the session, which isn't supported.")
        default:
            throw OracleProtocolError("unexpected message type \(type) at offset \(r.position - 1)")
        }
    }

    // MARK: Negotiation

    private mutating func readProtocolInfo(_ r: inout WireReader) throws {
        _ = try r.ub1()  // server version
        _ = try r.ub1()
        let banner = String(decoding: try r.nullTerminated(), as: UTF8.self)
        let charset = try r.u16le()
        _ = try r.ub1()  // server flags
        let elements = Int(try r.u16le())
        try r.skip(elements * 5)
        let fdoLength = Int(try r.u16())
        let fdo = Array(try r.take(fdoLength))
        var ncharset: UInt16 = 0
        if fdo.count >= 7 {
            let index = 6 + Int(fdo[5]) + Int(fdo[6])
            if fdo.count >= index + 5 { ncharset = UInt16(fdo[index + 3]) << 8 | UInt16(fdo[index + 4]) }
        }
        let compile = try r.bytesWithLength() ?? []
        let runtime = try r.bytesWithLength() ?? []
        serverBanner = banner
        serverCharset = charset
        serverNCharset = ncharset
        serverCompileCaps = compile
        serverRuntimeCaps = runtime
        done = true
    }

    private mutating func readAuthParameters(_ r: inout WireReader) throws {
        let count = try r.ub2()
        var values: [String: String] = [:]
        var verifier = verifierType
        for _ in 0..<count {
            _ = try r.ub4()
            let key = try r.string() ?? ""
            let value = try r.ub4() > 0 ? (try r.string() ?? "") : ""
            if key == "AUTH_VFR_DATA" { verifier = try r.ub4() } else { _ = try r.ub4() }
            values[key] = value
        }
        parameters.merge(values) { $1 }
        verifierType = verifier
    }

    private mutating func readReturnParameters(_ r: inout WireReader) throws {
        let numbers = try r.ub2()
        for _ in 0..<numbers { _ = try r.ub4() }
        let textLength = Int(try r.ub2())
        if textLength > 0 { try r.skip(textLength) }
        let pairs = try r.ub2()
        var schema: String?
        for _ in 0..<pairs {
            var key: [UInt8]?
            if try r.ub2() > 0 { key = try r.bytesWithLength() }
            if try r.ub2() > 0 { try r.skipBytesWithLength() }
            let keyword = try r.ub2()
            if keyword == 168, let key { schema = String(decoding: key, as: UTF8.self) }  // current schema
        }
        let registration = Int(try r.ub2())
        if registration > 0 { try r.skip(registration) }
        if let schema { currentSchema = schema }
    }

    private func skipServerPiggyback(_ r: inout WireReader) throws {
        let opcode = try r.ub1()
        switch opcode {
        case 1, 3: break  // query cache invalidation, trace event
        case 2:  // OS pid (MTS)
            _ = try r.ub2()
            try r.skipBytesWithLength()
        case 5:  // sync
            _ = try r.ub2()
            _ = try r.ub1()
            let elements = try r.ub2()
            _ = try r.ub1()
            for _ in 0..<elements {
                if try r.ub2() > 0 { try r.skipBytesWithLength() }
                if try r.ub2() > 0 { try r.skipBytesWithLength() }
                _ = try r.ub2()
            }
            _ = try r.ub4()
        case 7:  // LTXID
            let length = Int(try r.ub4())
            if length > 0 { try r.skipBytesWithLength() }
        case 8:  // application continuity replay context
            _ = try r.ub2()
            _ = try r.ub1()
            _ = try r.ub4()
            _ = try r.ub4()
            _ = try r.ub1()
            if try r.ub4() > 0 { try r.skipBytesWithLength() }
        case 9:  // extended sync
            _ = try r.ub2()
            _ = try r.ub1()
        case 4:  // session return (DRCP)
            _ = try r.ub2()
            _ = try r.ub1()
            let elements = try r.ub2()
            if elements > 0 {
                _ = try r.ub1()
                for _ in 0..<elements {
                    if try r.ub2() > 0 { try r.skipBytesWithLength() }
                    if try r.ub2() > 0 { try r.skipBytesWithLength() }
                    _ = try r.ub2()
                }
            }
            _ = try r.ub4()
            _ = try r.ub4()
            _ = try r.ub2()
        case 10:  // session signature
            _ = try r.ub2()
            _ = try r.ub1()
            _ = try r.ub8()
            _ = try r.ub8()
            _ = try r.ub8()
        default:
            throw OracleProtocolError("unknown server piggyback \(opcode)")
        }
    }

    private func skipIOVector(_ r: inout WireReader) throws {
        _ = try r.ub1()
        let requests = Int(try r.ub2())
        let iterations = Int(try r.ub4())
        let binds = iterations * 256 + requests
        _ = try r.ub4()
        _ = try r.ub2()
        let vector = Int(try r.ub2())
        if vector > 0 { try r.skip(vector) }
        let rowid = Int(try r.ub2())
        if rowid > 0 { try r.skip(rowid) }
        for _ in 0..<binds { _ = try r.ub1() }
    }

    // MARK: Errors

    private mutating func readErrorInfo(_ r: inout WireReader) throws {
        var info = OracleErrorInfo()
        let status = try r.ub4()  // end of call status
        _ = try r.ub2()  // end to end seq#
        _ = try r.ub4()  // current row number
        _ = try r.ub2()  // error number
        _ = try r.ub2()
        _ = try r.ub2()
        info.cursorID = try r.ub2()
        let position = try r.sb2()
        try r.skip(5)  // sql type, fatal, flags, user cursor options, UPI parameter
        _ = try r.ub1()  // warning flags
        _ = try r.ub4()  // rowid: block address
        _ = try r.ub2()  // partition
        _ = try r.ub1()
        _ = try r.ub4()  // block
        _ = try r.ub2()  // slot
        _ = try r.ub4()  // OS error
        _ = try r.ub1()  // statement number
        _ = try r.ub1()  // call number
        _ = try r.ub2()  // padding
        _ = try r.ub4()  // success iterations
        if try r.ub4() > 0 { try r.skipBytesWithLength() }  // logical rowid

        // Batch errors (array DML only): codes, offsets, messages.
        let codes = Int(try r.ub2())
        if codes > 0 {
            let first = try r.ub1()
            for _ in 0..<codes {
                if first == TNS.longLengthIndicator { _ = try r.ub4() }
                _ = try r.ub2()
            }
            if first == TNS.longLengthIndicator { try r.skip(1) }
        }
        let offsets = Int(try r.ub4())
        if offsets > 0 {
            let first = try r.ub1()
            for _ in 0..<offsets {
                if first == TNS.longLengthIndicator { _ = try r.ub4() }
                _ = try r.ub4()
            }
            if first == TNS.longLengthIndicator { try r.skip(1) }
        }
        let messages = Int(try r.ub2())
        if messages > 0 {
            try r.skip(1)
            for _ in 0..<messages {
                _ = try r.ub2()
                _ = try r.string()
                try r.skip(2)
            }
        }

        info.number = try r.ub4()
        info.rowCount = try r.ub8()
        if fieldVersion >= TNS.fieldVersion201 {
            _ = try r.ub4()  // sql type
            _ = try r.ub4()  // server checksum
        }
        if info.number != 0 {
            if position > 0 { info.position = Int(position) }
            info.message = (try r.string() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        callStatus = status
        error = info
    }

    // MARK: Describe

    private func readDescribeInfo(_ r: inout WireReader) throws -> [OracleColumn] {
        _ = try r.ub4()  // max row size
        let count = Int(try r.ub4())
        if count > 0 { _ = try r.ub1() }
        var result: [OracleColumn] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try readColumn(&r)) }
        if try r.ub4() > 0 { try r.skipBytesWithLength() }  // current date
        for _ in 0..<4 { _ = try r.ub4() }  // dcbflag, dcbmdbz, dcbmnpr, dcbmxpr
        if try r.ub4() > 0 { try r.skipBytesWithLength() }  // dcbqcky
        return result
    }

    private func readColumn(_ r: inout WireReader) throws -> OracleColumn {
        let type = try r.ub1()
        _ = try r.ub1()  // flags
        let precision = try r.sb1()
        let scale = try r.sb1()
        let bufferSize = try r.ub4()
        _ = try r.ub4()  // max array elements
        _ = try r.ub8()  // cont flags
        if try r.ub4() > 0 { try r.skipBytesWithLength() }  // type OID
        _ = try r.ub2()  // version
        _ = try r.ub2()  // character set id
        let csfrm = try r.ub1()
        var size = try r.ub4()
        if type == OracleType.raw { size = bufferSize }
        if fieldVersion >= TNS.fieldVersion122 { _ = try r.ub4() }  // oaccolid
        let nullable = try r.ub1() != 0
        _ = try r.ub1()  // v7 name length
        let name = try r.stringWithUB4Length() ?? ""
        let schema = try r.stringWithUB4Length()
        let typeName = try r.stringWithUB4Length()
        _ = try r.ub2()  // position
        _ = try r.ub4()  // UDS flags
        if fieldVersion >= TNS.fieldVersion231 {
            _ = try r.stringWithUB4Length()  // domain schema
            _ = try r.stringWithUB4Length()  // domain name
        }
        if fieldVersion >= TNS.fieldVersion231Ext3 {
            if try r.ub4() > 0 {
                _ = try r.ub1()
                let annotations = try r.ub4()
                _ = try r.ub1()
                for _ in 0..<annotations {
                    _ = try r.ub4()
                    _ = try r.string()
                    _ = try r.stringWithUB4Length()
                    _ = try r.ub4()
                }
                _ = try r.ub4()
            }
        }
        if fieldVersion >= TNS.fieldVersion234 {
            _ = try r.ub4()  // vector dimensions
            _ = try r.ub1()  // vector format
            _ = try r.ub1()  // vector flags
        }
        let objectType = type == OracleType.object ? [schema, typeName].compactMap { $0 }.joined(separator: ".") : nil
        return OracleColumn(
            name: name, type: type, csfrm: csfrm, precision: precision, scale: scale, bufferSize: bufferSize,
            size: size, nullable: nullable, fetchType: type, objectType: objectType)
    }

    // MARK: Rows

    private mutating func readRowHeader(_ r: inout WireReader) throws {
        _ = try r.ub1()  // flags
        _ = try r.ub2()  // requests
        _ = try r.ub4()  // iteration
        _ = try r.ub4()  // iterations
        _ = try r.ub2()  // buffer length
        var vector: [UInt8]?
        let length = Int(try r.ub4())
        if length > 0 {
            _ = try r.ub1()
            vector = Array(try r.take(length))
        }
        if try r.ub4() > 0 { try r.skipBytesWithLength() }  // rxhrid
        if let vector { bitVector = vector }
    }

    private mutating func readRowData(_ r: inout WireReader) throws {
        guard let columns else { throw OracleProtocolError("row data before column metadata") }
        var row: [CellValue] = []
        row.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            if let bitVector, index / 8 < bitVector.count, bitVector[index / 8] & (1 << (index % 8)) == 0 {
                // Unchanged from the previous row: the server didn't send it.
                row.append(previousRow.flatMap { index < $0.count ? $0[index] : nil } ?? .null)
            } else {
                row.append(try Self.readValue(column, &r, nationalUTF16: nationalUTF16))
            }
        }
        rows.append(row)
        previousRow = row
        bitVector = nil
    }

    static func readValue(_ column: OracleColumn, _ r: inout WireReader, nationalUTF16: Bool = true) throws
        -> CellValue
    {
        let type = column.fetchType
        if column.bufferSize == 0 && ![OracleType.long, OracleType.longRaw, OracleType.urowid].contains(type) {
            return .null  // NULL by describe (e.g. SELECT NULL)
        }
        let value: CellValue
        switch type {
        case OracleType.varchar, OracleType.char, OracleType.long:
            value = try r.bytesWithLength().map { .text(text($0, utf16: column.csfrm == 2 && nationalUTF16)) } ?? .null
        case OracleType.raw, OracleType.longRaw:
            value = try r.bytesWithLength().map { .bytes(Data($0)) } ?? .null
        case OracleType.number, OracleType.binaryInteger:
            value = try r.bytesWithLength().map(number) ?? .null
        case OracleType.date:
            value = try r.bytesWithLength().map(temporal(withZone: false, fraction: false)) ?? .null
        case OracleType.timestamp, OracleType.timestampLTZ:
            value = try r.bytesWithLength().map(temporal(withZone: false, fraction: true)) ?? .null
        case OracleType.timestampTZ:
            value = try r.bytesWithLength().map(temporal(withZone: true, fraction: true)) ?? .null
        case OracleType.intervalYM:
            value =
                try r.bytesWithLength().map { OracleValues.intervalYM($0).map(CellValue.temporal) ?? .null } ?? .null
        case OracleType.intervalDS:
            value =
                try r.bytesWithLength().map { OracleValues.intervalDS($0).map(CellValue.temporal) ?? .null } ?? .null
        case OracleType.binaryDouble:
            value =
                try r.bytesWithLength().map { OracleValues.binaryDouble($0).map(CellValue.double) ?? .null } ?? .null
        case OracleType.binaryFloat:
            value =
                try r.bytesWithLength().map { bytes in
                    OracleValues.binaryFloat(bytes).map { .double(Double("\($0)") ?? Double($0)) } ?? .null
                } ?? .null
        case OracleType.boolean:
            value = try r.bytesWithLength().map { .bool($0.last == 1) } ?? .null
        case OracleType.rowid:
            let length = try r.u8()
            if length == 0 || length == TNS.nullLengthIndicator {
                value = .null
            } else {
                let rba = try r.ub4()
                let partition = try r.ub2()
                _ = try r.ub1()
                let block = try r.ub4()
                let slot = try r.ub2()
                value =
                    OracleValues.rowid(rba: rba, partition: partition, block: block, slot: slot).map(CellValue.text)
                    ?? .null
            }
        case OracleType.urowid:
            if try r.bytesWithLength() == nil {
                value = .null
            } else {
                value = try r.bytesWithLength().flatMap(OracleValues.urowid).map(CellValue.text) ?? .null
            }
        case OracleType.clob, OracleType.blob, OracleType.bfile, OracleType.json, OracleType.vector:
            // A LOB locator (possibly with prefetched data); shown as a placeholder.
            if try r.ub4() > 0 {
                _ = try r.ub8()  // size
                _ = try r.ub4()  // chunk size
                if type == OracleType.json || type == OracleType.vector { try r.skipBytesWithLength() }
                try r.skipBytesWithLength()  // locator
                value = .unsupported(typeName: column.typeName, raw: "(\(column.typeName))")
            } else {
                value = .null
            }
        case OracleType.object:
            var present = false
            if try r.ub4() > 0 { try r.skipBytesWithLength() }  // type OID
            if try r.ub4() > 0 { try r.skipBytesWithLength() }  // OID
            if try r.ub4() > 0 { try r.skipBytesWithLength() }  // snapshot
            _ = try r.ub2()  // version
            if try r.ub4() > 0 { present = true }
            _ = try r.ub2()  // flags
            if present { try r.skipBytesWithLength() }
            value = present ? .unsupported(typeName: column.typeName, raw: "(\(column.typeName))") : .null
        default:
            throw DatabaseError(
                .unsupported, "Column \(column.name) has a type TableRoad can't read yet (\(column.typeName)).")
        }
        if type == OracleType.long || type == OracleType.longRaw {
            _ = try r.sb4()  // null indicator
            _ = try r.ub4()  // return code
        }
        return value
    }

    static func text(_ bytes: [UInt8], utf16: Bool) -> String {
        if utf16 { return String(decoding: utf16BE(bytes), as: UTF16.self) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func utf16BE(_ bytes: [UInt8]) -> [UInt16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
    }

    static func number(_ bytes: [UInt8]) -> CellValue {
        guard let text = OracleNumber.decode(bytes) else { return .null }
        if !text.contains("."), !text.contains("e"), let integer = Int64(text) { return .int(integer) }
        return .decimal(text)
    }

    static func temporal(withZone: Bool, fraction: Bool) -> ([UInt8]) -> CellValue {
        { bytes in
            OracleValues.timestamp(bytes, withZone: withZone, showFraction: fraction).map(CellValue.temporal) ?? .null
        }
    }
}
