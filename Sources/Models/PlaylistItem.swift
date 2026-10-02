import Foundation

enum MediaType: String, Codable, CaseIterable {
    case audio
    case video
    case divider
    /// Header row of a group: a named set of tracks that play together.
    case group

    var icon: String {
        switch self {
        case .audio: return "speaker.wave.2"
        case .video: return "film"
        case .divider: return "text.justify.leading"
        case .group: return "folder"
        }
    }

    static func detect(from url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        return MediaFileTypes.videoExtensions.contains(ext) ? .video : .audio
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
    /// Legacy "play next" flag. Groups replaced it: a playlist saved before
    /// groups existed is converted from these flags on load, and they are
    /// written back out on save (derived from the groups) only so that an
    /// older build can still open the file. Nothing reads it at play time.
    var autoFollow: Bool = false
    /// For a track inside a group, the ID of the group's header item. The
    /// tracks of a group always sit directly under their header; see
    /// `PlaylistStore.normalizeGroups`.
    var groupID: UUID? = nil
    /// Unchecked entries are skipped: a disabled track doesn't play with
    /// its group, and a disabled group header switches off the whole group.
    var isEnabled: Bool = true
    var masterVolume: Float = 1.0
    var leftVolume: Float = 1.0
    var rightVolume: Float = 1.0
    var colorTag: ColorTag = .none
    var outputRouting: OutputRouting = .defaultRouting
    /// When true, the cue is raised by `limiterBoostDB` and limited back to
    /// its original peak level before the volume controls — quiet passages
    /// come up, loud ones stay where they were.
    var limiterEnabled: Bool = false
    var limiterBoostDB: Float = PlaylistItem.defaultLimiterBoostDB
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
        case limiterEnabled, limiterBoostDB
        case groupID, isGroupHeader, isEnabled
    }

    static let defaultLimiterBoostDB: Float = 12
    static let limiterBoostRangeDB: ClosedRange<Float> = 0...30

    /// `limiterBoostDB` as the linear gain the audio unit takes.
    var limiterBoostGain: Float {
        powf(10, limiterBoostDB / 20)
    }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var fileExists: Bool {
        if !isMedia { return true }
        return FileManager.default.fileExists(atPath: filePath)
    }

    var isDivider: Bool { mediaType == .divider }
    var isGroup: Bool { mediaType == .group }
    /// True for rows that actually play something (audio or video), as
    /// opposed to dividers and group headers.
    var isMedia: Bool { mediaType == .audio || mediaType == .video }

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

    init(groupName: String, id: UUID = UUID()) {
        self.id = id
        self.name = groupName
        self.filePath = ""
        self.mediaType = .group
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
            && lhs.groupID == rhs.groupID
            && lhs.isEnabled == rhs.isEnabled
            && lhs.masterVolume == rhs.masterVolume
            && lhs.leftVolume == rhs.leftVolume
            && lhs.rightVolume == rhs.rightVolume
            && lhs.colorTag == rhs.colorTag
            && lhs.outputRouting == rhs.outputRouting
            && lhs.showLyrics == rhs.showLyrics
            && lhs.limiterEnabled == rhs.limiterEnabled
            && lhs.limiterBoostDB == rhs.limiterBoostDB
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
        // A group header is written as a divider plus a marker, so builds
        // from before groups existed still load the file (they show the
        // header as a plain divider above its tracks).
        let storedType = try c.decode(MediaType.self, forKey: .mediaType)
        let isGroupHeader = try c.decodeIfPresent(Bool.self, forKey: .isGroupHeader) ?? false
        mediaType = isGroupHeader ? .group : storedType
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        targetDisplayIndex = try c.decodeIfPresent(Int.self, forKey: .targetDisplayIndex) ?? 0
        autoFollow = try c.decodeIfPresent(Bool.self, forKey: .autoFollow) ?? false
        masterVolume = try c.decodeIfPresent(Float.self, forKey: .masterVolume) ?? 1.0
        leftVolume = try c.decodeIfPresent(Float.self, forKey: .leftVolume) ?? 1.0
        rightVolume = try c.decodeIfPresent(Float.self, forKey: .rightVolume) ?? 1.0
        colorTag = try c.decodeIfPresent(ColorTag.self, forKey: .colorTag) ?? .none
        outputRouting = try c.decodeIfPresent(OutputRouting.self, forKey: .outputRouting)
            ?? .defaultRouting
        showLyrics = try c.decodeIfPresent(Bool.self, forKey: .showLyrics) ?? false
        limiterEnabled = try c.decodeIfPresent(Bool.self, forKey: .limiterEnabled) ?? false
        limiterBoostDB = try c.decodeIfPresent(Float.self, forKey: .limiterBoostDB)
            ?? PlaylistItem.defaultLimiterBoostDB
        startPosition = 0.0  // session-only, always starts at 0
        endPosition = nil    // session-only
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(filePath, forKey: .filePath)
        // See `init(from:)`: headers go out as dividers plus a marker.
        try c.encode(isGroup ? MediaType.divider : mediaType, forKey: .mediaType)
        if isGroup { try c.encode(true, forKey: .isGroupHeader) }
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(targetDisplayIndex, forKey: .targetDisplayIndex)
        try c.encode(autoFollow, forKey: .autoFollow)
        try c.encode(masterVolume, forKey: .masterVolume)
        try c.encode(leftVolume, forKey: .leftVolume)
        try c.encode(rightVolume, forKey: .rightVolume)
        try c.encode(colorTag, forKey: .colorTag)
        try c.encode(outputRouting, forKey: .outputRouting)
        try c.encode(showLyrics, forKey: .showLyrics)
        try c.encode(limiterEnabled, forKey: .limiterEnabled)
        try c.encode(limiterBoostDB, forKey: .limiterBoostDB)
    }
}

struct PlaylistDocument: Codable {
    /// Version 1 chained tracks with per-item "play next" flags; version 2
    /// has groups (header items plus `groupID` on their tracks).
    static let currentVersion = 2

    var items: [PlaylistItem]
    var version: Int = PlaylistDocument.currentVersion
}
