import Foundation
import Combine
import WhisperKit

struct WhisperModelInfo: Identifiable, Hashable {
    /// WhisperKit variant identifier (what gets passed to WhisperKitConfig.model).
    let id: String
    let displayName: String
    let approxSizeMB: Int
    let qualityNote: String
}

/// Manages the on-disk catalog of WhisperKit CoreML models and wraps
/// WhisperKit's download/delete operations with progress state for the UI.
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    static let catalog: [WhisperModelInfo] = [
        .init(id: "openai_whisper-tiny.en",
              displayName: "Tiny (English)",
              approxSizeMB: 40,
              qualityNote: "Fastest, rough for singing"),
        .init(id: "openai_whisper-base.en",
              displayName: "Base (English)",
              approxSizeMB: 75,
              qualityNote: "Fast, fair on music"),
        .init(id: "openai_whisper-small.en",
              displayName: "Small (English)",
              approxSizeMB: 250,
              qualityNote: "Good balance — recommended"),
        .init(id: "openai_whisper-medium.en",
              displayName: "Medium (English)",
              approxSizeMB: 800,
              qualityNote: "High accuracy, slower"),
        .init(id: "openai_whisper-large-v3-v20240930_turbo_632MB",
              displayName: "Large v3 Turbo",
              approxSizeMB: 632,
              qualityNote: "Best multilingual, fast (quantized)"),
    ]

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: [String: Double] = [:]   // variant -> fraction
    @Published private(set) var lastError: String? = nil

    /// Root that WhisperKit is told to use; WhisperKit appends
    /// "models/argmaxinc/whisperkit-coreml/<variant>" beneath it.
    private let hubRoot: URL
    /// Folder where installed model directories actually live.
    private let installedDir: URL

    private init() {
        // Store under ~/Library/Application Support/BandMember/ — the standard
        // macOS location for app data. WhisperKit tacks on
        // "models/argmaxinc/whisperkit-coreml/<variant>" beneath `hubRoot`.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        self.hubRoot = appSupport
            .appendingPathComponent("BandMember", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
        self.installedDir = hubRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        try? FileManager.default.createDirectory(at: installedDir,
                                                 withIntermediateDirectories: true)
        migrateFromLegacyLocation()
        refreshInstalled()
    }

    /// If a user downloaded models under ~/Documents/huggingface (pre-fix),
    /// move the variants into the new Application Support location once.
    private func migrateFromLegacyLocation() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let legacyInstalled = docs
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)

        let fm = FileManager.default
        guard let legacyContents = try? fm.contentsOfDirectory(
            at: legacyInstalled,
            includingPropertiesForKeys: [.isDirectoryKey]
        ), !legacyContents.isEmpty else { return }

        for url in legacyContents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDir else { continue }
            let dest = installedDir.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: dest.path) { continue }
            do {
                try fm.moveItem(at: url, to: dest)
                debugLog("Models: migrated \(url.lastPathComponent) from Documents/huggingface")
            } catch {
                debugLog("Models: migration failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// Scans the download directory for installed model folders.
    func refreshInstalled() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: installedDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            installed = []
            return
        }
        var found: Set<String> = []
        for url in contents where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            found.insert(url.lastPathComponent)
        }
        installed = found
    }

    func isInstalled(_ variant: String) -> Bool { installed.contains(variant) }

    func folder(for variant: String) -> URL {
        installedDir.appendingPathComponent(variant, isDirectory: true)
    }

    @MainActor
    func download(_ variant: String) async throws {
        guard downloading[variant] == nil else { return }
        downloading[variant] = 0.0
        lastError = nil
        defer { downloading[variant] = nil }

        debugLog("Models: starting download for \(variant)")
        do {
            let start = Date()
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: hubRoot,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { progress in
                    Task { @MainActor in
                        ModelManager.shared.downloading[variant] = progress.fractionCompleted
                    }
                }
            )
            refreshInstalled()
            let elapsed = Date().timeIntervalSince(start)
            debugLog(String(format: "Models: downloaded %@ in %.1fs", variant, elapsed))
        } catch {
            lastError = "Download failed: \(error.localizedDescription)"
            debugLog("Models: download failed for \(variant): \(error)")
            throw error
        }
    }

    func delete(_ variant: String) {
        let folder = folder(for: variant)
        try? FileManager.default.removeItem(at: folder)
        refreshInstalled()
        debugLog("Models: deleted \(variant)")
    }
}
