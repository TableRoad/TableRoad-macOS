import Foundation
import Testing

@testable import TableRoadCore

@Suite struct ValueFormattingTests {
    @Test func prettyJSON() {
        #expect(
            ValueFormatting.prettyJSON(#"{"b":1,"a":[true,null],"url":"https://x/y"}"#) == """
                {
                  "a" : [
                    true,
                    null
                  ],
                  "b" : 1,
                  "url" : "https://x/y"
                }
                """)
        #expect(ValueFormatting.prettyJSON("42") == "42")
        #expect(ValueFormatting.prettyJSON("{not json") == nil)
    }

    @Test func jsonError() {
        #expect(ValueFormatting.jsonError(#"{"ok": 1}"#) == nil)
        #expect(ValueFormatting.jsonError(#"{"ok": }"#) != nil)
    }

    @Test func hexDump() {
        let data = Data("Hello, TableRoad!\u{0}\u{1}".utf8)
        let dump = ValueFormatting.hexDump(data)
        let lines = dump.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "00000000  48 65 6C 6C 6F 2C 20 54 61 62 6C 65 52 6F 61 64  Hello, TableRoad")
        #expect(lines[1].hasPrefix("00000010  21 00 01"))
        #expect(lines[1].hasSuffix("!.."))
        #expect(ValueFormatting.hexDump(Data(repeating: 0, count: 40), limit: 16).hasSuffix("… 24 more bytes"))
    }
}
