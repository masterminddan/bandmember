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

/// Per-cue output routing. Points at a named `OutputBus`; the bus-to-channel
/// translation is done at play time using the active device's `DeviceMapping`.
///
/// Cues no longer encode physical channels or device identity directly —
/// changing rigs only requires re-mapping buses on the new device, not
/// editing every cue.
struct OutputRouting: Codable, Hashable {
    var busID: UUID

    /// New playlists default to the Main bus. Older playlists migrate via
    /// `init(from:)`, which also handles the legacy string-enum form.
    static var defaultRouting: OutputRouting {
        OutputRouting(busID: OutputBusStore.shared.mainBusID)
    }

    enum CodingKeys: String, CodingKey { case busID }

    init(busID: UUID) {
        self.busID = busID
    }

    init(from decoder: Decoder) throws {
        // New format: { "busID": "<uuid>" }
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let id = try? c.decode(UUID.self, forKey: .busID) {
            self.busID = id
            return
        }
        // Legacy format: a single JSON string ("stereo" / "monoLeft" / "monoRight").
        if let svc = try? decoder.singleValueContainer(),
           let raw = try? svc.decode(String.self) {
            switch raw {
            case "monoLeft":
                self.busID = OutputBusStore.shared.legacyMonoLeftBusID()
            case "monoRight":
                self.busID = OutputBusStore.shared.legacyMonoRightBusID()
            default:
                self.busID = OutputBusStore.shared.mainBusID
            }
            return
        }
        self.busID = OutputBusStore.shared.mainBusID
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
    var outputRouting: OutputRouting = .defaultRouting
    /// When true, a fullscreen lyrics presenter opens on `targetDisplayIndex`
    /// when this item is triggered, showing timed lyrics from any track in
    /// the auto-follow chain.
    var showLyrics: Bool = false

    /// Session-only playhead start position (seconds). Not saved to JSON.
    var startPosition: Double = 0.0

    /// Session-only loop end position (seconds). When set and > startPosition,
    /// audio playback loops back to startPosition on reaching this point.
    var endPosition: Double? = nil

    /// Exclude session-only positions from serialization.
    enum CodingKeys: String, CodingKey {
        case id, name, filePath, mediaType, targetDisplayIndex, autoFollow
        case masterVolume, leftVolume, rightVolume, colorTag, outputRouting, showLyrics
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

    // Equality / hash ignore session-only fields (startPosition, endPosition)
    // so the "edited" indicator only fires on changes that would actually be saved.
    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.filePath == rhs.filePath
            && lhs.mediaType == rhs.mediaType
            && lhs.targetDisplayIndex == rhs.targetDisplayIndex
            && lhs.autoFollow == rhs.autoFollow
            && lhs.masterVolume == rhs.masterVolume
            && lhs.leftVolume == rhs.leftVolume
            && lhs.rightVolume == rhs.rightVolume
            && lhs.colorTag == rhs.colorTag
            && lhs.outputRouting == rhs.outputRouting
            && lhs.showLyrics == rhs.showLyrics
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
        outputRouting = try c.decodeIfPresent(OutputRouting.self, forKey: .outputRouting)
            ?? .defaultRouting
        showLyrics = try c.decodeIfPresent(Bool.self, forKey: .showLyrics) ?? false
        startPosition = 0.0  // session-only, always starts at 0
        endPosition = nil    // session-only
    }
}

struct PlaylistDocument: Codable {
    var items: [PlaylistItem]
    var version: Int = 1
}
