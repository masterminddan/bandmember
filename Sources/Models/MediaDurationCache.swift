import AVFoundation
import Combine
import Foundation

/// Lengths of the media files in the playlist, read in the background the
/// first time each one is asked for. Rows show them, and the show clock
/// adds them up to see how much music is left in the set.
///
/// Main-thread only: views ask from their bodies and results are published
/// back on the main queue.
final class MediaDurationCache: ObservableObject {
    static let shared = MediaDurationCache()

    /// Seconds, keyed by file path.
    @Published private(set) var durations: [String: Double] = [:]
    /// Paths being read right now, and paths that couldn't be read (so a
    /// missing or broken file isn't retried on every redraw).
    private var pending: Set<String> = []
    private var failed: Set<String> = []

    /// Length in seconds of the file at `path`, or nil while it is still
    /// being read or if it can't be read. Asking starts the read; the
    /// published `durations` changes when it lands.
    func duration(forPath path: String) -> Double? {
        if let known = durations[path] { return known }
        requestRead(path)
        return nil
    }

    /// Longest of `items` (the length of a group whose tracks play
    /// together), or nil when none of them has a known length yet.
    func duration(of items: [PlaylistItem]) -> Double? {
        items.compactMap { $0.isMedia ? duration(forPath: $0.filePath) : nil }.max()
    }

    /// Forgets everything, so files that changed on disk are re-read.
    func invalidate() {
        durations = [:]
        failed = []
    }

    private func requestRead(_ path: String) {
        guard !pending.contains(path), !failed.contains(path) else { return }
        pending.insert(path)
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .utility) {
            let seconds = await Self.readDuration(of: url)
            await MainActor.run {
                self.pending.remove(path)
                if let seconds {
                    self.durations[path] = seconds
                } else {
                    self.failed.insert(path)
                }
            }
        }
    }

    /// The length the engine will actually play. `AVAudioFile.length`
    /// underreports MP3 / AAC (decoder priming and padding), so for audio
    /// the larger of the asset's and the file's length is used, matching
    /// `PlaybackEngine.prepareAudioCue`.
    private static func readDuration(of url: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let assetSeconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? .nan
        var fileSeconds: Double = .nan
        if MediaType.detect(from: url) == .audio, let file = try? AVAudioFile(forReading: url) {
            fileSeconds = Double(file.length) / file.processingFormat.sampleRate
        }
        let candidates = [assetSeconds, fileSeconds].filter { $0.isFinite && $0 > 0 }
        return candidates.max()
    }
}
