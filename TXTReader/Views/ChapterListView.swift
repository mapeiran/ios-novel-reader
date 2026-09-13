import SwiftUI

struct ChapterListView: View {
    let chapters: [Chapter]
    let currentIndex: Int
    var onSelect: (Int) -> Void

    var body: some View {
        List {
            ForEach(chapters) { chapter in
                Button {
                    onSelect(chapter.index)
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundColor(chapter.index == currentIndex ? .accentColor : .primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(chapter.charCount)字")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("目录")
    }
}

/// 以 Sheet 形式呈现的目录（含关闭按钮）
struct ChapterListSheet: View {
    let chapters: [Chapter]
    let currentIndex: Int
    var onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChapterListView(chapters: chapters, currentIndex: currentIndex, onSelect: onSelect)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}
