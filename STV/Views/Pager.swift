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
    var onSnapshotChanged: ((Snapshot) -> Void)?

    struct Snapshot {
        let items: [HGSeries]
        let page: HGPage
        let hasMore: Bool
    }

    func snapshot() -> Snapshot {
        Snapshot(items: items, page: page, hasMore: hasMore)
    }

    func restore(_ snapshot: Snapshot) {
        token = UUID()
        items = snapshot.items
        page = snapshot.page
        hasMore = snapshot.hasMore
        isLoading = false
        error = nil
        onSnapshotChanged?(self.snapshot())
    }

    func setFetcher(_ f: @escaping (HGPage, [HGSeries]) async throws -> HGPage) {
        fetch = f
    }

    func reset(_ f: @escaping (HGPage, [HGSeries]) async throws -> HGPage) {
        fetch = f; items = []; hasMore = true; error = nil; isLoading = false
        page = HGPage(items: [], hasMore: true, nextOffset: 0); token = UUID()
        onSnapshotChanged?(snapshot())
        loadMore()
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
