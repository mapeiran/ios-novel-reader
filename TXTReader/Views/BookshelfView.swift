import SwiftUI
import UniformTypeIdentifiers

/// 书架排序方式
enum BookSort: String, CaseIterable, Identifiable {
    case added = "加入时间"
    case lastRead = "阅读时间"
    case title = "文件名称"
    var id: String { rawValue }
}

struct BookshelfView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject var library: LibraryStore
    @State private var showImportSheet = false
    @State private var pendingFileImport = false
    @State private var selectedBook: Book?
    @State private var importing = false
    @State private var errorMessage: String?
    @State private var duplicateMessage: String?
    @State private var renameBook: Book?
    @State private var renameText = ""
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
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sortedBooks) { book in
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
                            }
                        }
                    }
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
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
                DebugLog.log("sheet onDismiss pendingFileImport=\(pendingFileImport)")
                if pendingFileImport {
                    pendingFileImport = false
                    DocumentPickerPresenter.shared.present { urls in
                        handleURLs(urls)
                    }
                }
            }) {
                ImportOptionsView(
                    onPickFile: {
                        DebugLog.log("pick file tapped")
                        pendingFileImport = true
                        showImportSheet = false
                    },
                    onWiFi: {
                        showImportSheet = false
                        selectedTab = 1
                    })
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
}

/// 导入方式选择（Sheet 半屏，点击空白处即可退出）
struct ImportOptionsView: View {
    var onPickFile: () -> Void
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

            Button(action: onWiFi) {
                Label("WiFi 传书", systemImage: "wifi")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
    }
}

struct BookRow: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.headline)
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
                    if let last = book.lastReadAt {
                        Text(last, style: .date)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
