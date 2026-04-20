import Foundation
import Combine

/// Holds tempo analysis results and kicks off background analysis whenever
/// new audio files appear in the playlist. Singleton — there's only ever one
/// playlist in the app.
class TempoCoordinator: ObservableObject {
    static let shared = TempoCoordinator()

    @Published private(set) var cache: [String: TempoData] = [:]
    @Published private(set) var analyzing: Set<String> = []

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Subscribe to a store's items and analyze any new audio files that
    /// haven't been analyzed yet.
    func attach(to store: PlaylistStore) {
        cancellables.removeAll()
        store.$items
            .sink { [weak self] items in self?.scanForNewFiles(in: items) }
            .store(in: &cancellables)
    }

    private func scanForNewFiles(in items: [PlaylistItem]) {
        for item in items where item.mediaType == .audio && !item.filePath.isEmpty {
            requestAnalysisIfNeeded(for: item.filePath)
        }
    }

    func requestAnalysisIfNeeded(for path: String) {
        guard !path.isEmpty else { return }
        if cache[path] != nil { return }
        if analyzing.contains(path) { return }
        analyzing.insert(path)
        debugLog("Tempo: queued analysis for \(path)")
        queue.addOperation { [weak self] in
            let start = Date()
            let result = TempoAnalyzer.analyze(url: URL(fileURLWithPath: path))
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                guard let self else { return }
                self.analyzing.remove(path)
                if let result {
                    self.cache[path] = result
                    debugLog(String(format: "Tempo: %@ → %.1f BPM, %d beats (%.2fs)",
                                    (path as NSString).lastPathComponent,
                                    result.bpm, result.beats.count, elapsed))
                } else {
                    debugLog("Tempo: analysis returned nil for \((path as NSString).lastPathComponent) (\(String(format: "%.2fs", elapsed)))")
                }
            }
        }
    }

    /// Look up the tempo source for a given item. Prefers a track whose name
    /// contains "click"; otherwise falls back to the first audio item in the
    /// same auto-follow chain.
    func tempoData(forItemID itemID: UUID, store: PlaylistStore) -> TempoData? {
        guard let sourcePath = store.tempoSourcePath(forItemID: itemID) else { return nil }
        return cache[sourcePath]
    }
}

extension PlaylistStore {
    /// Indices of all items in the same auto-follow chain as `index`. A chain
    /// is a maximal contiguous run where every item except the last has
    /// `autoFollow = true`.
    func songChainIndices(forIndex index: Int) -> [Int] {
        guard index >= 0, index < items.count else { return [] }
        var start = index
        while start > 0, items[start - 1].autoFollow, !items[start - 1].isDivider {
            start -= 1
        }
        var end = index
        while end < items.count - 1, items[end].autoFollow, !items[end + 1].isDivider {
            end += 1
        }
        return Array(start...end)
    }

    /// File path of the item in the chain that should drive tempo: prefer a
    /// track whose display name contains "click", otherwise the first audio
    /// item in the chain.
    func tempoSourcePath(forItemID itemID: UUID) -> String? {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let chain = songChainIndices(forIndex: idx)
        for i in chain
        where items[i].mediaType == .audio
            && !items[i].filePath.isEmpty
            && items[i].name.lowercased().contains("click") {
            return items[i].filePath
        }
        for i in chain where items[i].mediaType == .audio && !items[i].filePath.isEmpty {
            return items[i].filePath
        }
        return nil
    }
}
