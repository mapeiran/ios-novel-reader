import Foundation

/// TXT 编码识别（在样本上检测，避免对大文件反复整包解码）
enum EncodingDetector {

    /// 采样大小
    private static let sampleSize = 64 * 1024

    /// GB18030（兼容 GBK/GB2312）
    static let gb18030: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    /// BIG5
    static let big5: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    /// 检测编码（基于文件头样本）
    static func detect(_ data: Data) -> String.Encoding? {
        guard !data.isEmpty else { return nil }

        // 1. BOM（只看头部）
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }

        let sample = Data(data.prefix(sampleSize))

        // 2. 系统探测（仅样本）
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: sample,
                                          encodingOptions: nil,
                                          convertedString: &converted,
                                          usedLossyConversion: &usedLossy)
        if raw != 0, !usedLossy.boolValue, converted != nil {
            return String.Encoding(rawValue: raw)
        }

        // 3. 回退链（在换行处截断的样本上，避免多字节被截断）
        let safe = safeSample(data)
        for enc in [String.Encoding.utf8, gb18030, big5, .utf16, .isoLatin1] {
            if let text = String(data: safe, encoding: enc), !text.contains("\u{FFFD}") {
                return enc
            }
        }
        return nil
    }

    /// 一次性拿到「全文文本 + 编码」，正常路径只整包解码一次
    static func decodeBest(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if let encoding = detect(data), let text = String(data: data, encoding: encoding) {
            return (text, encoding)
        }
        // 兜底：整包逐个尝试
        for enc in [String.Encoding.utf8, gb18030, big5, .utf16, .isoLatin1] {
            if let text = String(data: data, encoding: enc) {
                return (text, enc)
            }
        }
        return nil
    }

    static func decode(_ data: Data, as encoding: String.Encoding) -> String? {
        String(data: data, encoding: encoding)
    }

    /// 文本规范化：去 BOM、统一换行（无 CR 时零额外拷贝）
    static func normalize(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\u{FEFF}") { result.removeFirst() }
        if result.contains("\r") {
            result = result.replacingOccurrences(of: "\r\n", with: "\n")
            result = result.replacingOccurrences(of: "\r", with: "\n")
        }
        return result
    }

    /// 在最后一个换行处截断，保证多字节字符完整
    private static func safeSample(_ data: Data) -> Data {
        let sample = Data(data.prefix(sampleSize))
        if let newlineIndex = sample.lastIndex(of: 0x0A) {
            return sample.prefix(upTo: newlineIndex)
        }
        return sample
    }
}
