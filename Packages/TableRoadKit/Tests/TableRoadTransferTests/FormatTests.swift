import Foundation
import TableRoadCore
import Testing

@testable import TableRoadTransfer

struct FormatTests {
    @Test func csvOptions() {
        var csv = CSVOptions()
        let row: [CellValue] = [.int(1), .decimal("2.50"), .null, .text("a,b"), .text("say \"hi\"\nthere")]
        #expect(csv.line(row) == "1,2.50,,\"a,b\",\"say \"\"hi\"\"\nthere\"")

        csv.nullAsEmpty = false
        csv.lineBreaksToSpace = true
        csv.delimiter = ";"
        csv.decimalSeparator = ","
        // With ";" as the delimiter, "2,50" and "a,b" need no quotes.
        #expect(csv.line(row) == "1;2,50;NULL;a,b;\"say \"\"hi\"\" there\"")

        csv.quoting = .always
        #expect(csv.headerLine(["id", "na\"me"]) == "\"id\";\"na\"\"me\"")
        csv.quoting = .never
        #expect(csv.line([.text("x;y")]) == "x;y")
    }

    @Test func jsonRowsKeepOrderAndTypes() throws {
        let element = JSONRows.element(
            columns: ["z", "a", "j", "b"], values: [.int(1), .null, .json(#"{"k":[1,2]}"#), .bytes(Data([1, 2]))])
        let value = try JSONValue.parse(element)
        guard case .object(let members) = value else {
            Issue.record("expected object")
            return
        }
        #expect(members.map(\.key) == ["z", "a", "j", "b"])
        #expect(members[2].value == JSONValue.object([.init(key: "k", value: .array([.number("1"), .number("2")]))]))
        #expect(members[3].value == .string("AQI="))
    }

    @Test func sqlDumpInsertsAreBatchedAndEscaped() {
        var dump = SQLDumpFormat(flavor: .mysql)
        dump.rowsPerInsert = 2
        let sql = dump.inserts(
            table: "t", columns: ["id", "v"],
            rows: [[.int(1), .text("a'b\\c")], [.int(2), .null], [.int(3), .bytes(Data([0xAB]))]])
        #expect(
            sql == """
                INSERT INTO `t` (`id`, `v`) VALUES
                (1, 'a''b\\\\c'),
                (2, NULL);
                INSERT INTO `t` (`id`, `v`) VALUES
                (3, X'AB');

                """)
        #expect(
            dump.create(
                "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1", isView: true)
                == "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `v` AS select 1;\n\n")
    }

    @Test func gzipRoundTrip() throws {
        let text = String(repeating: "INSERT INTO t VALUES (1, 'hello');\n", count: 5000)
        let deflater = try Deflater(gzip: true)
        var compressed = try deflater.compress(Data(text.utf8))
        compressed += try deflater.compress(Data(), finish: true)
        #expect(compressed.count < text.utf8.count / 10)
        #expect(compressed.prefix(2) == Data([0x1F, 0x8B]))
        let inflater = try Inflater()
        // Feed in small pieces to exercise streaming.
        var output = Data()
        var index = 0
        while index < compressed.count {
            output += try inflater.decompress(compressed[index..<min(index + 100, compressed.count)])
            index += 100
        }
        #expect(String(decoding: output, as: UTF8.self) == text)
    }

    @Test func xlsxIsAValidZipThatUnzipCanRead() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tableroad-\(UUID()).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XLSXWriter(url: url)
        try writer.beginSheet("orders", header: ["id", "note"])
        try writer.addRow([.int(1), .text("<b>&\u{01}")])
        try writer.addRow([.null, .bool(true)])
        try writer.endSheet()
        try writer.beginSheet("orders", header: nil)  // duplicate name → "orders (2)"
        try writer.endSheet()
        try writer.finish()

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", url.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let sheet = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
        #expect(sheet.contains("<v>1</v>"))
        #expect(sheet.contains("&lt;b&gt;&amp;</t>"))
        #expect(sheet.contains("<c t=\"b\"><v>1</v></c>"))

        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-t", url.path]
        test.standardOutput = Pipe()
        try test.run()
        test.waitUntilExit()
        #expect(test.terminationStatus == 0)
    }
}
