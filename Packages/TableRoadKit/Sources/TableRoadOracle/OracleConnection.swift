import Foundation
import TableRoadCore

/// Where and how to reach an Oracle listener.
struct OracleEndpoint: Sendable {
    var host: String
    var port: Int
    var serviceName: String
    var useTLS: Bool
}

/// The result of running one statement on the wire.
struct OracleStatementResult: Sendable {
    var columns: [OracleColumn]?
    var rows: [[CellValue]]
    var rowCount: UInt64
}

/// One Oracle Net session: TNS packets over TCP or TLS (see OracleTransport), the TTC negotiation, O5LOGON and statement
/// execution. Requests are serialised by the caller; `interrupt()` may run while a request waits for its response.
actor OracleConnection {
    private var transport: (any OracleTransport)?
    /// The server takes TCP urgent data as a break (plain TCP only).
    private(set) var supportsOutOfBand = false
    private var inbox: [UInt8] = []
    private var inboxStart = 0

    private(set) var protocolVersion: UInt16 = 0
    private var sdu = 8192
    private var largePackets = false
    /// Responses end with an explicit marker (23ai); only used once our capabilities have told the server so.
    private(set) var explicitEndOfResponse = false
    private var serverOffersEndOfResponse = false
    private var checkOutOfBand = false
    private(set) var fieldVersion = TNS.fieldVersionMax
    private(set) var maxStringSize = 4000
    private(set) var charsetID: UInt16 = 0
    private(set) var ncharsetID: UInt16 = 0
    private(set) var banner = ""
    private var sequence: UInt8 = 0
    private var cursorsToClose: [UInt16] = []
    private var awaitingResponse = false
    private var interruptSent = false
    private var markerSeen = false
    private(set) var isBroken = false
    private(set) var transactionInProgress = false
    private(set) var sessionData: [String: String] = [:]
    private(set) var currentSchema: String?
    /// Turns off the end-of-response markers (tests exercise the incremental parser with it).
    var disableEndOfResponse = false

    /// Rows per round trip.
    static let fetchSize = 250
    static let requestedSDU = 65535

    private init() {}

    // MARK: Connect

    static func open(_ endpoint: OracleEndpoint, disableEndOfResponse: Bool = false) async throws -> OracleConnection {
        let session = OracleConnection()
        await session.setDisableEndOfResponse(disableEndOfResponse)
        do {
            try await session.negotiate(endpoint)
        } catch {
            await session.closeTransport()
            throw error
        }
        return session
    }

    private func setDisableEndOfResponse(_ value: Bool) { disableEndOfResponse = value }

    private func negotiate(_ endpoint: OracleEndpoint) async throws {
        var host = endpoint.host
        var port = endpoint.port
        var connectData = Self.connectDescriptor(endpoint)
        var flags: UInt8 = 0
        var attempts = 0
        try await connectTransport(host: host, port: port, useTLS: endpoint.useTLS)
        while true {
            attempts += 1
            guard attempts < 10 else { throw DatabaseError(.connection, "The listener kept redirecting.") }
            try await sendConnect(connectData, flags: flags)
            let packet = try await readPacket()
            switch packet.type {
            case TNS.accept:
                try handleAccept(packet.body)
                try await negotiateSession()
                return
            case TNS.resend:
                continue
            case TNS.refuse:
                throw refusal(packet.body, endpoint: endpoint)
            case TNS.redirect:
                var r = WireReader(packet.body)
                let length = Int(try r.u16())
                var data = Array(packet.body.dropFirst(2))
                if data.count < length {
                    let next = try await readPacket()
                    data = next.type == TNS.data ? Array(next.body.dropFirst(2)) : next.body
                }
                let text = String(decoding: data.prefix(length), as: UTF8.self)
                guard let split = text.firstIndex(of: "\0") else {
                    throw DatabaseError(.connection, "The listener sent an invalid redirect.")
                }
                let address = String(text[..<split])
                connectData = String(text[text.index(after: split)...])
                host = Self.descriptorValue("HOST", in: address) ?? host
                port = Self.descriptorValue("PORT", in: address).flatMap { Int($0) } ?? port
                flags = TNS.packetFlagRedirect
                try await connectTransport(host: host, port: port, useTLS: endpoint.useTLS)
            default:
                throw DatabaseError(.connection, "The listener answered with an unexpected packet (\(packet.type)).")
            }
        }
    }

    static func connectDescriptor(_ endpoint: OracleEndpoint) -> String {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "(", with: "?").replacingOccurrences(of: ")", with: "?")
                .replacingOccurrences(of: "=", with: "?")
        }
        let machine = clean(hostName())
        let user = clean(NSUserName())
        let service = endpoint.serviceName.isEmpty ? "FREEPDB1" : endpoint.serviceName
        return "(DESCRIPTION=(ADDRESS=(PROTOCOL=\(endpoint.useTLS ? "tcps" : "tcp"))(HOST=\(endpoint.host))"
            + "(PORT=\(endpoint.port)))(CONNECT_DATA=(SERVICE_NAME=\(service))"
            + "(CID=(PROGRAM=TableRoad)(HOST=\(machine))(USER=\(user)))))"
    }

    static func descriptorValue(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: "(\(key)=", options: .caseInsensitive),
            let end = text[range.upperBound...].firstIndex(of: ")")
        else { return nil }
        return String(text[range.upperBound..<end])
    }

    static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func sendConnect(_ connectData: String, flags: UInt8) async throws {
        let data = Array(connectData.utf8)
        var w = WireWriter()
        w.u16(TNS.versionDesired)
        w.u16(TNS.versionMinimum)
        let urgent = transport?.supportsUrgentData == true
        w.u16(0x0001 | (urgent ? 0x0400 : 0))  // service options: don't care, can receive attention (OOB)
        w.u16(UInt16(clamping: Self.requestedSDU))
        w.u16(UInt16(clamping: Self.requestedSDU))
        w.u16(0x4f98)  // protocol characteristics
        w.u16(0)  // line turnaround
        w.u16(1)  // value of 1
        w.u16(UInt16(data.count))
        w.u16(74)  // offset to connect data
        w.u32(0)  // max receivable data
        w.u8(0x84)  // NSI flags: security renegotiation, no network authentication
        w.u8(0x84)
        w.u64(0)
        w.u64(0)
        w.u64(0)
        w.u32(UInt32(Self.requestedSDU))  // SDU (large)
        w.u32(UInt32(Self.requestedSDU))  // TDU (large)
        w.u32(0)  // connect flags 1
        w.u32(urgent ? 1 : 0)  // connect flags 2: check OOB
        if data.count <= 230 {
            w.raw(data)
            try await sendPacket(type: TNS.connect, flags: flags, body: w.bytes)
        } else {
            try await sendPacket(type: TNS.connect, flags: flags, body: w.bytes)
            try await sendPacket(type: TNS.data, flags: 0, body: [0, 0] + data)
        }
    }

    private func handleAccept(_ body: [UInt8]) throws {
        var r = WireReader(body)
        let version = try r.u16()
        guard version >= TNS.versionMinAccepted else {
            throw DatabaseError(.connection, "Oracle Database 12.1 or later is required.")
        }
        let options = try r.u16()
        try r.skip(20)
        let acceptedSDU = Int(try r.u32())
        var flags: UInt32 = 0
        if version >= TNS.versionMinOOBCheck {
            try r.skip(5)
            flags = try r.u32()
        }
        protocolVersion = version
        supportsOutOfBand = transport?.supportsUrgentData == true && options & 0x0400 != 0
        checkOutOfBand = supportsOutOfBand && flags & 0x01 != 0
        sdu = acceptedSDU > 0 ? acceptedSDU : 8192
        largePackets = version >= TNS.versionMinLargeSDU
        serverOffersEndOfResponse =
            !disableEndOfResponse && version >= TNS.versionMinEndOfResponse
            && flags & TNS.acceptFlagEndOfResponse != 0
    }

    private func refusal(_ body: [UInt8], endpoint: OracleEndpoint) -> DatabaseError {
        var message = ""
        if body.count > 4 {
            let length = Int(body[2]) << 8 | Int(body[3])
            message = String(decoding: body.dropFirst(4).prefix(length), as: UTF8.self)
        }
        let code = Self.descriptorValue("ERR", in: message).flatMap { Int($0) }
        switch code {
        case 12514:
            return DatabaseError(
                .connection,
                "The listener doesn't know service \(endpoint.serviceName). Put the service name (e.g. FREEPDB1) "
                    + "in the connection's database field.", code: 12514)
        case 12505:
            return DatabaseError(.connection, "The listener doesn't know that SID.", code: 12505)
        default:
            return DatabaseError(.connection, "The listener refused the connection (TNS-\(code ?? 0)).", code: code)
        }
    }

    // MARK: Protocol, data types and capabilities

    private func negotiateSession() async throws {
        if checkOutOfBand {
            // Show the server that urgent data works on this connection (it resets and carries on).
            transport?.sendUrgent()
            try await sendMarker(TNS.markerReset)
        }
        var w = WireWriter()
        w.u8(TNS.msgProtocol)
        w.u8(6)  // protocol version 8.1+
        w.u8(0)
        w.raw(Array("TableRoad".utf8))
        w.u8(0)
        let info = try await request(w.bytes, kind: .protocolNegotiation)
        charsetID = info.serverCharset
        ncharsetID = info.serverNCharset
        banner = info.serverBanner
        let compile = info.serverCompileCaps
        if compile.count > 7, compile[7] < fieldVersion { fieldVersion = compile[7] }
        if fieldVersion < TNS.fieldVersion234 { serverOffersEndOfResponse = false }
        let runtime = info.serverRuntimeCaps
        maxStringSize = runtime.count > 6 && runtime[6] & 0x04 != 0 ? 32767 : 4000
        // Database-charset text arrives converted to the AL32UTF8 we declare; national text stays in the national
        // character set (AL16UTF16 normally, UTF8 on some old databases).
        try await sendDataTypes()
    }

    private func sendDataTypes() async throws {
        var w = WireWriter()
        w.u8(TNS.msgDataTypes)
        w.u16le(TNS.charsetUTF8)
        w.u16le(TNS.charsetUTF8)
        w.u8(0x01 | 0x02)  // multi-byte, convert lengths
        w.bytesWithLength(compileCapabilities())
        w.bytesWithLength(runtimeCapabilities())
        for (type, conversion, representation) in OracleDataTypes.all {
            w.u16(type)
            w.u16(conversion)
            w.u16(representation)
            w.u16(0)
        }
        w.u16(0)
        _ = try await request(w.bytes, kind: .dataTypes)
        explicitEndOfResponse = serverOffersEndOfResponse
    }

    private func compileCapabilities() -> [UInt8] {
        var caps = [UInt8](repeating: 0, count: 51)
        caps[0] = 6  // SQL version
        caps[4] = 0x08 | 0x02 | 0x20 | 0x40 | 0x80  // O5LOGON, O5LOGON_NP, O7LOGON, long identifiers, long passwords
        caps[5] = 0x08  // implicit pool
        caps[7] = fieldVersion
        caps[8] = 1  // server define conversion
        caps[15] = 0x20 | 0x01 | 0x08  // fast bit vectors, end of call status, indicator records
        caps[16] = 0x10 | 0x80  // fast session propagate, application context piggyback
        caps[17] = 3  // TDS version
        caps[18] = 7  // RPC version
        caps[19] = 3  // RPC signature
        caps[21] = 1  // DBF version
        caps[23] = 0x01 | 0x02 | 0x40 | 0x08 | 0x80 | 0x04  // LOB: ub8 sizes, encodings, prefetch, 12c
        caps[26] = 0x04  // zero-length non-padded
        caps[27] = 1  // ub2 data types
        caps[31] = 0x10  // DRCP
        caps[34] = 12  // client functions
        caps[37] = 0x10 | 0x20 | 0x80  // implicit results, big chunk CLR, keep out of order
        caps[40] = 0x04 | (serverOffersEndOfResponse ? 0x20 : 0)  // in-band notifications, end of response
        caps[42] = 0x01 | 0x04  // quasi LOBs, 2GB prefetch
        return caps
    }

    private func runtimeCapabilities() -> [UInt8] {
        var caps = [UInt8](repeating: 0, count: 11)
        caps[0] = 2  // 8.1 compatible
        caps[6] = 0x01 | 0x04  // zero copy, 32K strings
        return caps
    }

    // MARK: Authentication

    func authenticate(user: String, password: String) async throws {
        var one = WireWriter()
        writeAuthHeader(&one, function: TNS.funcAuthPhaseOne, user: user, mode: 0x01, pairs: 5)
        one.keyValue("AUTH_TERMINAL", "unknown")
        one.keyValue("AUTH_PROGRAM_NM", "TableRoad")
        one.keyValue("AUTH_MACHINE", Self.hostName())
        one.keyValue("AUTH_PID", String(getpid()))
        one.keyValue("AUTH_SID", NSUserName())
        let challenge = try await request(one.bytes, kind: .auth)
        try throwIfFailed(challenge, authentication: true)

        let response = try OracleAuth.respond(
            password: password, verifierType: challenge.verifierType, session: challenge.parameters)
        var two = WireWriter()
        let pairs = 6 + (response.speedyKey == nil ? 0 : 1)
        writeAuthHeader(&two, function: TNS.funcAuthPhaseTwo, user: user, mode: 0x01 | 0x100, pairs: pairs)
        two.keyValue("AUTH_SESSKEY", response.sessionKey, flags: 1)
        if let speedy = response.speedyKey { two.keyValue("AUTH_PBKDF2_SPEEDY_KEY", speedy) }
        two.keyValue("AUTH_PASSWORD", response.encodedPassword)
        two.keyValue("SESSION_CLIENT_CHARSET", "873")
        two.keyValue("SESSION_CLIENT_DRIVER_NAME", "TableRoad thn : 1.0")
        two.keyValue("SESSION_CLIENT_VERSION", String(1 << 24))
        two.keyValue("AUTH_ALTER_SESSION", "ALTER SESSION SET TIME_ZONE='\(Self.localTimeZoneOffset())'\0", flags: 1)
        let result = try await request(two.bytes, kind: .auth)
        try throwIfFailed(result, authentication: true)
        sessionData = challenge.parameters.merging(result.parameters) { $1 }
    }

    private func writeAuthHeader(_ w: inout WireWriter, function: UInt8, user: String, mode: UInt32, pairs: Int) {
        let userBytes = Array(user.utf8)
        writeFunctionCode(&w, function)
        w.u8(userBytes.isEmpty ? 0 : 1)
        w.ub4(userBytes.count)
        w.ub(UInt64(mode))
        w.u8(1)
        w.ub4(pairs)
        w.u8(1)
        w.u8(1)
        if !userBytes.isEmpty { w.bytesWithLength(userBytes) }
    }

    static func localTimeZoneOffset() -> String {
        let seconds = TimeZone.current.secondsFromGMT()
        let sign = seconds < 0 ? "-" : "+"
        return String(format: "%@%02d:%02d", sign, abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
    }

    /// The server version from the logon reply, e.g. `23.26.0.0.0`.
    var serverVersion: String {
        guard let number = sessionData["AUTH_VERSION_NO"].flatMap({ UInt32($0) }) else { return "" }
        let parts: [UInt32]
        if fieldVersion >= TNS.fieldVersion181Ext1 {
            parts = [number >> 24 & 0xff, number >> 16 & 0xff, number >> 12 & 0x0f, number >> 4 & 0xff, number & 0x0f]
        } else {
            parts = [number >> 24 & 0xff, number >> 20 & 0x0f, number >> 12 & 0x0f, number >> 8 & 0x0f, number & 0x0f]
        }
        return parts.map(String.init).joined(separator: ".")
    }

    // MARK: Statements

    /// Parses and executes `sql`; for queries, fetches every row. LOB columns are re-defined as LONG / LONG RAW so
    /// their contents arrive inline.
    func execute(_ sql: String, isQuery: Bool, isPLSQL: Bool, commit: Bool, maxRows: Int? = nil) async throws
        -> OracleStatementResult
    {
        var options = TNS.execParse | TNS.execExecute
        if !isPLSQL { options |= TNS.execNotPLSQL }
        if commit { options |= TNS.execCommit }
        if isQuery { options |= TNS.execFetch }
        var w = WireWriter()
        writeExecute(
            &w, options: options, cursorID: 0, sql: Array(sql.utf8), iterations: isQuery ? Self.fetchSize : 1,
            isQuery: isQuery, defines: nil)
        var response = try await request(w.bytes, kind: .statement)
        let cursorID = response.error.cursorID
        defer { if cursorID != 0 { cursorsToClose.append(cursorID) } }
        try throwIfFailed(response)
        guard isQuery, var columns = response.columns else {
            return OracleStatementResult(columns: nil, rows: [], rowCount: response.error.rowCount)
        }

        var rows = response.rows
        var finished = response.error.number == TNS.errNoDataFound
        if columns.contains(where: \.needsDefine) {
            // Ask for LOBs as inline LONG data; the define re-positions the cursor, so rows start again.
            for index in columns.indices { columns[index].fetchType = Self.defineType(columns[index]) }
            var define = WireWriter()
            writeExecute(
                &define, options: TNS.execDefine | TNS.execNotPLSQL, cursorID: cursorID, sql: nil,
                iterations: Self.fetchSize, isQuery: true, defines: columns)
            response = try await request(define.bytes, kind: .statement, columns: columns)
            try throwIfFailed(response)
            rows = response.rows
            finished = response.error.number == TNS.errNoDataFound
        }
        var previous = rows.last
        while !finished && rows.count < (maxRows ?? .max) {
            var fetch = WireWriter()
            writeFunctionCode(&fetch, TNS.funcFetch)
            fetch.ub4(Int(cursorID))
            fetch.ub4(Self.fetchSize)
            let batch = try await request(fetch.bytes, kind: .statement, columns: columns, previousRow: previous)
            try throwIfFailed(batch)
            rows += batch.rows
            previous = rows.last
            finished = batch.error.number == TNS.errNoDataFound || batch.rows.isEmpty
        }
        if let maxRows, rows.count > maxRows { rows.removeLast(rows.count - maxRows) }
        return OracleStatementResult(columns: columns, rows: rows, rowCount: UInt64(rows.count))
    }

    /// How a column is defined for fetching: LOBs as LONG / LONG RAW (contents inline), everything else as-is.
    static func defineType(_ column: OracleColumn) -> UInt8 {
        switch column.type {
        case OracleType.clob: OracleType.long
        case OracleType.blob: OracleType.longRaw
        default: column.type
        }
    }

    private func writeExecute(
        _ w: inout WireWriter, options: UInt32, cursorID: UInt16, sql: [UInt8]?, iterations: Int, isQuery: Bool,
        defines: [OracleColumn]?
    ) {
        if !cursorsToClose.isEmpty {
            // Piggyback: close cursors from earlier statements.
            w.u8(TNS.msgPiggyback)
            w.u8(TNS.funcCloseCursors)
            writeSequence(&w)
            w.u8(1)
            w.ub4(cursorsToClose.count)
            for id in cursorsToClose { w.ub4(Int(id)) }
            cursorsToClose = []
        }
        writeFunctionCode(&w, TNS.funcExecute)
        w.ub(UInt64(options))
        w.ub4(Int(cursorID))
        if let sql {
            w.u8(1)
            w.ub4(sql.count)
        } else {
            w.u8(0)
            w.ub4(0)
        }
        w.u8(1)  // pointer (vector)
        w.ub4(13)  // al8i4 length
        w.u8(0)  // pointer (al8o4)
        w.u8(0)  // pointer (al8o4l)
        w.ub4(0)  // prefetch buffer size
        w.ub4(iterations)  // prefetch rows
        w.ub(UInt64(TNS.maxLongLength))  // maximum LONG size
        w.u8(0)  // pointer (binds)
        w.ub4(0)  // number of binds
        for _ in 0..<5 { w.u8(0) }  // al8app, al8txn, al8txl, al8kv, al8kvl
        if let defines {
            w.u8(1)
            w.ub4(defines.count)
        } else {
            w.u8(0)
            w.ub4(0)
        }
        w.ub4(0)  // registration id
        w.u8(0)  // pointer (al8objlist)
        w.u8(1)  // pointer (al8objlen)
        w.u8(0)  // pointer (al8blv)
        w.ub4(0)
        w.u8(0)  // pointer (al8dnam)
        w.ub4(0)
        w.ub4(0)  // al8regid_msb
        w.u8(0)  // pointer (DML row counts)
        w.ub4(0)
        w.u8(0)
        if fieldVersion >= TNS.fieldVersion122 {
            w.u8(0)  // pointer (SQL signature)
            w.ub4(0)
            w.u8(0)  // pointer (SQL ID)
            w.ub4(0)
            w.u8(0)
            if fieldVersion >= TNS.fieldVersion122Ext1 {
                w.u8(0)  // pointer (chunk ids)
                w.ub4(0)
            }
        }
        if let sql {
            w.bytesWithLength(sql)
            w.ub4(1)  // al8i4[0] parse
        } else {
            w.ub4(0)
        }
        w.ub4(isQuery ? (cursorID == 0 ? 0 : iterations) : 1)  // al8i4[1] execution count
        for _ in 0..<5 { w.ub4(0) }  // al8i4[2...6]
        w.ub4(isQuery ? 1 : 0)  // al8i4[7] is query
        for _ in 0..<5 { w.ub4(0) }  // al8i4[8...12]
        for column in defines ?? [] { writeDefine(&w, column) }
    }

    private func writeDefine(_ w: inout WireWriter, _ column: OracleColumn) {
        let type = column.fetchType
        var bufferSize = column.bufferSize
        var continuation: UInt64 = 0
        var prefetch: UInt32 = 0
        switch type {
        case OracleType.long, OracleType.longRaw: bufferSize = TNS.maxLongLength
        case OracleType.json:
            continuation = 0x200_0000
            bufferSize = 32 * 1024 * 1024
            prefetch = bufferSize
        case OracleType.vector:
            continuation = 0x200_0000
            bufferSize = 1024 * 1024
            prefetch = bufferSize
        default: break
        }
        w.u8(type)
        w.u8(0x01)  // use indicators
        w.u8(0)  // precision and scale are always sent as zero
        w.u8(0)
        w.ub(UInt64(bufferSize > UInt32(maxStringSize) ? TNS.maxLongLength : bufferSize))
        w.ub4(0)  // max array elements
        w.ub(continuation)
        w.ub4(0)  // OID
        w.ub4(0)  // version
        w.ub4(column.csfrm != 0 ? Int(TNS.charsetUTF8) : 0)
        w.u8(column.csfrm)
        w.ub(UInt64(prefetch))
        if fieldVersion >= TNS.fieldVersion122 { w.ub4(0) }  // oaccolid
    }

    func commit() async throws {
        var w = WireWriter()
        writeFunctionCode(&w, TNS.funcCommit)
        try throwIfFailed(try await request(w.bytes, kind: .simple))
    }

    func rollback() async throws {
        var w = WireWriter()
        writeFunctionCode(&w, TNS.funcRollback)
        try throwIfFailed(try await request(w.bytes, kind: .simple))
    }

    func ping() async throws {
        var w = WireWriter()
        writeFunctionCode(&w, TNS.funcPing)
        try throwIfFailed(try await request(w.bytes, kind: .simple))
    }

    /// Logs off and closes the socket (best effort).
    func close() async {
        if !isBroken {
            var w = WireWriter()
            writeFunctionCode(&w, TNS.funcLogoff)
            _ = try? await request(w.bytes, kind: .simple)
            try? await sendPacket(type: TNS.data, flags: 0, body: [0, UInt8(TNS.dataFlagEOF)])
        }
        closeTransport()
    }

    private func closeTransport() {
        isBroken = true
        transport?.close()
    }

    /// Asks the server to stop the running call: TCP urgent data when the server accepts it, else an in-band
    /// interrupt marker (noticed while SQL runs, but not during e.g. DBMS_SESSION.SLEEP). An interrupted call fails
    /// with ORA-01013.
    func interrupt() async {
        guard awaitingResponse, !interruptSent, !isBroken else { return }
        interruptSent = true
        if supportsOutOfBand {
            transport?.sendUrgent()
        } else {
            try? await sendMarker(TNS.markerInterrupt)
        }
    }

    private func writeFunctionCode(_ w: inout WireWriter, _ function: UInt8) {
        w.u8(TNS.msgFunction)
        w.u8(function)
        writeSequence(&w)
    }

    private func writeSequence(_ w: inout WireWriter) {
        sequence = sequence == 255 ? 1 : sequence + 1
        w.u8(sequence)
        if fieldVersion >= TNS.fieldVersion231Ext1 { w.ub(0) }  // token number
    }

    private func throwIfFailed(_ response: OracleResponse, authentication: Bool = false) throws {
        guard response.failed else { return }
        let code = Int(response.error.number)
        let message = response.error.message ?? "ORA-\(String(format: "%05d", code))"
        let category: DatabaseError.Category =
            switch code {
            case 1013: .cancelled
            case 1017, 1005, 28000, 28001, 1045: .authentication
            case 3113, 3114, 3135, 12537, 12547, 28: .connection
            default: authentication ? .authentication : .query
            }
        if category == .connection { isBroken = true }
        throw DatabaseError(category, message, code: code)
    }

    // MARK: Request / response

    /// Sends one request and reads its whole response.
    private func request(
        _ payload: [UInt8], kind: OracleRequestKind, columns: [OracleColumn]? = nil, previousRow: [CellValue]? = nil
    ) async throws -> OracleResponse {
        guard !isBroken else { throw DatabaseError(.connection, "The connection to the server was lost.") }
        do {
            try await sendData(payload)
            awaitingResponse = true
            interruptSent = false
            markerSeen = false
            var response = OracleResponse(kind: kind, fieldVersion: fieldVersion, explicitEnd: explicitEndOfResponse)
            response.nationalUTF16 = ncharsetID != 871 && ncharsetID != 873
            response.columns = columns
            response.previousRow = previousRow
            defer { awaitingResponse = false }
            try await receive(into: &response)
            awaitingResponse = false
            if interruptSent && !markerSeen {
                // The call finished before the break took effect; the server still answers it (with a break and
                // ORA-01013), which must be read now so it can't hit the next call.
                if supportsOutOfBand { try await sendMarker(TNS.markerInterrupt) }
                var discarded = OracleResponse(
                    kind: .simple, fieldVersion: fieldVersion, explicitEnd: explicitEndOfResponse)
                try await receive(into: &discarded)
            }
            transactionInProgress = response.callStatus & TNS.callStatusTransactionInProgress != 0
            if let schema = response.currentSchema { currentSchema = schema }
            return response
        } catch let error as DatabaseError {
            throw error
        } catch let error as OracleProtocolError {
            closeTransport()
            throw DatabaseError(.connection, "Oracle protocol error: \(error.description)")
        }
    }

    private func receive(into response: inout OracleResponse) async throws {
        var payload: [UInt8] = []
        var committed = 0
        var needed = 0
        var pending: Packet?
        while true {
            let packet: Packet
            if let next = pending {
                packet = next
                pending = nil
            } else {
                packet = try await readPacket()
            }
            var complete = false
            switch packet.type {
            case TNS.data:
                guard packet.body.count >= 2 else { continue }
                let flags = UInt16(packet.body[0]) << 8 | UInt16(packet.body[1])
                payload.append(contentsOf: packet.body.dropFirst(2))
                if flags & TNS.dataFlagEOF != 0 {
                    isBroken = true
                    complete = true
                }
                if flags & TNS.dataFlagEndOfResponse != 0 { complete = true }
                if packet.body.count == 3 && packet.body[2] == TNS.msgEndOfResponse { complete = true }
            case TNS.marker:
                // The server broke off the call (an error or our interrupt): reset, then read the real response.
                markerSeen = true
                pending = try await resetAfterMarker(packet)
                payload = []
                committed = 0
                needed = 0
                continue
            case TNS.control:
                if packet.body.count >= 10 {
                    var r = WireReader(packet.body)
                    let controlType = try r.u16()
                    if controlType == 8 {
                        try r.skip(4)
                        let error = try r.u32()
                        if error == 12572 || error == 12573 { isBroken = true }
                    }
                }
                continue
            default:
                throw OracleProtocolError("unexpected packet type \(packet.type)")
            }
            if explicitEndOfResponse && !complete { continue }
            if payload.count < needed && !complete { continue }
            var reader = WireReader(payload, position: committed)
            do {
                try response.process(&reader, committed: &committed)
                if !response.done && !explicitEndOfResponse && !complete { continue }
                return
            } catch let more as NeedMoreData {
                if complete || explicitEndOfResponse {
                    if isBroken { throw DatabaseError(.connection, "The server closed the connection.") }
                    throw OracleProtocolError("response ended early")
                }
                needed = more.needed
            }
        }
    }

    /// After a break marker: send a reset marker, skip packets until the server's reset marker arrives.
    /// After a marker: send a reset marker, skip packets until the server's reset marker (unless the marker that
    /// arrived was already one), then skip any further markers. Returns the first packet of the real response.
    private func resetAfterMarker(_ marker: Packet) async throws -> Packet {
        try await sendMarker(TNS.markerReset)
        func isReset(_ packet: Packet) -> Bool {
            packet.type == TNS.marker && packet.body.count >= 3 && packet.body[2] == TNS.markerReset
        }
        if !isReset(marker) {
            while !isReset(try await readPacket()) {}
        }
        while true {
            let packet = try await readPacket()
            if packet.type != TNS.marker { return packet }
        }
    }

    private func sendMarker(_ type: UInt8) async throws {
        try await sendPacket(type: TNS.marker, flags: 0, body: [1, 0, type])
    }

    // MARK: Packets

    struct Packet {
        var type: UInt8
        var flags: UInt8
        var body: [UInt8]
    }

    /// Sends a TTC payload in as many data packets as the SDU requires.
    private func sendData(_ payload: [UInt8], dataFlags: UInt16 = 0) async throws {
        let maxChunk = max(sdu - TNS.headerSize - 2, 256)
        var offset = 0
        repeat {
            let end = min(offset + maxChunk, payload.count)
            let body = [UInt8(dataFlags >> 8), UInt8(dataFlags & 0xff)] + payload[offset..<end]
            try await sendPacket(type: TNS.data, flags: 0, body: body)
            offset = end
        } while offset < payload.count
    }

    private func sendPacket(type: UInt8, flags: UInt8, body: [UInt8]) async throws {
        var w = WireWriter()
        let length = body.count + TNS.headerSize
        if largePackets {
            w.u32(UInt32(length))
        } else {
            w.u16(UInt16(length))
            w.u16(0)
        }
        w.u8(type)
        w.u8(flags)
        w.u16(0)
        w.raw(body)
        if Self.tracePackets { Self.trace("send", w.bytes) }
        try await send(Data(w.bytes))
    }

    private func readPacket() async throws -> Packet {
        try await fill(TNS.headerSize)
        let header = inbox[inboxStart..<(inboxStart + TNS.headerSize)]
        let h = Array(header)
        let length: Int =
            largePackets
            ? Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            : Int(h[0]) << 8 | Int(h[1])
        guard length >= TNS.headerSize else { throw OracleProtocolError("bad packet length \(length)") }
        try await fill(length)
        let packet = Packet(
            type: h[4], flags: h[5], body: Array(inbox[(inboxStart + TNS.headerSize)..<(inboxStart + length)]))
        if Self.tracePackets { Self.trace("recv", Array(inbox[inboxStart..<(inboxStart + length)])) }
        inboxStart += length
        if inboxStart > 1 << 16 {
            inbox.removeFirst(inboxStart)
            inboxStart = 0
        }
        return packet
    }

    private func fill(_ count: Int) async throws {
        while inbox.count - inboxStart < count {
            inbox.append(contentsOf: try await receiveChunk())
        }
    }

    /// Set TABLEROAD_ORACLE_TRACE=1 to dump packets to stderr while debugging the protocol.
    static let tracePackets = ProcessInfo.processInfo.environment["TABLEROAD_ORACLE_TRACE"] != nil

    static func trace(_ direction: String, _ bytes: [UInt8]) {
        var lines = ["\(direction) \(bytes.count) bytes"]
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            lines.append(
                String(format: "%04d", offset) + " : " + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + " |"
                    + ascii + "|")
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        // A path in the variable appends there; anything else writes to stderr.
        if let path = ProcessInfo.processInfo.environment["TABLEROAD_ORACLE_TRACE"], path.hasPrefix("/"),
            let file = FileHandle(forWritingAtPath: path)
                ?? {
                    FileManager.default.createFile(atPath: path, contents: nil)
                    return FileHandle(forWritingAtPath: path)
                }()
        {
            file.seekToEndOfFile()
            file.write(data)
            try? file.close()
        } else {
            FileHandle.standardError.write(data)
        }
    }

    // MARK: Transport

    private func connectTransport(host: String, port: Int, useTLS: Bool) async throws {
        transport?.close()
        transport =
            useTLS
            ? try await TLSTransport.connect(host: host, port: port)
            : try await SocketTransport.connect(host: host, port: port)
        inbox = []
        inboxStart = 0
    }

    private func send(_ data: Data) async throws {
        guard let transport else { throw DatabaseError(.connection, "Not connected.") }
        try await transport.send(data)
    }

    private func receiveChunk() async throws -> [UInt8] {
        guard let transport else { throw DatabaseError(.connection, "Not connected.") }
        do {
            return try await transport.receive()
        } catch {
            isBroken = true
            throw error
        }
    }
}
