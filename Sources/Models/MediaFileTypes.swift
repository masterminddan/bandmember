import Foundation
import UniformTypeIdentifiers

/// Single source of truth for which files BandMember will accept as cues.
///
/// Playback itself is format-agnostic — `PlaybackEngine` decides between
/// `AVAudioFile` scheduling and a full `AVAssetReader` decode by comparing
/// durations, not by extension — so this list only gates the open panel and
/// the drop targets. Anything AVFoundation can decode belongs here.
enum MediaFileTypes {
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "adts",
        "aif", "aiff", "aifc",
        "wav", "wave",
        "caf", "flac",
    ]

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    static let allExtensions: Set<String> = audioExtensions.union(videoExtensions)

    /// Content types for `NSOpenPanel.allowedContentTypes`, derived from the
    /// extension list so the two can't drift apart.
    static let contentTypes: [UTType] = allExtensions
        .compactMap { UTType(filenameExtension: $0) }

    static func isSupported(_ url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }
}
