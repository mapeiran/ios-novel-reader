import SwiftUI

/// 目录 / 搜索 侧边栏（背景与文字颜色跟随阅读主题）
struct ReaderSidebarView: View {
    let chapters: [Chapter]
    let currentIndex: Int
    let backgroundColor: Color
    let textColor: Color
    let accentColor: Color
    let startInSearch: Bool
    var onSelectChapter: (Int) -> Void
    var onSelectOffset: (Int) -> Void
    var searchProvider: (String) -> [SearchResult]

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(textColor.opacity(0.15))
            if trimmedQuery.isEmpty {
                chapterList
            } else {
                resultList
            }
        }
        .background(backgroundColor)
        .onAppear {
            if startInSearch { searchFocused = true }
        }
        .onChange(of: query) { newValue in
            performSearch(newValue)
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(textColor.opacity(0.55))
            TextField("搜索全书内容", text: $query)
                .focused($searchFocused)
                .foregroundColor(textColor)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(textColor.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(textColor.opacity(0.08))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 目录

    private var chapterList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(chapters) { chapter in
                    Button {
                        onSelectChapter(chapter.index)
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .lineLimit(1)
                                .foregroundColor(chapter.index == currentIndex ? accentColor : textColor)
                            Spacer()
                            Text("\(chapter.charCount)字")
                                .font(.caption)
                                .foregroundColor(textColor.opacity(0.45))
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(textColor.opacity(0.08))
                }
            }
        }
    }

    // MARK: - 搜索结果

    private var resultList: some View {
        Group {
            if searching {
                ProgressView()
                    .tint(textColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                Text("未找到相关内容")
                    .foregroundColor(textColor.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { result in
                            Button {
                                onSelectOffset(result.offset)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.chapterTitle)
                                        .font(.caption)
                                        .foregroundColor(accentColor)
                                        .lineLimit(1)
                                    highlightedSnippet(result.snippet)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(textColor.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    private func highlightedSnippet(_ snippet: String) -> Text {
        guard !trimmedQuery.isEmpty else {
            return Text(snippet).foregroundColor(textColor)
        }
        var result = Text("")
        var remainder = Substring(snippet)
        while let range = remainder.range(of: trimmedQuery, options: .caseInsensitive) {
            result = result + Text(remainder[..<range.lowerBound]).foregroundColor(textColor)
            result = result + Text(remainder[range]).foregroundColor(accentColor).bold()
            remainder = remainder[range.upperBound...]
        }
        result = result + Text(remainder).foregroundColor(textColor)
        return result
    }

    // MARK: - 搜索执行

    private func performSearch(_ text: String) {
        let keyword = text.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        let provider = searchProvider
        DispatchQueue.global(qos: .userInitiated).async {
            let found = provider(keyword)
            DispatchQueue.main.async {
                results = found
                searching = false
            }
        }
    }
}
