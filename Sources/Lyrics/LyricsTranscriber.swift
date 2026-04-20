import Foundation
import Combine
import WhisperKit

/// ObservableObject that owns a WhisperKit instance and manages transcription
/// jobs. One instance of WhisperKit is kept around per model variant so
/// repeated transcriptions don't pay load-cost each time.
@MainActor
final class LyricsTranscriber: ObservableObject {
    static let shared = LyricsTranscriber()

    struct JobStatus {
        enum State {
            case idle
            case loadingModel
            case transcribing(fraction: Double)
            case done
            case failed(String)
        }
        var state: State
    }

    /// Keyed by audio file path — one job per audio file at a time.
    @Published private(set) var jobs: [String: JobStatus] = [:]

    private var whisper: WhisperKit?
    private var loadedVariant: String?

    private init() {}

    func status(for path: String) -> JobStatus.State {
        jobs[path]?.state ?? .idle
    }

    /// Kicks off a transcription. Returns immediately; progress arrives via `jobs`.
    /// When finished, the result is persisted via `LyricsStore.shared.save`.
    func transcribe(audioPath: String, variant: String) {
        if case .transcribing = jobs[audioPath]?.state { return }
        if case .loadingModel = jobs[audioPath]?.state { return }

        let shortPath = (audioPath as NSString).lastPathComponent
        jobs[audioPath] = JobStatus(state: .loadingModel)
        debugLog("Lyrics: transcribe() called for \(shortPath) with variant=\(variant)")

        Task { @MainActor in
            do {
                let loadStart = Date()
                try await ensureModel(variant: variant)
                let loadElapsed = Date().timeIntervalSince(loadStart)
                debugLog(String(format: "Lyrics: model ready in %.1fs, starting transcription for %@", loadElapsed, shortPath))

                guard let whisper = self.whisper else {
                    throw NSError(domain: "LyricsTranscriber", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
                }

                self.jobs[audioPath] = JobStatus(state: .transcribing(fraction: 0))

                let options = DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: "en",
                    skipSpecialTokens: true,
                    withoutTimestamps: false,
                    wordTimestamps: false
                )

                let transcribeStart = Date()
                let results: [TranscriptionResult] = try await whisper.transcribe(
                    audioPath: audioPath,
                    decodeOptions: options,
                    callback: { progress in
                        // progress.text grows over time — we don't have a real
                        // fraction, so use a smoothed value based on token count.
                        let fraction = min(0.99, Double(progress.tokens.count) / 1000.0 + 0.1)
                        Task { @MainActor in
                            LyricsTranscriber.shared.jobs[audioPath] =
                                JobStatus(state: .transcribing(fraction: fraction))
                        }
                        return nil
                    }
                )
                let transcribeElapsed = Date().timeIntervalSince(transcribeStart)

                let doc = Self.buildDocument(
                    audioPath: audioPath,
                    modelVariant: variant,
                    results: results
                )
                LyricsStore.shared.save(doc, for: audioPath)
                self.jobs[audioPath] = JobStatus(state: .done)
                debugLog(String(format: "Lyrics: transcription complete for %@ in %.1fs — %d segments",
                                shortPath, transcribeElapsed, doc.segments.count))
            } catch {
                self.jobs[audioPath] = JobStatus(state: .failed(error.localizedDescription))
                debugLog("Lyrics: transcription FAILED for \(shortPath): \(error)")
            }
        }
    }

    /// Loads a WhisperKit instance for the given variant, reusing the cached
    /// one if it's already loaded. Local folder is passed explicitly to avoid
    /// re-downloading anything that's already installed.
    private func ensureModel(variant: String) async throws {
        if loadedVariant == variant, whisper != nil {
            debugLog("Lyrics: reusing already-loaded WhisperKit for \(variant)")
            return
        }

        let folder = ModelManager.shared.folder(for: variant)
        debugLog("Lyrics: initializing WhisperKit for \(variant) at \(folder.path)")
        debugLog("Lyrics: NOTE — first load of a model does CoreML specialization (2–8 min for turbo). Subsequent loads are <1s.")

        let config = WhisperKitConfig(
            model: variant,
            modelFolder: folder.path,
            verbose: true,
            logLevel: .info,
            prewarm: false,
            download: false
        )
        let instance = try await WhisperKit(config)
        self.whisper = instance
        self.loadedVariant = variant
        debugLog("Lyrics: WhisperKit loaded for \(variant)")
    }

    private static func buildDocument(
        audioPath: String,
        modelVariant: String,
        results: [TranscriptionResult]
    ) -> LyricsDocument {
        var segments: [LyricSegment] = []
        var language: String? = nil
        for r in results {
            if language == nil { language = r.language }
            for seg in r.segments {
                segments.append(LyricSegment(
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    start: Double(seg.start),
                    end: Double(seg.end)
                ))
            }
        }
        return LyricsDocument(
            audioFilePath: audioPath,
            segments: segments,
            modelUsed: modelVariant,
            language: language,
            createdAt: Date()
        )
    }
}
