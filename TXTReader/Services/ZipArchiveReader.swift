import Foundation

/// 极简 ZIP 读取器（支持 stored 与 deflate，用于批量导入 TXT）
enum ZipArchiveReader {

    struct Entry {
        let name: String
        let data: Data
    }

    enum ZipError: LocalizedError {
        case invalid
        case unsupported
        var errorDescription: String? {
            switch self {
            case .invalid:     return "不是有效的 ZIP 文件"
            case .unsupported: return "ZIP 使用了不支持的压缩方式"
            }
        }
    }

    /// 读取 ZIP 中的所有 .txt 条目
    static func readTextEntries(at url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url)
        return try readTextEntries(from: data)
    }

    static func readTextEntries(from data: Data) throws -> [Entry] {
        guard let eocd = findEOCD(data) else { throw ZipError.invalid }
        let totalEntries = Int(readUInt16(data, eocd + 10))
        let cdOffset = Int(readUInt32(data, eocd + 16))

        var entries: [Entry] = []
        var p = cdOffset

        for _ in 0..<totalEntries {
            guard readUInt32(data, p) == 0x02014b50 else { break }
            let method = readUInt16(data, p + 10)
            let compSize = Int(readUInt32(data, p + 20))
            let uncompSize = Int(readUInt32(data, p + 24))
            let nameLen = Int(readUInt16(data, p + 28))
            let extraLen = Int(readUInt16(data, p + 30))
            let commentLen = Int(readUInt16(data, p + 32))
            let localOffset = Int(readUInt32(data, p + 42))

            let nameStart = p + 46
            guard nameStart + nameLen <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)),
                              encoding: .utf8) ?? ""
            p = nameStart + nameLen + extraLen + commentLen

            let lower = name.lowercased()
            guard lower.hasSuffix(".txt"), !lower.hasPrefix("__macosx/") else { continue }

            guard readUInt32(data, localOffset) == 0x04034b50 else { continue }
            let lNameLen = Int(readUInt16(data, localOffset + 26))
            let lExtraLen = Int(readUInt16(data, localOffset + 28))
            let dataStart = localOffset + 30 + lNameLen + lExtraLen
            guard dataStart + compSize <= data.count else { continue }
            let compressed = data.subdata(in: dataStart..<(dataStart + compSize))

            let raw: Data
            switch method {
            case 0:
                raw = compressed
            case 8:
                guard let inflated = inflateRaw(compressed, uncompressedSize: uncompSize) else { continue }
                raw = inflated
            default:
                continue
            }
            entries.append(Entry(name: name, data: raw))
        }
        return entries
    }

    // MARK: - ZIP 结构解析

    private static func findEOCD(_ data: Data) -> Int? {
        let minEOCD = 22
        guard data.count >= minEOCD else { return nil }
        let lower = max(0, data.count - 65557)
        var i = data.count - minEOCD
        while i >= lower {
            if readUInt32(data, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    // MARK: - 原始 deflate 解压（zlib，windowBits = -15）

    private static func inflateRaw(_ data: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: uncompressedSize)
        var stream = z_stream()
        var result: Data?

        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                stream.next_in = UnsafeMutablePointer(mutating: inPtr.baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outPtr.baseAddress
                stream.avail_out = uInt(uncompressedSize)

                guard inflateInit2_(&stream, -15, zlibVersion(),
                                     Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                let status = inflate(&stream, Z_FINISH)
                if status == Z_STREAM_END || status == Z_OK {
                    result = Data(outPtr.prefix(Int(stream.total_out)))
                }
                inflateEnd(&stream)
            }
        }
        return result
    }
}
