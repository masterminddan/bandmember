import Foundation

enum MediaType: String, Codable, CaseIterable {
    case audio
    case video
    case divider

    var icon: String {
        switch self {
        case .audio: return "speaker.wave.2"
        case .video: return "film"
        case .divider: return "text.justify.leading"
        }
    }

    static func detect(from url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3", "aif", "aiff":
            return .audio
        case "mp4", "mov":
            return .video
        default:
            return .audio
        }
    }
}

/// Predefined color tags for playlist items.
enum ColorTag: String, Codable, CaseIterable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    var displayName: String { rawValue.capitalized }
}

struct PlaylistItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var filePath: String
    var mediaType: MediaType
    var targetDisplayIndex: Int = 0
    var autoFollow: Bool = false
    var masterVolume: Float = 1.0
    var leftVolume: Float = 1.0
    var rightVolume: Float = 1.0
    var colorTag: ColorTag = .none

    /// Session-only playhead start position (seconds). Not saved to JSON.
    var startPosition: Double = 0.0

    /// Exclude startPosition from serialization.
    enum CodingKeys: String, CodingKey {
        case id, name, filePath, mediaType, targetDisplayIndex, autoFollow
        case masterVolume, leftVolume, rightVolume, colorTag
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var fileExists: Bool {
        if mediaType == .divider { return true }
        return FileManager.default.fileExists(atPath: filePath)
    }

    var isDivider: Bool { mediaType == .divider }

    init(url: URL) {
        self.name = url.deletingPathExtension().lastPathComponent
        self.filePath = url.path
        self.mediaType = MediaType.detect(from: url)
    }

    init(dividerName: String) {
        self.name = dividerName
        self.filePath = ""
        self.mediaType = .divider
    }

    // Custom decoder so older JSON files without colorTag still load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        filePath = try c.decode(String.self, forKey: .filePath)
        mediaType = try c.decode(MediaType.self, forKey: .mediaType)
        targetDisplayIndex = try c.decodeIfPresent(Int.self, forKey: .targetDisplayIndex) ?? 0
        autoFollow = try c.decodeIfPresent(Bool.self, forKey: .autoFollow) ?? false
        masterVolume = try c.decodeIfPresent(Float.self, forKey: .masterVolume) ?? 1.0
        leftVolume = try c.decodeIfPresent(Float.self, forKey: .leftVolume) ?? 1.0
        rightVolume = try c.decodeIfPresent(Float.self, forKey: .rightVolume) ?? 1.0
        colorTag = try c.decodeIfPresent(ColorTag.self, forKey: .colorTag) ?? .none
        startPosition = 0.0  // session-only, always starts at 0
    }
}

struct PlaylistDocument: Codable {
    var items: [PlaylistItem]
    var version: Int = 1
}
