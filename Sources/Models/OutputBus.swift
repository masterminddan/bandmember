import Foundation

/// A named, device-agnostic destination for cue audio (e.g. "FOH", "IEM").
/// Cues route to a bus; per-device mappings translate the bus to physical
/// output channel(s) at play time.
struct OutputBus: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Display name. Free-form, no uniqueness enforced (but the editor warns).
    var name: String
}

/// Per-device routing for a single bus. Choosing `.stereo` occupies the
/// pair `(startChannel, startChannel + 1)`; choosing `.monoSum` occupies
/// a single channel and sums L+R (-3 dB) into it.
///
/// Mono-sum-vs-stereo is per-device intentionally: a "FOH" bus might be
/// stereo on a 4-out interface but get mono-summed to a single output on
/// a rig where only one DI is available.
enum BusAssignment: Codable, Hashable {
    case stereo(startChannel: Int)
    case monoSum(channel: Int)

    /// 1-based first physical channel.
    var startChannel: Int {
        switch self {
        case .stereo(let c), .monoSum(let c): return c
        }
    }
    /// Number of physical output channels consumed (1 or 2).
    var channelWidth: Int {
        switch self {
        case .stereo:  return 2
        case .monoSum: return 1
        }
    }
    var isMonoSum: Bool {
        if case .monoSum = self { return true }
        return false
    }
}

/// Per-device routing for the named buses. `assignments[busID]` describes
/// where (and in what shape) that bus lands on this device, or nil if the
/// bus is unmapped on this device.
struct DeviceMapping: Codable, Hashable {
    /// CoreAudio device UID — stable across reboots and reconnections.
    var deviceUID: String
    /// Last-seen human name of the device. Shown in missing-device alerts
    /// when the device isn't currently connected.
    var deviceName: String
    var assignments: [UUID: BusAssignment] = [:]

    /// Same on-disk shape as the synthesized encoder (a flat array of
    /// alternating bus-ID / assignment entries, which is how Swift encodes
    /// a UUID-keyed dictionary), but with the pairs sorted by bus ID.
    /// Dictionary iteration order changes every launch; sorting keeps the
    /// saved file byte-stable when nothing really changed.
    /// Decoding stays synthesized, so existing files load unchanged.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceUID, forKey: .deviceUID)
        try c.encode(deviceName, forKey: .deviceName)
        var pairs = c.nestedUnkeyedContainer(forKey: .assignments)
        for (busID, assignment) in assignments.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            try pairs.encode(busID)
            try pairs.encode(assignment)
        }
    }
}

/// Persistence container for the machine-local bus + mapping
/// configuration. Stored in Application Support, separate from any
/// playlist file, and never committed: device UIDs embed hardware serial
/// numbers and Bluetooth addresses.
struct OutputBusConfig: Codable {
    var buses: [OutputBus] = []
    var mappings: [DeviceMapping] = []
    /// UUID of the bus that acts as the silent fallback (used when a cue's
    /// bus is missing or unmapped on the active device). Persisted so the
    /// designation survives renaming the bus's display name.
    var mainBusID: UUID? = nil
    var version: Int = 1
}

/// The git-tracked subset of the configuration: just the buses. Stored at
/// `config/output-buses.json` in the source checkout (see `OutputBusStore`)
/// so the bus IDs that playlists reference resolve on every machine.
/// Deliberately has no device information in it.
struct SharedBusConfig: Codable {
    var buses: [OutputBus] = []
    var mainBusID: UUID? = nil
    var version: Int = 1
}

// MARK: - Legacy decoding

/// Older configs stored `isMonoSum` on the bus and a bare `Int` per
/// assignment. We decode into the new model, treating any old "mono-sum"
/// bus's assignments as `.monoSum(channel:)` and every other entry as
/// `.stereo(startChannel:)`. The decoder is invoked by `OutputBusStore.load`.
struct LegacyOutputBus: Codable {
    var id: UUID
    var name: String
    var isMonoSum: Bool?
}

struct LegacyDeviceMapping: Codable {
    var deviceUID: String
    var deviceName: String
    var assignments: [UUID: Int]
}

struct LegacyOutputBusConfig: Codable {
    var buses: [LegacyOutputBus]?
    var mappings: [LegacyDeviceMapping]?
    var mainBusID: UUID?
    var version: Int?
}
