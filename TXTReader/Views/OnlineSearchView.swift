import SwiftUI

struct OnlineSearchView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var sources: BookSourceStore

    @State private var keyword = ""
    @State private var results: [BookSourceService.AggregatedResult] = []
    @State private var searching = false
    @State private var message: String?
    @State private var showSourceManager = false

    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadChapter = ""
    @State private var readingBook: Book?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                content
            }
            .navigationTitle("书城")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSourceManager = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .overlay { if downloading { downloadOverlay } }
            .sheet(isPresented: $showSourceManager) {
                BookSourceManagerView().environmentObject(sources)
            }
            .fullScreenCover(item: $readingBook) { book in
                ReaderContainerView(book: book)
                    .environmentObject(library)
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack {
                Label("多源聚合搜索", systemImage: "globe")
                    .font(.subheadline)
                Spacer()
                Text("已启用 \(sources.enabledSources.count) 个书源")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("管理") { showSourceManager = true }
                    .font(.subheadline)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索书名 / 作者", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { performSearch() }
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
                Button("搜索") { performSearch() }
                    .disabled(searching || keyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if sources.enabledSources.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "globe").font(.system(size: 44)).foregroundColor(.secondary)
                Text("还没有可用书源").font(.headline)
                Text("点击右上角管理，导入书源 JSON").font(.footnote).foregroundColor(.secondary)
                Button("管理书源") { showSourceManager = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searching {
            ProgressView("多源搜索中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            Text(message ?? "输入书名后搜索")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(results) { item in
                Button { startOnlineReading(item) } label: { resultRow(item) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { startDownload(item) } label: {
                            Label("下载", systemImage: "arrow.down.circle")
                        }
                        .tint(.accentColor)
                    }
                    .contextMenu {
                        Button { startOnlineReading(item) } label: {
                            Label("在线阅读（边读边缓存）", systemImage: "book")
                        }
                        Button { startDownload(item) } label: {
                            Label("下载到书架", systemImage: "arrow.down.circle")
                        }
                    }
            }
        }
    }

    private func resultRow(_ item: BookSourceService.AggregatedResult) -> some View {
        let result = item.result
        return HStack(spacing: 12) {
            if let cover = result.cover, let url = URL(string: cover) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(.secondarySystemBackground)
                }
                .frame(width: 44, height: 60)
                .clipped()
                .cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 44, height: 60)
                    .overlay(Image(systemName: "book").foregroundColor(.secondary))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name).font(.headline).lineLimit(1)
                Text(result.author).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text(item.sourceName)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "arrow.down.circle").foregroundColor(.accentColor)
        }
        .padding(.vertical, 4)
    }

    private var downloadOverlay: some View {
        VStack(spacing: 14) {
            ProgressView(value: downloadProgress)
                .frame(width: 220)
            Text("正在下载 \(Int(downloadProgress * 100))%")
                .font(.subheadline)
            Text(downloadChapter).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 动作

    private func performSearch() {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        let enabled = sources.enabledSources
        guard !enabled.isEmpty else { message = "没有启用的书源"; return }

        searching = true
        message = nil
        results = []
        Task {
            let found = await BookSourceService().searchAll(keyword: key, sources: enabled)
            await MainActor.run {
                results = found
                searching = false
                if found.isEmpty { message = "未找到结果（可尝试添加更多书源）" }
            }
        }
    }

    /// 在线阅读：抓目录 + 第一章后立即打开，其余章节后台缓存到本地
    private func startOnlineReading(_ item: BookSourceService.AggregatedResult) {
        guard let source = sources.sources.first(where: { $0.id == item.sourceID }) else { return }
        downloading = true
        downloadProgress = 0
        downloadChapter = "获取目录…"
        let result = item.result
        Task {
            do {
                let book = try await OnlineReadingService.shared.start(
                    source: source, title: result.name, author: result.author,
                    cover: result.cover, detailURL: result.detailURL,
                    storage: library.storage, library: library)
                await MainActor.run {
                    downloading = false
                    readingBook = book
                }
            } catch {
                await MainActor.run {
                    downloading = false
                    message = "在线阅读失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func startDownload(_ item: BookSourceService.AggregatedResult) {
        guard let source = sources.sources.first(where: { $0.id == item.sourceID }) else { return }
        downloading = true
        downloadProgress = 0
        downloadChapter = "获取目录…"
        let result = item.result
        let importer = OnlineImportService(source: source, storage: library.storage)
        importer.download(name: result.name, author: result.author, cover: result.cover,
                          detailURL: result.detailURL) { progress, chapter in
            downloadProgress = progress
            downloadChapter = chapter
        } completion: { res in
            downloading = false
            switch res {
            case .success(let (book, chapters)):
                if let existing = library.findDuplicate(hash: book.contentHash) {
                    library.discard(book)
                    message = "《\(existing.title)》已存在，已跳过"
                } else {
                    library.add(book, chapters: chapters)
                    message = "已加入书架：《\(book.title)》（\(chapters.count) 章）"
                }
            case .failure(let error):
                message = "下载失败：\(error.localizedDescription)"
            }
        }
    }
}
