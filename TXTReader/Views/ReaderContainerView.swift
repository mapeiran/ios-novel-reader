import SwiftUI

struct ReaderContainerView: View {
    let book: Book
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = ReaderSettings()
    @State private var chapters: [Chapter] = []

    var body: some View {
        ReaderViewRepresentable(book: book,
                                chapters: chapters,
                                settings: settings,
                                progressStore: library.progressStoreInstance())
            .ignoresSafeArea()
            .onAppear {
                refreshChapters()
                if chapters.isEmpty {
                    // 章节缺失时按文件重新分章兜底
                    library.parseChapters(for: book)
                }
                OnlineReadingService.shared.resumeIfNeeded(book: book,
                                                           storage: library.storage,
                                                           library: library)
            }
            .onChange(of: library.books) { _ in
                refreshChapters()
            }
            .onDisappear {
                // 退出阅读后刷新书架上的阅读进度（延后一拍，确保阅读器已保存记录）
                DispatchQueue.main.async { library.reload() }
            }
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary)
                        .padding(12)
                }
            }
    }

    private func refreshChapters() {
        chapters = library.chapters(for: book)
    }
}

struct ReaderViewRepresentable: UIViewControllerRepresentable {
    let book: Book
    let chapters: [Chapter]
    let settings: ReaderSettings
    let progressStore: ReadingProgressStore

    func makeUIViewController(context: Context) -> ReaderViewController {
        ReaderViewController(book: book,
                             chapters: chapters,
                             settings: settings,
                             progressStore: progressStore)
    }

    func updateUIViewController(_ uiViewController: ReaderViewController, context: Context) {
        uiViewController.updateOnlineContent(chapters: chapters)
    }
}
