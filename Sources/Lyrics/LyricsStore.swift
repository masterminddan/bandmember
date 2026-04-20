import Foundation
import Combine

/// In-memory cache + on-disk sidecar persistence for lyric documents.
/// Sidecar is saved next to the audio file as `<filename>.lyrics.json`.
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published private var cache: [String: LyricsDocument] = [:]
    /// Sidecar file mtime captured when the entry was cached. Used to detect
    /// external edits / retranscriptions and reload from disk.
    private var cachedMTimes: [String: Date] = [:]

    private init() {}

    func sidecarPath(for audioPath: String) -> String {
        return audioPath + ".lyrics.json"
    }

    private func sidecarMTime(_ sidecar: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sidecar) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    /// Loads from sidecar if not yet cached OR if the sidecar on disk is
    /// newer than the cached copy. Safe to call from any thread.
    func lyrics(for audioPath: String) -> LyricsDocument? {
        let sidecar = sidecarPath(for: audioPath)
        let diskMTime = sidecarMTime(sidecar)

        // Fast path: cache hit with matching mtime.
        if let cached = cache[audioPath],
           let cachedAt = cachedMTimes[audioPath],
           let diskMTime = diskMTime,
           diskMTime <= cachedAt {
            return cached
        }
        // If the sidecar doesn't exist, drop any stale cache entry.
        guard diskMTime != nil else {
            cache.removeValue(forKey: audioPath)
            cachedMTimes.removeValue(forKey: audioPath)
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: sidecar))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(LyricsDocument.self, from: data)
            let mtime = diskMTime ?? Date()
            DispatchQueue.main.async {
                self.cache[audioPath] = doc
                self.cachedMTimes[audioPath] = mtime
            }
            debugLog("Lyrics: loaded sidecar for \((audioPath as NSString).lastPathComponent) (\(doc.segments.count) segments, model=\(doc.modelUsed))")
            return doc
        } catch {
            debugLog("Lyrics: failed to load \(sidecar): \(error)")
            return nil
        }
    }

    func save(_ doc: LyricsDocument, for audioPath: String) {
        let sidecar = sidecarPath(for: audioPath)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(doc)
            try data.write(to: URL(fileURLWithPath: sidecar))
            // Update cache after successful write so the mtime we record
            // matches what's actually on disk.
            cache[audioPath] = doc
            cachedMTimes[audioPath] = sidecarMTime(sidecar) ?? Date()
            debugLog("Lyrics: saved sidecar for \((audioPath as NSString).lastPathComponent) (\(doc.segments.count) segments)")
        } catch {
            debugLog("Lyrics: failed to save \(sidecar): \(error)")
        }
    }

    func delete(for audioPath: String) {
        cache.removeValue(forKey: audioPath)
        cachedMTimes.removeValue(forKey: audioPath)
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
