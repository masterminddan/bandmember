import Foundation

/// Writes debug messages to both stderr (visible in terminal) and a log file.
func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    // Write to stderr (more reliable than stdout for GUI apps)
    FileHandle.standardError.write(Data(line.utf8))
    // Also append to log file
    let logPath = "/tmp/BandMember.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}
