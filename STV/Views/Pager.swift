import SwiftUI

@MainActor
final class Pager: ObservableObject {
    @Published var items: [HGSeries] = []
    @Published var hasMore = true
    @Published var isLoading = false
    @Published var error: Error?
    @Published private(set) var page = HGPage(items: [], hasMore: true, nextOffset: 0)
    private var fetch: ((HGPage, [HGSeries]) async throws -> HGPage)?
    private var token = UUID()
    private(set) var loadedPageCount = 0
    var onSnapshotChanged: ((Snapshot) -> Void)?

    struct Snapshot {
        let items: [HGSeries]
        let page: HGPage
        let hasMore: Bool
        let loadedPageCount: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(items: items, page: page, hasMore: hasMore, loadedPageCount: loadedPageCount)
    }

    func restore(_ snapshot: Snapshot) {
        token = UUID()
        items = snapshot.items
        page = snapshot.page
        hasMore = snapshot.hasMore
        loadedPageCount = snapshot.loadedPageCount
        isLoading = false
        error = nil
        onSnapshotChanged?(self.snapshot())
    }

    func setFetcher(_ f: @escaping (HGPage, [HGSeries]) async throws -> HGPage) {
        fetch = f
    }

    func reset(_ f: @escaping (HGPage, [HGSeries]) async throws -> HGPage) {
        fetch = f; items = []; hasMore = true; error = nil; isLoading = false; loadedPageCount = 0
        page = HGPage(items: [], hasMore: true, nextOffset: 0); token = UUID()
        onSnapshotChanged?(snapshot())
        loadMore()
    }

    /// Re-fetch the pages that were already visible before a manual refresh.
    /// The request token prevents an older in-flight page from publishing over this refresh.
    func refreshPreservingDepth(_ f: @escaping (HGPage, [HGSeries]) async throws -> HGPage) async {
        fetch = f
        let depth = max(1, loadedPageCount)
        token = UUID()
        let t = token
        items = []
        page = HGPage(items: [], hasMore: true, nextOffset: nil)
        hasMore = true
        error = nil
        loadedPageCount = 0
        isLoading = true
        onSnapshotChanged?(snapshot())

        for _ in 0..<depth {
            do {
                let next = try await f(page, items)
                guard t == token else { return }
                var ids = Set(items.map(\\.id))
                items += next.items.filter { ids.insert($0.id).inserted }
                page = next
                loadedPageCount += 1
                hasMore = next.hasMore && !next.items.isEmpty
                error = nil
                onSnapshotChanged?(snapshot())
                if !hasMore { break }
            } catch {
                guard t == token else { return }
                self.error = error
                break
            }
        }
        guard t == token else { return }
        isLoading = false
        onSnapshotChanged?(snapshot())
    }

    func loadMore() {
        guard let fetch, hasMore, !isLoading else { return }
        isLoading = true
        let t = token, prev = page, seen = items
        Task {
            do {
                let p = try await fetch(prev, seen)
                guard t == token else { return }
                var ids = Set(items.map(\.id))
                items += p.items.filter { ids.insert($0.id).inserted }
                page = p
                loadedPageCount += 1
                hasMore = p.hasMore && !p.items.isEmpty
                error = nil
            } catch {
                guard t == token else { return }
                self.error = error
            }
            if t == token {
                isLoading = false
                onSnapshotChanged?(snapshot())
            }
        }
    }
}
