import Foundation
import TableRoadCore

/// Minimal streaming zip (deflate entries with data descriptors), enough for .xlsx. No zip64: entries over 4 GB fail.
final class ZipWriter {
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private struct Entry {
        var name: Data
        var crc: UInt32
        var compressed: UInt64
        var uncompressed: UInt64
        var headerOffset: UInt64
    }
    private var entries: [Entry] = []
    private var current: (name: Data, headerOffset: UInt64, crc: UInt32, compressed: UInt64, uncompressed: UInt64)?
    private var deflater: Deflater?

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private func emit(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    func beginEntry(_ name: String) throws {
        let nameData = Data(name.utf8)
        var header = Data()
        header.le32(0x0403_4B50)
        header.le16(20)  // version needed
        header.le16(0x0808)  // data descriptor + UTF-8 names
        header.le16(8)  // deflate
        header.le16(0)  // time
        header.le16(0x21)  // date (1980-01-01)
        header.le32(0)  // crc (in descriptor)
        header.le32(0)
        header.le32(0)
        header.le16(UInt16(nameData.count))
        header.le16(0)
        header.append(nameData)
        current = (nameData, offset, 0, 0, 0)
        try emit(header)
        deflater = try Deflater(gzip: false)
    }

    func write(_ data: Data) throws {
        guard var entry = current, let deflater else { return }
        entry.crc = CRC32.update(entry.crc, data)
        entry.uncompressed += UInt64(data.count)
        let out = try deflater.compress(data)
        entry.compressed += UInt64(out.count)
        current = entry
        try emit(out)
    }

    func endEntry() throws {
        guard var entry = current, let deflater else { return }
        let tail = try deflater.compress(Data(), finish: true)
        entry.compressed += UInt64(tail.count)
        try emit(tail)
        guard entry.compressed < UInt64(UInt32.max), entry.uncompressed < UInt64(UInt32.max) else {
            throw TransferError.fileTooLarge
        }
        var descriptor = Data()
        descriptor.le32(0x0807_4B50)
        descriptor.le32(entry.crc)
        descriptor.le32(UInt32(entry.compressed))
        descriptor.le32(UInt32(entry.uncompressed))
        try emit(descriptor)
        entries.append(
            Entry(
                name: entry.name, crc: entry.crc, compressed: entry.compressed, uncompressed: entry.uncompressed,
                headerOffset: entry.headerOffset))
        current = nil
        self.deflater = nil
    }

    func addEntry(_ name: String, _ text: String) throws {
        try beginEntry(name)
        try write(Data(text.utf8))
        try endEntry()
    }

    func finish() throws {
        let start = offset
        for entry in entries {
            var record = Data()
            record.le32(0x0201_4B50)
            record.le16(20)  // made by
            record.le16(20)
            record.le16(0x0808)
            record.le16(8)
            record.le16(0)
            record.le16(0x21)
            record.le32(entry.crc)
            record.le32(UInt32(entry.compressed))
            record.le32(UInt32(entry.uncompressed))
            record.le16(UInt16(entry.name.count))
            record.le16(0)  // extra
            record.le16(0)  // comment
            record.le16(0)  // disk
            record.le16(0)  // internal attrs
            record.le32(0)  // external attrs
            guard entry.headerOffset < UInt64(UInt32.max) else { throw TransferError.fileTooLarge }
            record.le32(UInt32(entry.headerOffset))
            record.append(entry.name)
            try emit(record)
        }
        let size = offset - start
        guard start < UInt64(UInt32.max) else { throw TransferError.fileTooLarge }
        var end = Data()
        end.le32(0x0605_4B50)
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(entries.count))
        end.le16(UInt16(entries.count))
        end.le32(UInt32(size))
        end.le32(UInt32(start))
        end.le16(0)
        try emit(end)
        try handle.close()
    }
}

extension Data {
    fileprivate mutating func le16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    fileprivate mutating func le32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Streams rows into an .xlsx workbook, one worksheet per table.
final class XLSXWriter {
    static let maxRows = 1_048_576
    static let maxCellLength = 32_767

