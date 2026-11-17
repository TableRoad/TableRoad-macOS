import Foundation
import Testing

@testable import TableRoadCore

struct JSONValueTests {
    let source =
        #"{"vodafone":{"account_number":null,"crm_data_source_id":11,"create_new_account":true},"n":1.10,"s":"a\"b\né 😀","list":[1,[],{}]}"#

    @Test func keepsKeyOrderAndNumberText() throws {
        let value = try JSONValue.parse(source)
        guard case .object(let members) = value else {
            Issue.record("expected object")
            return
        }
        #expect(members.map(\.key) == ["vodafone", "n", "s", "list"])
        #expect(members[1].value == .number("1.10"))
        #expect(members[2].value == .string("a\"b\né 😀"))
        guard case .object(let inner) = members[0].value else {
            Issue.record("expected object")
            return
        }
        #expect(inner.map(\.key) == ["account_number", "crm_data_source_id", "create_new_account"])
    }

    @Test func minifyRoundTrips() throws {
        let value = try JSONValue.parse(source)
        #expect(try JSONValue.parse(value.minified) == value)
        #expect(value.minified.hasPrefix(#"{"vodafone":{"account_number":null,"crm_data_source_id":11,"#))
    }

    @Test func prettyIndents() throws {
        let pretty = try JSONValue.parse(#"{"a":{"b":[1,2]},"c":{}}"#).pretty(indent: 4)
        #expect(
            pretty == """
                {
                    "a": {
                        "b": [
                            1,
                            2
                        ]
                    },
                    "c": {}
                }
                """)
        #expect(try JSONValue.parse(pretty) == JSONValue.parse(#"{"a":{"b":[1,2]},"c":{}}"#))
    }

    @Test(arguments: [#"{"a":}"#, "[1,]", #"{"a" 1}"#, "tru", "01x", #""unterminated"#, "{} extra"])
    func rejectsInvalid(_ text: String) {
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse(text) }
    }

    @Test func childrenForOutline() throws {
        let value = try JSONValue.parse(#"[{"x":1},"y"]"#)
        #expect(value.children?.map(\.label) == ["[0]", "[1]"])
        #expect(value.children?[1].value.scalarText == "y")
        #expect(value.children?[0].value.typeName == "object")
    }
}
