import Foundation

/// 在线书籍下载：抓目录 + 正文，拼成 TXT 后走本地导入流程
final class OnlineImportService {
    private let source: BookSource
    private let storage: Storage
    private let service = BookSourceService()

    init(source: BookSource, storage: Storage) {
        self.source = source
        self.storage = storage
    }

    func download(name: String,
                  author: String,
                  cover: String?,
                  detailURL: String,
                  progress: @escaping (Double, String) -> Void,
                  completion: @escaping (Result<(Book, [Chapter]), Error>) -> Void) {
        Task {
            do {
                let chapters = try await service.chapters(detailURL: detailURL, source: source)
                var text = ""

                for (index, chapter) in chapters.enumerated() {
                    let content = (try? await service.content(chapterURL: chapter.url, source: source)) ?? ""
                    text += chapter.name + "\n" + content + "\n\n"
                    let percent = Double(index + 1) / Double(max(1, chapters.count))
                    await MainActor.run { progress(percent, chapter.name) }
                }

                var result = try BookImportService(storage: storage)
                    .importText(text, title: name, author: author.isEmpty ? nil : author)
                result.0.sourceName = source.name
                result.0.coverURL = cover
                await MainActor.run { completion(.success(result)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}
