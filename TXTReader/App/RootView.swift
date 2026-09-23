import SwiftUI

struct RootView: View {
    @StateObject private var library = LibraryStore()
    @StateObject private var sources = BookSourceStore()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            BookshelfView(selectedTab: $selectedTab)
                .environmentObject(library)
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            OnlineSearchView()
                .environmentObject(library)
                .environmentObject(sources)
                .tabItem { Label("书城", systemImage: "globe") }
                .tag(1)

            WiFiImportView()
                .environmentObject(library)
                .tabItem { Label("WiFi传书", systemImage: "wifi") }
                .tag(2)

            AppSettingsView()
                .environmentObject(library)
                .environmentObject(sources)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .onOpenURL { url in
            importURL(url)
        }
    }

    /// 处理「用其他应用打开 / 分享到本 App」传入的文件
    private func importURL(_ url: URL) {
        DebugLog.log("onOpenURL: \(url.path)")
        let service = BookImportService(storage: library.storage)
        service.importFile(at: url) { result in
            switch result {
            case .success(let book):
                if let existing = library.findDuplicate(hash: book.contentHash) {
                    library.discard(book)
                    DebugLog.log("open import duplicate: \(existing.title)")
                } else {
                    library.add(book)
                    library.parseChapters(for: book)
                    selectedTab = 0
                }
            case .failure(let error):
                DebugLog.log("open import failed: \(error.localizedDescription)")
            }
        }
    }
}
