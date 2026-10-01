import Foundation
import Combine

/// Shared, app-wide configuration of named output buses and per-device
/// channel assignments. Persisted in two places:
///
/// - **Buses** (names, IDs, which one is the default) go to
///   `config/output-buses.json` inside the source checkout the app was
///   built from. Playlists reference buses by ID, so this file has to
///   travel with the git repo for a playlist to open correctly on another
///   machine. It contains nothing hardware-specific.
/// - **Device mappings** stay in Application Support on each machine. They
///   are keyed by CoreAudio device UID, which embeds hardware serial
///   numbers and Bluetooth addresses, so they must never be written into
///   the (public) repo. The local file also keeps a copy of the buses and
///   is the sole store when the checkout isn't present (e.g. the .app was
///   copied to a machine without the source).
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

    /// Machine-local file: device mappings plus a copy of the buses.
    private let localURL: URL
    /// Git-tracked file: buses only. Nil when the checkout isn't present.
    private let sharedURL: URL?
    /// Set when the git-tracked file exists but couldn't be read (e.g. it
    /// has merge-conflict markers). We then leave it alone rather than
    /// overwrite it with this machine's local bus list.
    private var sharedFileUnreadable = false
    private var saveDebounce: AnyCancellable?

    /// Root of the source checkout this binary was compiled from, baked in
    /// at build time via `#filePath` (this file lives at
    /// `<repo>/Sources/Playback/OutputBusStore.swift`). Each machine builds
    /// from its own clone, so this resolves to that machine's clone.
    private static let buildRepoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Playback
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // repo root

    /// `~/Library/Application Support/BandMember/output-mappings.json`.
    private static func localConfigURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("BandMember", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("output-mappings.json")
    }

    /// `<repo>/config/output-buses.json`, or nil when the checkout this
    /// binary was built from doesn't exist on this machine.
    private static func sharedBusesURL() -> URL? {
        let fm = FileManager.default
        let root = buildRepoRoot
        // Sanity-check that the baked-in path is really the checkout.
        guard fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            debugLog("OutputBusStore: source checkout not found at \(root.path); buses are local-only")
            return nil
        }
        let dir = root.appendingPathComponent("config", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            debugLog("OutputBusStore: could not create \(dir.path) (\(error)); buses are local-only")
            return nil
        }
        return dir.appendingPathComponent("output-buses.json")
    }

    init() {
        self.localURL = Self.localConfigURL()
        self.sharedURL = Self.sharedBusesURL()
        debugLog("OutputBusStore: mappings at \(localURL.path), buses at \(sharedURL?.path ?? "(local only)")")

        loadLocal()
        loadShared()
        ensureDefaults()

        // One-time migration: a checkout with no bus file yet gets seeded
        // from the buses this machine already had in Application Support.
        if let url = sharedURL, !FileManager.default.fileExists(atPath: url.path) {
            saveShared()
            debugLog("OutputBusStore: seeded \(url.path) from local buses")
        }

        // Coalesce writes — bus/mapping edits often come in bursts. Save
        // 200 ms after the last change.
        saveDebounce = Publishers.CombineLatest($buses, $mappings)
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.save() }
    }

    // MARK: - Persistence

    /// Loads the machine-local file: device mappings, plus the buses as
    /// they were last seen here (replaced by `loadShared` when the
    /// git-tracked bus file is available).
    private func loadLocal() {
        guard let data = try? Data(contentsOf: localURL) else { return }
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
            return
        }
        debugLog("OutputBusStore: could not decode \(localURL.path); starting from defaults")
    }

    /// Replaces the bus list with the git-tracked one, when present. The
    /// repo is authoritative for buses so every machine resolves playlist
    /// bus IDs the same way.
    private func loadShared() {
        guard let url = sharedURL, let data = try? Data(contentsOf: url) else { return }
        guard let cfg = try? JSONDecoder().decode(SharedBusConfig.self, from: data),
              !cfg.buses.isEmpty else {
            sharedFileUnreadable = true
            debugLog("OutputBusStore: could not decode \(url.path); keeping local buses and leaving that file untouched")
            return
        }
        let localMainID = mainBusID
        let hadLocalMain = buses.contains { $0.id == localMainID }

        self.buses = cfg.buses
        if let id = cfg.mainBusID, cfg.buses.contains(where: { $0.id == id }) {
            self.mainBusID = id
        } else {
            self.mainBusID = cfg.buses[0].id
        }

        // This machine's default bus isn't in the shared list — it ran
        // with its own bus list before the shared file arrived. Carry
        // each device's default-bus assignment over to the shared default
        // so those devices keep playing instead of going silent.
        let sharedMainID = mainBusID
        if hadLocalMain, localMainID != sharedMainID,
           !cfg.buses.contains(where: { $0.id == localMainID }) {
            for i in mappings.indices where mappings[i].assignments[sharedMainID] == nil {
                if let asn = mappings[i].assignments[localMainID] {
                    mappings[i].assignments[sharedMainID] = asn
                }
            }
        }
    }

    private func save() {
        saveLocal()
        saveShared()
    }

    private func saveLocal() {
        write(OutputBusConfig(buses: buses, mappings: mappings, mainBusID: mainBusID),
              to: localURL)
    }

    private func saveShared() {
        guard let url = sharedURL, !sharedFileUnreadable else { return }
        write(SharedBusConfig(buses: buses, mainBusID: mainBusID), to: url)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        // Don't touch the file when nothing changed — the bus file is
        // tracked in git, and an idle launch should leave the tree clean.
        if let existing = try? Data(contentsOf: url), existing == data { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            debugLog("OutputBusStore: failed to save \(url.path): \(error)")
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
