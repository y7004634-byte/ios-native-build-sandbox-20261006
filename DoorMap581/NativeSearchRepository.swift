import Foundation

/// The complete public corpus is prepared once off the main actor. It is not
/// cut to the first page or replaced by LIKE/FTS/Apple-only matching.
actor NativeSearchRepository {
    struct Corpus: Sendable {
        let local: [DoorSearchCore.Prepared]
        let community: [DoorSearchCore.Prepared]
    }
    private let resources: NativePublicResources
    private var corpus: Corpus?
    private var loading: Task<Corpus, Error>?
    private var generation = UUID()
    init(resources: NativePublicResources) { self.resources = resources }

    private func ensureCorpus() async throws -> Corpus {
        if let corpus { return corpus }
        if let loading { return try await loading.value }
        let resources = self.resources, expectedGeneration = generation
        let task = Task<Corpus, Error> {
            let index = try await resources.searchIndex()
            try Task.checkCancellation()
            let bytes = try await resources.data("offline/taichung-community-1150630-v2/search-index.json")
            let communities = try JSONDecoder().decode(DoorCommunityIndex.self, from: bytes)
            guard communities.records.count == 7285 else { throw DoorOfflineError.invalidManifest }
            try Task.checkCancellation()
            return Corpus(local: index.rows.map(DoorSearchCore.Prepared.init),
                          community: communities.records.map(DoorSearchCore.Prepared.init))
        }
        loading = task
        do {
            let value = try await task.value
            guard generation == expectedGeneration else { throw CancellationError() }
            corpus = value; loading = nil
            return value
        } catch {
            if generation == expectedGeneration { loading = nil }
            throw error
        }
    }
    func search(query: String, center: DoorCoordinate?, apple: [DoorSearchRecord] = []) async throws -> DoorSearchWindow.Presentation {
        let corpus = try await ensureCorpus()
        try Task.checkCancellation()
        var session = DoorSearchSession()
        let ticket = session.begin(query: query, center: center)
        session.publish(corpus.local, provider: .local, for: ticket)
        session.publish(corpus.community, provider: .community, for: ticket)
        session.publish(apple.map(DoorSearchCore.Prepared.init), provider: .apple, for: ticket)
        let output = session.presentation
        try Task.checkCancellation()
        return output
    }
    func counts() async throws -> (local: Int, community: Int) {
        let value = try await ensureCorpus()
        return (value.local.count, value.community.count)
    }
    func releaseDisposableCaches() {
        generation = UUID(); loading?.cancel(); loading = nil; corpus = nil
    }
}

/// One request owner for the top field, keyboard Search, More shortcut and
/// area re-search. Old queries and late Apple responses cannot publish.
@MainActor final class NativeSearchCoordinator {
    private let repository: NativeSearchRepository
    private let apple: NativeAppleSearchProvider
    private let appleEnabled: Bool
    private var task: Task<Void, Never>?
    private(set) var revision: UInt64 = 0
    private(set) var query = ""
    private(set) var center: DoorCoordinate?
    private(set) var presentation = DoorSearchWindow.present([], query: "", center: nil)
    private(set) var pageLimit = DoorSearchWindow.pageSize
    private(set) var busy = false
    private(set) var message = ""
    var onChange: (() -> Void)?
    init(repository: NativeSearchRepository, appleEnabled: Bool = true) {
        self.repository = repository; self.appleEnabled = appleEnabled
        apple = NativeAppleSearchProvider()
    }
    func clear() {
        revision &+= 1; task?.cancel(); task = nil; apple.cancel()
        query = ""; center = nil; busy = false; message = ""; pageLimit = DoorSearchWindow.pageSize
        presentation = DoorSearchWindow.present([], query: "", center: nil); onChange?()
    }
    func begin(_ text: String, center: DoorCoordinate?, submitted: Bool) {
        clear()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        self.center = center
        let expected = revision, query = self.query, repository = self.repository
        busy = true; message = "搜尋本機資料…"; onChange?()
        task = Task { [weak self] in
            do {
                if !submitted { try await Task.sleep(nanoseconds: 180_000_000) }
                let local = try await repository.search(query: query, center: center)
                guard let self, self.revision == expected, !Task.isCancelled else { return }
                self.presentation = local; self.busy = false; self.message = self.rangeMessage(local); self.onChange?()
                guard submitted, self.appleEnabled else { return }
                self.busy = true; self.message += " · Apple 補充中"; self.onChange?()
                do {
                    let items = try await self.apple.search(query: query, center: center, radiusM: local.listRadiusM ?? 3000)
                    guard self.revision == expected, !Task.isCancelled else { return }
                    let merged = try await repository.search(query: query, center: center, apple: items)
                    guard self.revision == expected, !Task.isCancelled else { return }
                    self.presentation = merged; self.message = self.rangeMessage(merged)
                } catch {
                    guard self.revision == expected, !Task.isCancelled else { return }
                    self.message = self.rangeMessage(local) + " · Apple 暫不可用，本機結果保留"
                }
                self.busy = false; self.onChange?()
            } catch {
                guard let self, self.revision == expected, !Task.isCancelled else { return }
                self.busy = false; self.message = "本機搜尋尚未完成：\(error.localizedDescription)"; self.onChange?()
            }
        }
    }
    var page: [DoorSearchCore.Result] { presentation.page(through: pageLimit) }
    var hasMore: Bool { pageLimit < presentation.list.count }
    func loadMore() { pageLimit = min(pageLimit + DoorSearchWindow.pageSize, presentation.list.count); onChange?() }
    func cancelPendingPreservingResults() { revision &+= 1; task?.cancel(); task = nil; apple.cancel(); busy = false }
    private func rangeMessage(_ value: DoorSearchWindow.Presentation) -> String {
        if value.list.isEmpty { return "本機範圍內沒有符合資料；可移動地圖後重搜" }
        if value.listRadiusM == nil { return "地址／位置候選 · \(value.list.count) 筆" }
        return (value.expanded ? "附近 3 公里結果較少，清單擴到 8 公里" : "附近 3 公里") + " · \(value.list.count) 筆"
    }
    deinit { task?.cancel() }
}