    private let zip: ZipWriter
    private var sheetNames: [String] = []
    private var buffer = Data()
    private var rowsInSheet = 0
    private var currentSheet: String?

    init(url: URL) throws {
        zip = try ZipWriter(url: url)
    }

    func beginSheet(_ name: String, header: [String]?) throws {
        let sheetName = uniqueSheetName(name)
        sheetNames.append(sheetName)
        currentSheet = sheetName
        rowsInSheet = 0
        try zip.beginEntry("xl/worksheets/sheet\(sheetNames.count).xml")
        buffer.append(
            Data(
                ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                    + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>")
                    .utf8))
        if let header {
            try appendRow(header.map { .text($0) }, style: 1)
        }
    }

    func addRow(_ values: [CellValue]) throws { try appendRow(values, style: nil) }

    private func appendRow(_ values: [CellValue], style: Int?) throws {
        guard rowsInSheet < Self.maxRows else { throw TransferError.excelRowLimit(currentSheet ?? "") }
        rowsInSheet += 1
        var xml = "<row>"
        let s = style.map { " s=\"\($0)\"" } ?? ""
        for value in values {
            switch value {
            case .null:
                xml += "<c\(s)/>"
            case .bool(let flag):
                xml += "<c t=\"b\"\(s)><v>\(flag ? 1 : 0)</v></c>"
            case .int, .uint, .decimal:
                xml += "<c\(s)><v>\(value.displayText ?? "")</v></c>"
            case .double(let number) where number.isFinite:
                xml += "<c\(s)><v>\(number)</v></c>"
            default:
                var text = value.displayText ?? ""
                if text.count > Self.maxCellLength { text = String(text.prefix(Self.maxCellLength)) }
                xml += "<c t=\"inlineStr\"\(s)><is><t xml:space=\"preserve\">\(Self.escape(text))</t></is></c>"
            }
        }
        xml += "</row>"
        buffer.append(Data(xml.utf8))
        if buffer.count >= 1 << 20 { try flushBuffer() }
    }

    private func flushBuffer() throws {
        try zip.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func endSheet() throws {
        buffer.append(Data("</sheetData></worksheet>".utf8))
        try flushBuffer()
        try zip.endEntry()
        currentSheet = nil
    }

    func finish() throws {
        if sheetNames.isEmpty {
            try beginSheet("Sheet1", header: nil)
            try endSheet()
        }
        let sheets = sheetNames.enumerated()
        try zip.addEntry(
            "[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
                + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
                + sheets.map {
                    "<Override PartName=\"/xl/worksheets/sheet\($0.offset + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                }.joined()
                + "</Types>")
        try zip.addEntry(
            "_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
                + "</Relationships>")
        try zip.addEntry(
            "xl/workbook.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
                + sheets.map {
                    "<sheet name=\"\(Self.escape($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>"
                }.joined()
                + "</sheets></workbook>")
        try zip.addEntry(
            "xl/_rels/workbook.xml.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + sheets.map {
                    "<Relationship Id=\"rId\($0.offset + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0.offset + 1).xml\"/>"
                }.joined()
                + "<Relationship Id=\"rId\(sheetNames.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
                + "</Relationships>")
        // Style 1 = bold (header row).
        try zip.addEntry(
            "xl/styles.xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
                + "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
                + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
                + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
                + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
                + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
                + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs>"
                + "</styleSheet>")
        try zip.finish()
    }

    /// Excel sheet names: ≤ 31 characters, none of []:*?/\, unique (case-insensitive).
    private func uniqueSheetName(_ name: String) -> String {
        let cleaned = String(name.map { "[]:*?/\\".contains($0) ? "_" : $0 }.prefix(31))
        var candidate = cleaned.isEmpty ? "Sheet" : cleaned
        var counter = 2
        while sheetNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            let suffix = " (\(counter))"
            candidate = String(cleaned.prefix(31 - suffix.count)) + suffix
            counter += 1
        }
        return candidate
    }

    /// XML text: escapes markup and drops characters XML 1.0 can't contain.
    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "\t", "\n", "\r": output.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }
}
