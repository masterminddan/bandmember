import Foundation

/// Writes debug messages to a per-user log file at the macOS-standard
/// location `~/Library/Logs/BandMember/BandMember.log` (and also to
/// stderr, which is useful when launched from a terminal).
///
/// The file rolls over once it reaches ~1 MB: the current log moves to
/// `BandMember.log.1` (overwriting any previous rollover) and a fresh
/// log is started. This bounds disk use at roughly 2 MB regardless of
/// how long the app has been running on a given machine — small enough
/// to leave on by default but big enough to capture a useful trace when
/// a user files a bug.
private enum LogConfig {
    static let maxBytes: UInt64 = 1_000_000  // ~1 MB
}

private let logFileURL: URL = {
    let fm = FileManager.default
    let base = (try? fm.url(for: .libraryDirectory,
                            in: .userDomainMask,
                            appropriateFor: nil,
                            create: false))
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    let dir = base.appendingPathComponent("Logs/BandMember", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("BandMember.log")
}()

private let logQueue = DispatchQueue(label: "com.bandmember.debuglog")

func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    let data = Data(line.utf8)

    // stderr — invisible when launched from Finder/dock but useful when
    // running the binary from a terminal during development.
    FileHandle.standardError.write(data)

    // Serialize file writes so the rotation check stays consistent.
    logQueue.async {
        rotateIfNeeded()
        let path = logFileURL.path
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

private func rotateIfNeeded() {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
          let size = attrs[.size] as? UInt64,
          size > LogConfig.maxBytes else { return }
    let rolled = logFileURL.deletingLastPathComponent()
        .appendingPathComponent("BandMember.log.1")
    try? fm.removeItem(at: rolled)
    try? fm.moveItem(at: logFileURL, to: rolled)
}
