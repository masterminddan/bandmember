import Foundation
import Combine

/// In-memory cache + on-disk sidecar persistence for lyric documents.
/// Sidecar is saved next to the audio file as `<filename>.lyrics.json`.
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published private var cache: [String: LyricsDocument] = [:]

    private init() {}

    func sidecarPath(for audioPath: String) -> String {
        return audioPath + ".lyrics.json"
    }

    /// Loads from sidecar if not yet cached. Safe to call from any thread.
    func lyrics(for audioPath: String) -> LyricsDocument? {
        if let cached = cache[audioPath] { return cached }
        let sidecar = sidecarPath(for: audioPath)
        guard FileManager.default.fileExists(atPath: sidecar) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: sidecar))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(LyricsDocument.self, from: data)
            DispatchQueue.main.async { self.cache[audioPath] = doc }
            return doc
        } catch {
            debugLog("Lyrics: failed to load \(sidecar): \(error)")
            return nil
        }
    }

    func save(_ doc: LyricsDocument, for audioPath: String) {
        cache[audioPath] = doc
        let sidecar = sidecarPath(for: audioPath)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(doc)
            try data.write(to: URL(fileURLWithPath: sidecar))
            debugLog("Lyrics: saved sidecar for \((audioPath as NSString).lastPathComponent) (\(doc.segments.count) segments)")
        } catch {
            debugLog("Lyrics: failed to save \(sidecar): \(error)")
        }
    }

    func delete(for audioPath: String) {
        cache.removeValue(forKey: audioPath)
        let sidecar = sidecarPath(for: audioPath)
        try? FileManager.default.removeItem(atPath: sidecar)
    }

    /// Walks a song chain and returns the first audio item that has lyrics.
    /// Preference order: item named "vocal" (first) → triggered item → first in chain.
    func lyricsForChain(triggeredItemID: UUID, store: PlaylistStore) -> (item: PlaylistItem, doc: LyricsDocument)? {
        guard let idx = store.items.firstIndex(where: { $0.id == triggeredItemID }) else { return nil }
        let chain = store.songChainIndices(forIndex: idx)

        // 1. Explicit match on "vocal" or "lyrics" in the name
        for i in chain {
            let it = store.items[i]
            guard it.mediaType == .audio, !it.filePath.isEmpty else { continue }
            let lower = it.name.lowercased()
            if lower.contains("vocal") || lower.contains("lyrics") || lower.contains("lyric") {
                if let doc = lyrics(for: it.filePath) { return (it, doc) }
            }
        }
        // 2. Triggered item itself
        let triggered = store.items[idx]
        if triggered.mediaType == .audio, !triggered.filePath.isEmpty,
           let doc = lyrics(for: triggered.filePath) {
            return (triggered, doc)
        }
        // 3. Any item in the chain
        for i in chain {
            let it = store.items[i]
            guard it.mediaType == .audio, !it.filePath.isEmpty else { continue }
            if let doc = lyrics(for: it.filePath) { return (it, doc) }
        }
        return nil
    }
}
