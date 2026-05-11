import Foundation
import Combine

/// Shared, app-wide configuration of named output buses and per-device
/// channel assignments. Persisted to Application Support.
///
/// One bus is designated "default" (`mainBusID`) — it's guaranteed to
/// exist and acts as the fallback when a cue's bus is missing or unmapped
/// on the active device. The default bus's display name is freely editable.
final class OutputBusStore: ObservableObject {
    static let shared = OutputBusStore()

    @Published private(set) var buses: [OutputBus] = []
    @Published private(set) var mappings: [DeviceMapping] = []

    /// busID of the bus designated as the silent fallback. Persisted.
    private(set) var mainBusID: UUID = UUID()

    private let configURL: URL
    private var saveDebounce: AnyCancellable?

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("BandMember", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.configURL = dir.appendingPathComponent("output-mappings.json")

        load()
        ensureDefaults()

        // Coalesce writes — bus/mapping edits often come in bursts. Save
        // 200 ms after the last change.
        saveDebounce = Publishers.CombineLatest($buses, $mappings)
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.save() }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: configURL) else { return }
        let dec = JSONDecoder()

        // Try the current schema first.
        if let cfg = try? dec.decode(OutputBusConfig.self, from: data) {
            self.buses = cfg.buses
            self.mappings = cfg.mappings
            self.mainBusID = cfg.mainBusID ?? cfg.buses.first?.id ?? mainBusID
            return
        }
        // Fall back to the pre-`BusAssignment` schema (mono-sum was a per-bus
        // boolean, assignments were bare Ints). Convert in-place.
        if let legacy = try? dec.decode(LegacyOutputBusConfig.self, from: data) {
            let legacyBuses = legacy.buses ?? []
            let monoBusIDs = Set(legacyBuses.filter { $0.isMonoSum == true }.map { $0.id })
            self.buses = legacyBuses.map { OutputBus(id: $0.id, name: $0.name) }
            self.mappings = (legacy.mappings ?? []).map { lm in
                var m = DeviceMapping(deviceUID: lm.deviceUID, deviceName: lm.deviceName)
                for (busID, ch) in lm.assignments {
                    m.assignments[busID] = monoBusIDs.contains(busID)
                        ? .monoSum(channel: ch)
                        : .stereo(startChannel: ch)
                }
                return m
            }
            if let id = legacy.mainBusID, self.buses.contains(where: { $0.id == id }) {
                self.mainBusID = id
            } else if let m = self.buses.first(where: { $0.name == "Main" }) {
                self.mainBusID = m.id
            } else if let first = self.buses.first {
                self.mainBusID = first.id
            }
        }
    }

    private func save() {
        let cfg = OutputBusConfig(buses: buses, mappings: mappings, mainBusID: mainBusID)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) {
            try? data.write(to: configURL)
        }
    }

    private func ensureDefaults() {
        if buses.contains(where: { $0.id == mainBusID }) { return }
        if let existing = buses.first(where: { $0.name == "Main" }) {
            mainBusID = existing.id
        } else {
            let main = OutputBus(name: "Main")
            mainBusID = main.id
            buses.insert(main, at: 0)
        }
    }

    // MARK: - Bus lookup

    func bus(id: UUID) -> OutputBus? {
        buses.first { $0.id == id }
    }

    var mainBus: OutputBus {
        buses.first { $0.id == mainBusID } ?? OutputBus(name: "Main")
    }

    // MARK: - Bus mutation

    @discardableResult
    func addBus(name: String) -> OutputBus {
        let bus = OutputBus(name: uniqueName(from: name))
        buses.append(bus)
        return bus
    }

    func renameBus(id: UUID, to newName: String) {
        guard let idx = buses.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        buses[idx].name = trimmed
    }

    func deleteBus(id: UUID) {
        guard id != mainBusID else { return }  // default bus is permanent
        buses.removeAll { $0.id == id }
        for i in mappings.indices {
            mappings[i].assignments.removeValue(forKey: id)
        }
    }

    /// Generates a name that doesn't collide with an existing bus.
    private func uniqueName(from base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Bus" : trimmed
        var attempt = candidate
        var n = 2
        while buses.contains(where: { $0.name.caseInsensitiveCompare(attempt) == .orderedSame }) {
            attempt = "\(candidate) \(n)"
            n += 1
        }
        return attempt
    }

    // MARK: - Device mappings

    func mapping(for deviceUID: String) -> DeviceMapping? {
        mappings.first { $0.deviceUID == deviceUID }
    }

    /// Ensures a `DeviceMapping` exists for the given device. Auto-assigns
    /// the default bus to a stereo pair on channels 1-2 the first time a
    /// device is seen (provided it has ≥ 2 channels).
    func ensureMapping(deviceUID: String, deviceName: String, channelCount: Int) {
        if let idx = mappings.firstIndex(where: { $0.deviceUID == deviceUID }) {
            // Refresh remembered name in case it changed.
            mappings[idx].deviceName = deviceName
            return
        }
        var m = DeviceMapping(deviceUID: deviceUID, deviceName: deviceName)
        if channelCount >= 2 {
            m.assignments[mainBusID] = .stereo(startChannel: 1)
        } else if channelCount == 1 {
            m.assignments[mainBusID] = .monoSum(channel: 1)
        }
        mappings.append(m)
    }

    func setAssignment(busID: UUID, deviceUID: String, assignment: BusAssignment?) {
        // Auto-create the mapping row if we don't have one yet — covers the
        // case where the user opens the editor and assigns a bus on a
        // device that's connected but has never been the active output.
        let idx: Int
        if let existing = mappings.firstIndex(where: { $0.deviceUID == deviceUID }) {
            idx = existing
        } else {
            mappings.append(DeviceMapping(deviceUID: deviceUID,
                                          deviceName: deviceUID,
                                          assignments: [:]))
            idx = mappings.count - 1
        }
        if let a = assignment {
            mappings[idx].assignments[busID] = a
        } else {
            mappings[idx].assignments.removeValue(forKey: busID)
        }
    }

    /// `BusAssignment` for `busID` on the given device, or nil if unmapped.
    func assignment(busID: UUID, deviceUID: String) -> BusAssignment? {
        mapping(for: deviceUID)?.assignments[busID]
    }

    // MARK: - Legacy migration helpers (per-cue OutputRouting decoder)

    /// Returns (creating if needed) the bus used to migrate the old
    /// `OutputRouting.monoLeft` enum value. The bus is auto-assigned as
    /// `.monoSum(channel: 1)` on every existing device the first time it's
    /// created, so playlists that used it keep playing where they did.
    func legacyMonoLeftBusID() -> UUID {
        return findOrCreateLegacyMonoBus(name: "Mono L", defaultChannel: 1)
    }

    /// Counterpart for `OutputRouting.monoRight` — channel 2.
    func legacyMonoRightBusID() -> UUID {
        return findOrCreateLegacyMonoBus(name: "Mono R", defaultChannel: 2)
    }

    private func findOrCreateLegacyMonoBus(name: String, defaultChannel: Int) -> UUID {
        if let existing = buses.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing.id
        }
        let bus = OutputBus(name: name)
        buses.append(bus)
        for i in mappings.indices where mappings[i].assignments[bus.id] == nil {
            mappings[i].assignments[bus.id] = .monoSum(channel: defaultChannel)
        }
        return bus.id
    }

    // MARK: - Display helpers

    /// "Outputs 1-2" / "Output 3 (mono)" / "Muted" / "Out of range" —
    /// shown as the trailing label in dropdowns. `deviceChannelCount`
    /// validates that the assignment still fits the device.
    /// A bus with no assignment is silent on this device, not falling
    /// back to a default — hence "Muted".
    func channelLabel(busID: UUID, deviceUID: String?, deviceChannelCount: Int) -> String {
        guard bus(id: busID) != nil else { return "—" }
        guard let uid = deviceUID,
              let asn = assignment(busID: busID, deviceUID: uid) else {
            return "Muted"
        }
        let last = asn.startChannel + asn.channelWidth - 1
        if last > deviceChannelCount { return "Out of range" }
        switch asn {
        case .stereo(let c):  return "Outputs \(c)-\(c + 1)"
        case .monoSum(let c): return "Output \(c) (mono)"
        }
    }
}
