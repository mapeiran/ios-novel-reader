import Foundation

/// 书籍导入：先快速落盘 + 建记录，再后台解析分章
final class BookImportService {
    private let storage: Storage

    init(storage: Storage) {
        self.storage = storage
    }

    /// 快速导入：仅把原始文件放入沙盒并创建书籍记录（不做解码/分章）
    func importFile(at url: URL,
                    pattern: String = ChapterRule.defaultPattern,
                    completion: @escaping (Result<Book, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            DebugLog.log("import start: \(url.path) scoped=\(accessed)")

            do {
                let id = UUID()
                let fileURL = self.storage.bookFileURL(for: id)

                // 自家临时文件（局域网）可直接移动；外部文件用多种方式读取
                let isOwnTemp = url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                if isOwnTemp {
                    try? FileManager.default.moveItem(at: url, to: fileURL)
                }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Self.copyData(from: url, to: fileURL)
                }

                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                DebugLog.log("import copied size=\(size)")
                guard size > 0 else { throw AppError.emptyContent }

                let title = (url.lastPathComponent as NSString).deletingPathExtension
                let book = Book(id: id,
                                title: title,
                                author: nil,
                                filePath: fileURL.path,
                                encoding: "待解析",
                                fileSize: size,
                                totalChars: 0,
                                chapterCount: 0,
                                chapterRule: pattern,
                                addedAt: Date(),
                                lastReadAt: nil,
                                parseState: .pending)
                DispatchQueue.main.async { completion(.success(book)) }
            } catch {
                DebugLog.log("import failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// 多种方式读取外部文件，兼容「文件」App / iCloud provider URL
    private static func copyData(from url: URL, to dest: URL) throws {
        // 1. 直接拷贝
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return
        } catch {
            DebugLog.log("copyItem failed: \(error)")
        }

        // 2. 读取 Data 再写入
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            try data.write(to: dest, options: .atomic)
            return
        }

        // 3. NSFileCoordinator 协调读取
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var readError: Error?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { newURL in
            do {
                data = try Data(contentsOf: newURL)
            } catch {
                readError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        guard let data, !data.isEmpty else { throw AppError.emptyContent }
        try data.write(to: dest, options: .atomic)
    }

    /// 后台解析：识别编码 -> 规范化 -> 回写 UTF-8 -> 正则分章
    func parse(_ book: Book,
               completion: @escaping (Result<(Book, [Chapter]), Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let fileURL = URL(fileURLWithPath: book.filePath)
                let data = try Data(contentsOf: fileURL)

                guard let (decoded, encoding) = EncodingDetector.decodeBest(data) else {
                    throw AppError.encodingFailed
                }
                let text = EncodingDetector.normalize(decoded)
                guard text.contains(where: { !$0.isWhitespace }) else {
                    throw AppError.emptyContent
                }

                // 统一回写为 UTF-8（已是 UTF-8 且无 BOM 时跳过）
                let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
                if encoding != .utf8 || hasBOM {
                    try text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                }

                let chapters = ChapterParser.parse(text: text,
                                                   bookId: book.id,
                                                   pattern: book.chapterRule ?? ChapterRule.defaultPattern)

                var updated = book
                updated.encoding = String(describing: encoding)
                updated.totalChars = (text as NSString).length
                updated.chapterCount = chapters.count
                updated.parseState = .done

                DispatchQueue.main.async { completion(.success((updated, chapters))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
