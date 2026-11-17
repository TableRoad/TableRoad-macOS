import Foundation
import zlib

public enum CompressionError: Error, CustomStringConvertible {
    case zlib(String, Int32)
    public var description: String {
        switch self {
        case .zlib(let step, let code): "Compression failed (\(step), zlib error \(code))."
        }
    }
}

/// Streaming deflate: gzip files (`.sql.gz`) or raw deflate (zip entries).
final class Deflater {
    private var stream = z_stream()

    init(gzip: Bool, level: Int32 = 6) throws {
        let status = deflateInit2_(
            &stream, level, Z_DEFLATED, gzip ? 31 : -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(),
            Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw CompressionError.zlib("init", status) }
    }

    deinit { deflateEnd(&stream) }

    /// Compresses `data`; with `finish`, also flushes and ends the stream.
    func compress(_ data: Data, finish: Bool = false) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let status = deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
                    output.append(out.baseAddress!, count: out.count - Int(stream.avail_out))
                    return status
                }
                if status == Z_STREAM_END { break }
                guard status == Z_OK || status == Z_BUF_ERROR else { throw CompressionError.zlib("deflate", status) }
                // Done when zlib has consumed everything and has nothing more to write.
                if stream.avail_in == 0 && stream.avail_out != 0 && !finish { break }
                if stream.avail_in == 0 && status == Z_BUF_ERROR { break }
            }
        }
        return output
    }
}

/// Streaming inflate for gzip (or zlib) input.
final class Inflater {
    private var stream = z_stream()
    private(set) var finished = false

    init() throws {
        // 15 + 32: detect gzip or zlib headers automatically.
        let status = inflateInit2_(&stream, 15 + 32, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw CompressionError.zlib("init", status) }
    }

    deinit { inflateEnd(&stream) }

    func decompress(_ data: Data) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while stream.avail_in > 0 && !finished {
                let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    output.append(out.baseAddress!, count: out.count - Int(stream.avail_out))
                    return status
                }
                if status == Z_STREAM_END {
                    finished = true
                } else if status != Z_OK {
                    throw CompressionError.zlib("inflate", status)
                }
            }
        }
        return output
    }
}

enum CRC32 {
    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(zlib.crc32(uLong(crc), bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
    }
}

/// Buffered file output, optionally gzip-compressed.
final class FileSink {
    private let handle: FileHandle
    private var buffer = Data()
    private let deflater: Deflater?
    private(set) var bytesWritten: Int64 = 0

    init(url: URL, gzip: Bool = false) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        deflater = gzip ? try Deflater(gzip: true) : nil
    }

    func write(_ text: String) throws { try write(Data(text.utf8)) }

    func write(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= 1 << 20 { try flush() }
    }

    private func flush(finish: Bool = false) throws {
        guard !buffer.isEmpty || finish else { return }
        let out = try deflater?.compress(buffer, finish: finish) ?? buffer
        try handle.write(contentsOf: out)
        bytesWritten += Int64(out.count)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        try flush(finish: deflater != nil)
        try handle.close()
    }
}
