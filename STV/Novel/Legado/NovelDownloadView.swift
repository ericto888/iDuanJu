import SwiftUI

struct NovelDownloadView: View {
    let book: NovelBook
    var chapter: Int = 0
    @AppStorage("novel.prefetch") private var prefetch = 3
    @ObservedObject private var loader = NovelWebLoader.shared
    /// Counted off the main thread: it scans the chapter folder, and the loader publishes after every chapter.
    @State private var cached: Int?

    private var state: NovelWebLoader.DownloadState? { loader.downloadStates[book.id] }

    var body: some View {
        DSSheet("缓存与下载") {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        NovelBookRow(title: book.title, author: book.author ?? "", kind: cached.map { "已缓存 \($0) / \(book.chapters.count) 章" } ?? "共 \(book.chapters.count) 章", cover: book.coverURL)
                        if let state {
                            DSProgressBar(value: Double(state.completed) / Double(max(1, state.total)), height: 5)
                            HStack(alignment: .firstTextBaseline) {
                                Text("本次 \(state.completed)/\(state.total) · 失败 \(state.failures)").dsFont(12, relativeTo: .caption).foregroundStyle(STVTheme.secondary)
                                Spacer(minLength: 8)
                                if state.active {
                                    Button { loader.stopDownload(book) } label: { MiniButtonLabel(title: "暂停下载", tint: DSTone.danger, ground: DSTone.dangerSoft) }.buttonStyle(PressScale())
                                }
                            }
                            if !state.message.isEmpty { Text(state.message).dsFont(12, relativeTo: .caption).foregroundStyle(state.failures > 0 ? DSTone.danger : STVTheme.secondary) }
                        }
                    }
                    .padding(.horizontal, 20)
                    DSSection("离线下载", footer: "保持应用前台下载。已缓存章节可断网阅读，暂停或中断后可继续，已完成章节不会重复请求。", separatorInset: 58) {
                        DSRow("缓存后 50 章", icon: "arrow.down.circle") { loader.download(book, from: chapter, count: 50) }
                        DSRow("缓存后 200 章", icon: "arrow.down.circle") { loader.download(book, from: chapter, count: 200) }
                        DSRow("下载全本", icon: "books.vertical", subtitle: "或继续未完成的下载") { loader.download(book, from: 0, count: nil) }
                    }
                    .disabled(state?.active == true)
                    DSSection("提前缓存", footer: "阅读时自动预取后续章节，减少翻页等待。") {
                        SegmentedTabs(items: [0, 3, 10, 20], selection: $prefetch, label: { $0 == 0 ? "关闭" : "\($0) 章" }, idPrefix: "novel.prefetch").dsRow(vertical: 14)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .dsSheetChrome()
        .task(id: state?.completed ?? -1) {
            let book = book
            let n = await Task.detached(priority: .utility) { NovelStore.fastCachedCount(book) }.value
            if !Task.isCancelled { cached = n }
        }
    }
}
