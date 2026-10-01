import SwiftUI
import UniformTypeIdentifiers

/// 书架排序方式
enum BookSort: String, CaseIterable, Identifiable {
    case added = "加入时间"
    case lastRead = "阅读时间"
    case title = "文件名称"
    case size = "文件大小"
    var id: String { rawValue }
}

struct BookshelfView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var library: LibraryStore
    @State private var showImportSheet = false
    @State private var pendingFileImport = false
    @State private var pendingZipImport = false
    @State private var selectedBook: Book?
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var duplicateMessage: String?
    @State private var renameBook: Book?
    @State private var renameText = ""
    @State private var formatBook: Book?
    @State private var moveBook: Book?
    @State private var folderFilter: String?
    @State private var searchText = ""
    @AppStorage("bookshelf.sort") private var sortRaw = BookSort.added.rawValue

    private var sort: BookSort { BookSort(rawValue: sortRaw) ?? .added }

    private var sortedBooks: [Book] {
        switch sort {
        case .added:
            return library.books.sorted { $0.addedAt > $1.addedAt }
        case .lastRead:
            return library.books.sorted {
                ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast)
            }
        case .title:
            return library.books.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .size:
            return library.books.sorted { $0.fileSize > $1.fileSize }
        }
    }

    /// 搜索过滤（书名模糊匹配）+ 文件夹过滤
    private var displayedBooks: [Book] {
        var list = sortedBooks
        if let filter = folderFilter {
            if filter.isEmpty {
                list = list.filter { ($0.folder ?? "").isEmpty }
            } else {
                list = list.filter { $0.folder == filter }
            }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(displayedBooks) { book in
                            Button {
                                if book.isParsing {
                                    errorMessage = "《\(book.title)》正在后台解析，请稍候再打开"
                                } else {
                                    selectedBook = book
                                }
                            } label: {
                                BookRow(book: book)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    library.remove(book)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    renameText = book.title
                                    renameBook = book
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .tint(.blue)
                                Button {
                                    formatBook = book
                                } label: {
                                    Label("格式化", systemImage: "wand.and.stars")
                                }
                                .tint(.green)
                                Button {
                                    moveBook = book
                                } label: {
                                    Label("移动", systemImage: "folder")
                                }
                                .tint(.indigo)
                            }
                        }
                    }
                }
            }
            .navigationTitle("书架")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Menu {
                        Picker("分类", selection: Binding(
                            get: { folderFilter ?? "__all__" },
                            set: { folderFilter = ($0 == "__all__") ? nil : $0 })) {
                            Text("全部").tag("__all__")
                            Text("未分类").tag("")
                            ForEach(library.folders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    Menu {
                        Picker("排序", selection: $sortRaw) {
                            ForEach(BookSort.allCases) { option in
                                Text(option.rawValue).tag(option.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImportSheet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if importing {
                    ProgressView("正在导入…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $showImportSheet, onDismiss: {
                // 等弹窗完全关闭后再拉起文件选择器，避免呈现冲突
                if pendingFileImport {
                    pendingFileImport = false
                    DocumentPickerPresenter.shared.present { urls in
                        handleURLs(urls)
                    }
                } else if pendingZipImport {
                    pendingZipImport = false
                    DocumentPickerPresenter.shared.present(contentTypes: [.zip, .archive]) { urls in
                        importZip(urls)
                    }
                }
            }) {
                ImportOptionsView(
                    onPickFile: {
                        pendingFileImport = true
                        showImportSheet = false
                    },
                    onPickZip: {
                        pendingZipImport = true
                        showImportSheet = false
                    },
                    onWiFi: {
                        showImportSheet = false
                        selectedTab = 2
                    })
            }
            .sheet(item: $formatBook) { book in
                FormatPreviewView(book: book)
                    .environmentObject(library)
            }
            .sheet(item: $moveBook) { book in
                MoveToFolderView(book: book, folders: library.folders) { folder in
                    library.move(book, to: folder)
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .fullScreenCover(item: $selectedBook) { book in
                ReaderContainerView(book: book)
                    .environmentObject(library)
            }
        }
        .alert("重命名", isPresented: Binding(
            get: { renameBook != nil },
            set: { if !$0 { renameBook = nil } })) {
            TextField("书名", text: $renameText)
            Button("取消", role: .cancel) { renameBook = nil }
            Button("保存") {
                if let book = renameBook {
                    library.rename(book, to: renameText)
                }
                renameBook = nil
            }
        }
        .alert("重复导入", isPresented: Binding(
            get: { duplicateMessage != nil },
            set: { if !$0 { duplicateMessage = nil } })) {
            Button("好", role: .cancel) { duplicateMessage = nil }
        } message: {
            Text(duplicateMessage ?? "")
        }
        .onAppear { DebugLog.log("Bookshelf onAppear") }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("书架还是空的")
                .font(.headline)
            Text("点击右上角 + 导入 TXT，或到「WiFi传书」从电脑上传")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func handleURLs(_ urls: [URL]) {
        DebugLog.log("handleURLs count=\(urls.count)")
        guard !urls.isEmpty else { return }
        importing = true
        let service = BookImportService(storage: library.storage)
        var finished = 0
        var duplicates: [String] = []
        var failures: [String] = []

        for url in urls {
            DebugLog.log("importing url=\(url.path)")
            service.importFile(at: url) { res in
                finished += 1
                switch res {
                case .success(let book):
                    if let existing = library.findDuplicate(hash: book.contentHash) {
                        library.discard(book)
                        duplicates.append(existing.title)
                    } else {
                        library.add(book)
                        library.parseChapters(for: book)
                    }
                case .failure(let error):
                    DebugLog.log("import failure=\(error.localizedDescription)")
                    failures.append(error.localizedDescription)
                }

                if finished == urls.count {
                    importing = false
                    if !duplicates.isEmpty {
                        duplicateMessage = "以下文档已经导入过，已跳过：\n"
                            + duplicates.map { "《\($0)》" }.joined(separator: "\n")
                    } else if !failures.isEmpty {
                        errorMessage = failures.joined(separator: "\n")
                    }
                }
            }
        }
    }

    /// ZIP 批量导入：解压出所有 .txt 后走普通导入流程
    private func importZip(_ urls: [URL]) {
        guard let url = urls.first else { return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let entries = try ZipArchiveReader.readTextEntries(at: url)
                var tempURLs: [URL] = []
                for entry in entries {
                    let name = entry.name.components(separatedBy: "/").last ?? "book.txt"
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString)-\(name)")
                    try entry.data.write(to: tmp, options: .atomic)
                    tempURLs.append(tmp)
                }
                DispatchQueue.main.async {
                    importing = false
                    if tempURLs.isEmpty {
                        errorMessage = "ZIP 中未找到 TXT 文件"
                    } else {
                        handleURLs(tempURLs)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    importing = false
                    errorMessage = "解压失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

/// 导入方式选择（Sheet 半屏，点击空白处即可退出）
struct ImportOptionsView: View {
    var onPickFile: () -> Void
    var onPickZip: () -> Void
    var onWiFi: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("导入 TXT")
                .font(.headline)
                .padding(.top, 24)

            Button(action: onPickFile) {
                Label("从「文件」App 导入", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Button(action: onPickZip) {
                Label("导入 ZIP（批量）", systemImage: "doc.zipper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Button(action: onWiFi) {
                Label("WiFi 传书", systemImage: "wifi")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }
}

struct BookCoverView: View {
    let book: Book
    var width: CGFloat = 44
    var height: CGFloat = 60

    var body: some View {
        Group {
            if let cover = book.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        generated
                    }
                }
            } else {
                generated
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .cornerRadius(6)
    }

    /// 无封面时用书名生成一张默认封面（配色由书名稳定散列得到）
    private var generated: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(shortTitle)
                .font(.system(size: min(width, height) * 0.36, weight: .bold))
                .foregroundColor(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(4)
        }
    }

    private var shortTitle: String {
        let trimmed = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "书" }
        return String(trimmed.prefix(2))
    }

    private var gradient: [Color] {
        var seed = 0
        for scalar in book.title.unicodeScalars {
            seed = (seed &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        let hue = Double(seed % 360) / 360.0
        return [Color(hue: hue, saturation: 0.55, brightness: 0.78),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.55)]
    }
}

struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCoverView(book: book)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                if book.isParsing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(book.parseState == .failed ? "解析失败" : "解析中…")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Text("\(book.chapterCount) 章")
                        Text("\(Int(book.progress * 100))%")
                        if book.isCaching {
                            Text("缓存中").foregroundColor(.orange)
                        }
                        if let folder = book.folder, !folder.isEmpty {
                            Label(folder, systemImage: "folder")
                        }
                        if let last = book.lastReadAt {
                            Text(last, style: .date)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                if let source = book.sourceName, !source.isEmpty {
                    Label(source, systemImage: "globe")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 移动到分类文件夹
struct MoveToFolderView: View {
    let book: Book
    let folders: [String]
    var onMove: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newFolder = ""

    var body: some View {
        NavigationStack {
            List {
                Section("选择文件夹") {
                    Button {
                        onMove(nil); dismiss()
                    } label: {
                        Label("未分类", systemImage: "tray")
                    }
                    ForEach(folders, id: \.self) { folder in
                        Button {
                            onMove(folder); dismiss()
                        } label: {
                            Label(folder, systemImage: "folder")
                        }
                    }
                }
                Section("新建文件夹") {
                    HStack {
                        TextField("文件夹名称", text: $newFolder)
                        Button("创建并移动") {
                            let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                            onMove(name)
                            dismiss()
                        }
                        .disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
