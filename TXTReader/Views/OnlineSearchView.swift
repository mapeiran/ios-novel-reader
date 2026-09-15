import SwiftUI

struct OnlineSearchView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var sources: BookSourceStore

    @State private var keyword = ""
    @State private var selectedSourceID: UUID?
    @State private var results: [OnlineSearchResult] = []
    @State private var searching = false
    @State private var message: String?
    @State private var showSourceEditor = false

    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadChapter = ""

    private var selectedSource: BookSource? {
        sources.sources.first { $0.id == selectedSourceID } ?? sources.sources.first
    }

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
                    Button { showSourceEditor = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay { if downloading { downloadOverlay } }
            .sheet(isPresented: $showSourceEditor) {
                BookSourceEditView().environmentObject(sources)
            }
            .onAppear {
                if selectedSourceID == nil { selectedSourceID = sources.sources.first?.id }
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    ForEach(sources.sources) { source in
                        Button(source.name) { selectedSourceID = source.id }
                    }
                    if sources.sources.isEmpty {
                        Text("暂无书源")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "books.vertical")
                        Text(selectedSource?.name ?? "选择书源")
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                }

                Spacer()

                if !sources.sources.isEmpty {
                    Button("管理") { showSourceEditor = true }
                        .font(.subheadline)
                }
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
        if sources.sources.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "globe").font(.system(size: 44)).foregroundColor(.secondary)
                Text("还没有书源").font(.headline)
                Text("点击右上角 + 粘贴书源 JSON 添加").font(.footnote).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searching {
            ProgressView("搜索中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            VStack(spacing: 10) {
                Text(message ?? "输入书名后搜索")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(results) { result in
                Button { startDownload(result) } label: { resultRow(result) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func resultRow(_ result: OnlineSearchResult) -> some View {
        HStack(spacing: 12) {
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
        guard !key.isEmpty, let source = selectedSource else { return }
        searching = true
        message = nil
        results = []
        Task {
            do {
                let found = try await BookSourceService().search(keyword: key, source: source)
                await MainActor.run { results = found; searching = false }
            } catch {
                await MainActor.run {
                    searching = false
                    message = "搜索失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func startDownload(_ result: OnlineSearchResult) {
        guard let source = selectedSource else { return }
        downloading = true
        downloadProgress = 0
        downloadChapter = "获取目录…"
        let importer = OnlineImportService(source: source, storage: library.storage)
        importer.download(name: result.name, author: result.author, detailURL: result.detailURL) { progress, chapter in
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
