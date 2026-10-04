import Foundation

/// How a playlist finds its media.
///
/// A saved playlist records two paths per file: the absolute path it had on
/// the machine that saved it, and its path relative to the playlist's own
/// folder. On load the relative one wins if a file is there, so a playlist
/// that has been moved or copied *with* its media — an exported bundle, or
/// the whole project folder synced to another laptop — keeps working no
/// matter what the folders above it are called. If nothing is there (the
/// playlist file was moved on its own), the absolute path is used, exactly
/// as before relative paths existed.
enum PlaylistPaths {
    /// Path of `filePath` relative to `folder` ("audio/song.aif",
    /// "../raw aifs/song.aif"). Nil when the two share nothing but the root,
    /// e.g. media on a different volume.
    static func relativePath(from folder: URL, to filePath: String) -> String? {
        guard !filePath.isEmpty else { return nil }
        let base = folder.standardizedFileURL.pathComponents
        let target = URL(fileURLWithPath: filePath).standardizedFileURL.pathComponents
        var shared = 0
        while shared < base.count, shared < target.count, base[shared] == target[shared] {
            shared += 1
        }
        guard shared > 1 else { return nil }   // only "/" in common
        let up = Array(repeating: "..", count: base.count - shared)
        return (up + target[shared...]).joined(separator: "/")
    }

    /// `item` as it should be held in memory after loading from a playlist
    /// in `playlistFolder`: `filePath` pointing at the media relative to the
    /// playlist if it's there, at its recorded absolute path otherwise.
    static func resolved(_ item: PlaylistItem, playlistFolder: URL) -> PlaylistItem {
        var item = item
        if let relative = item.relativePath, !relative.isEmpty {
            let candidate = playlistFolder.appendingPathComponent(relative).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: candidate) {
                item.filePath = candidate
            }
        }
        item.relativePath = nil
        return item
    }
}

/// Packs a playlist and every file it uses into one self-contained folder:
///
///     <name>/
///         <name>.json
///         audio/   (audio files, plus their lyrics sidecars)
///         video/
///
/// and zips it. Unzipped anywhere on any machine, the playlist inside opens
/// and finds its media through the relative paths written into it.
enum PlaylistBundle {
    struct Summary {
        var fileCount = 0
        var byteCount: Int64 = 0
        /// Names of playlist entries whose file wasn't found and so isn't
        /// in the bundle.
        var missing: [String] = []
    }

    struct Cancelled: Error {}

