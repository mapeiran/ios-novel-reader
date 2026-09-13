import SwiftUI

struct ReaderContainerView: View {
    let book: Book
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = ReaderSettings()

    var body: some View {
        ReaderViewRepresentable(book: book,
                                chapters: library.chapters(for: book),
                                settings: settings,
                                progressStore: library.progressStoreInstance())
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary)
                        .padding(12)
                }
            }
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

    func updateUIViewController(_ uiViewController: ReaderViewController, context: Context) {}
}
