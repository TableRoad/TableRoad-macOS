import Darwin
import Foundation
import TableRoadCore
import Testing

@testable import TableRoadRedis

struct RESPParserTests {
    @Test func parsesNestedAndPartialReplies() throws {
        let full = Data("*3\r\n$3\r\nfoo\r\n:42\r\n*2\r\n+OK\r\n$-1\r\n".utf8)
        for cut in 0..<full.count {
            var index = full.startIndex
            #expect(try RESPParser.parse(full.prefix(cut), at: &index) == nil, "cut at \(cut)")
        }
        var index = full.startIndex
        let value = try RESPParser.parse(full, at: &index)
        #expect(value == .array([.bulk(Data("foo".utf8)), .integer(42), .array([.simple("OK"), .bulk(nil)])]))
        #expect(index == full.endIndex)
    }

    @Test func consoleArguments() {
        #expect(RedisSession.arguments(#"SET "my key" 'a b' plain"#) == ["SET", "my key", "a b", "plain"])
        #expect(RedisSession.arguments(#"SET k "line\nbreak" """#) == ["SET", "k", "line\nbreak", ""])
    }

    @Test func formatting() {
        #expect(RESPValue.array([.bulk(Data("a".utf8)), .integer(1)]).formatted() == "1) \"a\"\n2) (integer) 1")
    }
}

@Suite(.enabled(if: RedisServer.available, "Start the redis service in docker/compose.yml"), .serialized)
struct RedisSessionTests {
    let config = RedisConnectConfig(host: "127.0.0.1", port: 16379, password: "tableroad", database: 3)

    @Test func connectBrowseAndReadEveryType() async throws {
        let redis = try await RedisSession.connect(config)
        #expect(await redis.serverVersion.hasPrefix("7"))
        await #expect {
            _ = try await RedisSession.connect(RedisConnectConfig(host: "127.0.0.1", port: 16379, password: "nope"))
        } throws: { ($0 as? DatabaseError)?.category == .authentication }

        let prefix = "tr:\(UUID().uuidString.prefix(8)):"
        try await redis.command(["SET", prefix + "s", "hello world"])
        try await redis.command(["EXPIRE", prefix + "s", "600"])
        try await redis.command(["HSET", prefix + "h", "b", "2", "a", "1"])
        try await redis.command(["RPUSH", prefix + "l", "x", "y", "z"])
        try await redis.command(["SADD", prefix + "set", "m", "n"])
        try await redis.command(["ZADD", prefix + "z", "2", "two", "1", "one"])
        try await redis.command(["XADD", prefix + "x", "*", "field", "value"])
        for i in 0..<1200 { try await redis.command(["SET", prefix + "bulk:\(i)", "\(i)"]) }

        let (keys, truncated) = try await redis.scan(pattern: prefix + "*", limit: 5000)
        #expect(!truncated)
        #expect(keys.count == 1206)
        let byName = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })
        #expect(byName[prefix + "s"]?.type == "string")
        #expect((byName[prefix + "s"]?.ttl ?? 0) > 500)
        #expect(byName[prefix + "h"]?.ttl == nil)
        #expect(try await redis.scan(pattern: prefix + "*", limit: 10).truncated)

        #expect(try await redis.value(of: prefix + "s") == .string("hello world"))
        #expect(try await redis.value(of: prefix + "h") == .hash([("a", "1"), ("b", "2")]))
        #expect(try await redis.value(of: prefix + "l") == .list(["x", "y", "z"]))
        #expect(try await redis.value(of: prefix + "set") == .set(["m", "n"]))
        #expect(try await redis.value(of: prefix + "z") == .zset([("one", "1"), ("two", "2")]))
        if case .stream(let entries) = try await redis.value(of: prefix + "x") {
            #expect(entries.first?.fields.first?.0 == "field")
        } else {
            Issue.record("expected stream")
        }
        #expect(try await redis.value(of: prefix + "missing") == .missing)
        #expect(try await redis.rawCommand(["NOTACOMMAND"]).formatted().hasPrefix("(error)"))
        #expect((try await redis.info())["redis_version"] != nil)

        // Clean up with UNLINK in batches.
        let names = keys.map(\.name)
        for start in stride(from: 0, to: names.count, by: 500) {
            try await redis.command(["UNLINK"] + names[start..<min(start + 500, names.count)])
        }
        await redis.close()
    }
}

enum RedisServer {
    static let available: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(16379).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()
}