    /// Sidecar files that belong with a media file and travel with it.
    private static func sidecars(for path: String) -> [String] {
        [path + ".lyrics.json"].filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Builds the bundle folder for `items` inside `parent` and returns it.
    /// Each distinct file is copied once, however many entries use it; two
    /// different files with the same name get distinct names. On the same
    /// APFS volume the copies are clones, so they take neither time nor
    /// space. `progress` is called before each file with (done, total).
    static func stage(items: [PlaylistItem],
                      name: String,
                      in parent: URL,
                      progress: (Int, Int) -> Void = { _, _ in },
                      isCancelled: () -> Bool = { false }) throws -> (folder: URL, summary: Summary) {
        let fm = FileManager.default
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var summary = Summary()
        var placed: [String: String] = [:]      // source path → path inside the bundle
        var taken: Set<String> = []             // bundle paths already used (lowercased)

        let sources = items.filter { $0.isMedia && !$0.filePath.isEmpty }
        let total = Set(sources.map(\.filePath)).count

        for item in sources where placed[item.filePath] == nil {
            if isCancelled() { throw Cancelled() }
            progress(placed.count, total)
            guard fm.fileExists(atPath: item.filePath) else {
                summary.missing.append(item.name)
                placed[item.filePath] = ""      // looked at; nothing to point to
                continue
            }

            let subfolder = item.mediaType == .video ? "video" : "audio"
            let source = URL(fileURLWithPath: item.filePath)
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var fileName = source.lastPathComponent
            var n = 2
            while taken.contains("\(subfolder)/\(fileName)".lowercased()) {
                fileName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            let relative = "\(subfolder)/\(fileName)"
            taken.insert(relative.lowercased())

            let destination = folder.appendingPathComponent(relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            for sidecar in sidecars(for: item.filePath) {
                // Keep the sidecar's suffix on the (possibly renamed) file.
                let suffix = String(sidecar.dropFirst(item.filePath.count))
                try fm.copyItem(atPath: sidecar, toPath: destination.path + suffix)
            }

            placed[item.filePath] = relative
            summary.fileCount += 1
            summary.byteCount += (try? fm.attributesOfItem(atPath: item.filePath)[.size] as? Int64) ?? 0
        }
        progress(total, total)

        // The playlist itself: absolute paths left as they are (they still
        // work on this machine), relative paths pointing into the bundle.
        var out = PlaylistStore.withLegacyChainFlags(items)
        for i in out.indices where out[i].isMedia {
            let relative = placed[out[i].filePath] ?? ""
            out[i].relativePath = relative.isEmpty ? nil : relative
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(PlaylistDocument(items: out))
            .write(to: folder.appendingPathComponent("\(name).json"))

        return (folder, summary)
    }

    /// Zips `folder` (keeping it as the top-level entry) to `zipURL`.
    /// `onStart` receives the running process so the caller can cancel it.
    static func zip(folder: URL, to zipURL: URL, onStart: (Process) -> Void = { _ in }) throws {
        try? FileManager.default.removeItem(at: zipURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // Stored, not compressed: audio and video barely shrink (a 12 GB
        // set list saved 6 %) and deflating them takes several times longer
        // than just writing them out.
        process.arguments = ["-c", "-k", "--zlibCompressionLevel", "0", "--keepParent",
                             folder.path, zipURL.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        onStart(process)
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            try? FileManager.default.removeItem(at: zipURL)
            throw Cancelled()
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: zipURL)
            throw NSError(domain: "PlaylistBundle", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                        message.isEmpty ? "Could not create the zip file." : message])
        }
    }
}

/// Runs a bundle export in the background and reports progress for the UI.
final class PlaylistBundleExporter: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""

    private let lock = NSLock()
    private var cancelled = false
    private var zipProcess: Process?

    /// Exports `items` as `<zip name>.zip` at `zipURL`. `completion` runs on
    /// the main queue.
    func export(items: [PlaylistItem], to zipURL: URL,
                completion: @escaping (Result<PlaylistBundle.Summary, Error>) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        status = "Collecting files…"
        lock.lock(); cancelled = false; zipProcess = nil; lock.unlock()

        let name = zipURL.deletingPathExtension().lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var staging: URL?
            let result: Result<PlaylistBundle.Summary, Error>
            do {
                // Stage next to the media rather than next to the zip: on
                // the same volume the "copies" are free clones, so the only
                // real writing is the zip itself.
                let anchor = items.first { $0.isMedia && fm.fileExists(atPath: $0.filePath) }
                    .map { URL(fileURLWithPath: $0.filePath) } ?? zipURL
                let temp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: anchor, create: true)
                staging = temp
                let staged = try PlaylistBundle.stage(
                    items: items, name: name, in: temp,
                    progress: { done, total in
                        DispatchQueue.main.async { self.status = "Collecting files… \(done) of \(total)" }
                    },
                    isCancelled: { self.isCancelled })
                DispatchQueue.main.async { self.status = "Writing the zip…" }
                try PlaylistBundle.zip(folder: staged.folder, to: zipURL) { process in
                    self.lock.lock(); self.zipProcess = process; self.lock.unlock()
                    if self.isCancelled { process.terminate() }
                }
                result = .success(staged.summary)
            } catch {
                result = .failure(error)
            }
            if let staging = staging { try? fm.removeItem(at: staging) }
            DispatchQueue.main.async {
                self.isRunning = false
                self.status = ""
                completion(result)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = zipProcess
        lock.unlock()
        process?.terminate()
        status = "Cancelling…"
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
