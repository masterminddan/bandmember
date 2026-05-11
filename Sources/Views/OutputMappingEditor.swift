import SwiftUI

/// Two-pane editor for the global named-bus list (left) and the
/// per-device channel assignments (right). Opened from the per-cue picker's
/// gear button or the Audio > Edit Output Mappings… menu.
struct OutputMappingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var busStore = OutputBusStore.shared
    @ObservedObject private var audioOut = AudioOutputManager.shared

    /// Bus selected in the left pane. Drives the rename / mono-sum controls.
    @State private var selectedBusID: UUID? = nil
    /// Device whose assignments are shown in the right pane. Defaults to
    /// the currently active device, but the user can switch to configure
    /// other devices ahead of time.
    @State private var editingDeviceUID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                busListPane
                Divider()
                assignmentsPane
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onAppear {
            if selectedBusID == nil {
                selectedBusID = busStore.buses.first?.id
            }
            if editingDeviceUID == nil {
                editingDeviceUID = audioOut.currentDevice?.uid
                    ?? busStore.mappings.first?.deviceUID
            }
        }
    }

    // MARK: - Left pane (buses)

    private var busListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Buses")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            List(selection: $selectedBusID) {
                ForEach(busStore.buses) { bus in
                    HStack {
                        Text(bus.name)
                        if bus.id == busStore.mainBusID {
                            Text("• default")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tag(Optional(bus.id))
                }
            }
            .listStyle(.bordered)
            .frame(minWidth: 200)

            HStack(spacing: 4) {
                Button(action: addBus) { Image(systemName: "plus") }
                    .help("New bus")
                Button(action: deleteSelectedBus) { Image(systemName: "minus") }
                    .disabled(selectedBusID == nil
                              || selectedBusID == busStore.mainBusID)
                    .help("Delete bus")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Per-bus details (rename + caption). Pinned to a constant
            // height so the list above doesn't reflow when switching
            // between default and non-default buses (the default bus
            // shows an extra caption line, which would otherwise eat
            // space from the list).
            Group {
                if let id = selectedBusID, let bus = busStore.bus(id: id) {
                    busDetail(bus)
                } else {
                    Text("Select a bus to edit")
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(height: 130, alignment: .top)
        }
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private func busDetail(_ bus: OutputBus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundColor(.secondary)
                TextField("Bus name", text: Binding(
                    get: { bus.name },
                    set: { busStore.renameBus(id: bus.id, to: $0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            if bus.id == busStore.mainBusID {
                Text("This is the default bus — always present and used as the fallback when a cue's bus is missing or unmapped on the active device.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Right pane (per-device assignments)

    private var assignmentsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Device").font(.headline)
                Spacer()
                devicePicker
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if let uid = editingDeviceUID,
               let dev = device(forUID: uid) {
                assignmentTable(deviceUID: uid, channelCount: dev.channelCount)
            } else if let uid = editingDeviceUID,
                      let mapping = busStore.mapping(for: uid) {
                // Saved mapping for a device that isn't currently connected.
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(mapping.deviceName) — not connected")
                        .foregroundColor(.orange)
                    Text("Reconnect to edit channel assignments. Cues routed through this device will fall back to the current device's Main bus until it returns.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                Spacer()
            } else {
                Text("No device selected").foregroundColor(.secondary).padding(12)
                Spacer()
            }
        }
        .frame(minWidth: 360)
    }

    private var devicePicker: some View {
        Menu {
            ForEach(audioOut.devices) { dev in
                Button(action: { editingDeviceUID = dev.uid }) {
                    if editingDeviceUID == dev.uid {
                        Label("\(dev.name) — \(dev.channelCount) ch", systemImage: "checkmark")
                    } else {
                        Text("\(dev.name) — \(dev.channelCount) ch")
                    }
                }
            }
            // Saved-but-disconnected devices, so the user can clean up
            // assignments for rigs they're not currently plugged into.
            let savedOnly = busStore.mappings.filter { m in
                !audioOut.devices.contains { $0.uid == m.deviceUID }
            }
            if !savedOnly.isEmpty {
                Divider()
                ForEach(savedOnly, id: \.deviceUID) { m in
                    Button(action: { editingDeviceUID = m.deviceUID }) {
                        if editingDeviceUID == m.deviceUID {
                            Label("\(m.deviceName) (saved)", systemImage: "checkmark")
                        } else {
                            Text("\(m.deviceName) (saved)").foregroundColor(.secondary)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(currentDeviceLabel)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 260)
    }

    private var currentDeviceLabel: String {
        guard let uid = editingDeviceUID else { return "—" }
        if let dev = device(forUID: uid) { return "\(dev.name) — \(dev.channelCount) ch" }
        if let m = busStore.mapping(for: uid) { return "\(m.deviceName) (saved)" }
        return "—"
    }

    private func device(forUID uid: String) -> AudioOutputDevice? {
        audioOut.devices.first { $0.uid == uid }
    }

    @ViewBuilder
    private func assignmentTable(deviceUID: String, channelCount: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(busStore.buses) { bus in
                    assignmentRow(bus: bus,
                                  deviceUID: deviceUID,
                                  channelCount: channelCount)
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func assignmentRow(bus: OutputBus,
                               deviceUID: String,
                               channelCount: Int) -> some View {
        let current = busStore.assignment(busID: bus.id, deviceUID: deviceUID)
        HStack {
            Text(bus.name)
                .frame(width: 130, alignment: .leading)

            Menu {
                Button(action: {
                    busStore.setAssignment(busID: bus.id, deviceUID: deviceUID, assignment: nil)
                }) {
                    if current == nil {
                        Label("Muted (no output)", systemImage: "checkmark")
                    } else {
                        Text("Muted (no output)")
                    }
                }
                if channelCount >= 2 {
                    Divider()
                    Section {
                        ForEach(stereoOptions(channelCount: channelCount), id: \.self) { start in
                            Button(action: {
                                busStore.setAssignment(busID: bus.id, deviceUID: deviceUID,
                                                       assignment: .stereo(startChannel: start))
                            }) {
                                let label = "Outputs \(start)-\(start + 1) (stereo)"
                                if case .stereo(let c) = current, c == start {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                }
                if channelCount >= 1 {
                    Divider()
                    Section {
                        ForEach(1...channelCount, id: \.self) { ch in
                            Button(action: {
                                busStore.setAssignment(busID: bus.id, deviceUID: deviceUID,
                                                       assignment: .monoSum(channel: ch))
                            }) {
                                let label = "Output \(ch) (mono-sum)"
                                if case .monoSum(let c) = current, c == ch {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(displayLabel(for: current, channelCount: channelCount))
                        .foregroundColor(rowLabelColor(current: current, channelCount: channelCount))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)

            if let conflict = conflictingBusName(for: bus, deviceUID: deviceUID, current: current) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("Channel(s) also used by \(conflict). Audio from both buses will sum.")
            }
        }
        .padding(.vertical, 6)
    }

    private func stereoOptions(channelCount: Int) -> [Int] {
        let last = channelCount - 1
        guard last >= 1 else { return [] }
        return Array(1...last)
    }

    private func displayLabel(for current: BusAssignment?, channelCount: Int) -> String {
        guard let asn = current else { return "Muted (no output)" }
        let last = asn.startChannel + asn.channelWidth - 1
        if last > channelCount { return "Out of range (\(asn.startChannel))" }
        switch asn {
        case .stereo(let c):  return "Outputs \(c)-\(c + 1) (stereo)"
        case .monoSum(let c): return "Output \(c) (mono-sum)"
        }
    }

    private func rowLabelColor(current: BusAssignment?, channelCount: Int) -> Color {
        guard let asn = current else { return .secondary }
        let last = asn.startChannel + asn.channelWidth - 1
        return last > channelCount ? .orange : .primary
    }

    /// Returns the name of another bus that shares any channel with `bus`
    /// on the given device AND has the same shape (both stereo or both
    /// mono-sum). Same-shape overlap is almost always a mistake (two
    /// stereo FOH buses on 1-2; two click sends on the same mono out).
    /// Mixed-shape overlap — e.g. a stereo Main on 1-2 sitting alongside
    /// mono-sum buses on 1 and 2 for per-output sends — is a normal live
    /// pattern and not flagged.
    private func conflictingBusName(for bus: OutputBus, deviceUID: String, current: BusAssignment?) -> String? {
        guard let asn = current else { return nil }
        let mine = Set(asn.startChannel..<(asn.startChannel + asn.channelWidth))
        guard let mapping = busStore.mapping(for: deviceUID) else { return nil }
        for (otherID, other) in mapping.assignments where otherID != bus.id {
            guard other.isMonoSum == asn.isMonoSum else { continue }
            let theirs = Set(other.startChannel..<(other.startChannel + other.channelWidth))
            if !mine.isDisjoint(with: theirs) {
                return busStore.bus(id: otherID)?.name ?? "another bus"
            }
        }
        return nil
    }

    // MARK: - Actions

    private func addBus() {
        let bus = busStore.addBus(name: "New Bus")
        selectedBusID = bus.id
    }


    private func deleteSelectedBus() {
        guard let id = selectedBusID, id != busStore.mainBusID else { return }
        busStore.deleteBus(id: id)
        selectedBusID = busStore.buses.first?.id
    }
}
