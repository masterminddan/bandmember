import SwiftUI
import AppKit

struct ItemInspectorView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var playbackEngine: PlaybackEngine
    @ObservedObject private var tempo = TempoCoordinator.shared
    @ObservedObject private var busStore = OutputBusStore.shared
    @ObservedObject private var audioOut = AudioOutputManager.shared
    @State private var showMappingEditor = false
    @AppStorage("snapMode") private var snapModeRaw: String = SnapMode.measure.rawValue
    @AppStorage("inspectorTab") private var inspectorTabRaw: String = "track"

    private var snapMode: SnapMode {
        SnapMode(rawValue: snapModeRaw) ?? .measure
    }

    private enum InspectorTab: String, CaseIterable { case track, lyrics
        var label: String { rawValue.capitalized }
    }
    private var inspectorTab: InspectorTab {
        get { InspectorTab(rawValue: inspectorTabRaw) ?? .track }
    }

    var body: some View {
        Group {
            if store.selectedIDs.count > 1 {
                multiSelectInspector
            } else if let selectedID = store.selectedIDs.first,
                      let itemIndex = store.items.firstIndex(where: { $0.id == selectedID }) {
                inspectorContent(for: itemIndex, id: selectedID)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showMappingEditor) {
            OutputMappingEditor()
                .frame(minWidth: 620, minHeight: 420)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sidebar.right")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Select an item to inspect")
                .foregroundColor(.secondary)
            Text("Press Space to play selected item")
                .foregroundStyle(.tertiary)
                .font(.caption)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Multi-Select Inspector

    private var multiSelectInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(store.selectedIDs.count) items selected")
                    .font(.headline)

                Divider()

                // Color tag (applies to all selected)
                ColorTagPicker(
                    value: multiSelectColorTag,
                    onChange: { newTag in
                        store.pushUndo()
                        for id in store.selectedIDs {
                            if let idx = store.items.firstIndex(where: { $0.id == id }) {
                                store.items[idx].colorTag = newTag
                            }
                        }
                    }
                )

                Divider()

                // Auto-follow (applies to all selected)
                Toggle(isOn: Binding(
                    get: { multiSelectAutoFollow },
                    set: { newValue in
                        store.pushUndo()
                        for id in store.selectedIDs {
                            if let idx = store.items.firstIndex(where: { $0.id == id }) {
                                store.items[idx].autoFollow = newValue
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text("Also play next")
                        Text("Simultaneously triggers the next item")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Output bus (applies to all selected)
                let commonBusID = multiSelectBusID
                VStack(alignment: .leading, spacing: 6) {
                    Text("Output").font(.headline)
                    GlobalOutputDevicePicker()
                    BusPicker(
                        currentBusID: commonBusID,
                        onSelect: { newBusID in
                            store.pushUndo()
                            applyToSelection { $0.outputRouting = OutputRouting(busID: newBusID) }
                        },
                        onEdit: { showMappingEditor = true },
                        mixedLabel: commonBusID == nil ? "Mixed" : nil
                    )
                    if let id = commonBusID, isMonoSumOnCurrentDevice(busID: id) {
                        Text("L+R are summed (-3 dB) and sent to a single channel on this device.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                Divider()

                // Volume (applies to all selected)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Volume").font(.headline)
                    multiVolumeSlider(label: "Master", keyPath: \.masterVolume)
                    multiVolumeSlider(label: "Left",   keyPath: \.leftVolume)
                    multiVolumeSlider(label: "Right",  keyPath: \.rightVolume)
                }

                Spacer()
            }
            .padding()
        }
    }

    /// Builds a VolumeSlider that reads the common value across the selection
    /// (or shows "Mixed"), and on edit applies the new value to every selected item.
    @ViewBuilder
    private func multiVolumeSlider(
        label: String,
        keyPath: WritableKeyPath<PlaylistItem, Float>
    ) -> some View {
        let common = multiSelectVolume(keyPath)
        VolumeSlider(
            label: label,
            value: Binding(
                get: { common ?? 1.0 },
                set: { newVal in
                    applyToSelection { $0[keyPath: keyPath] = newVal }
                }
            ),
            onEditStart: { store.pushUndo() },
            mixedLabel: common == nil ? "Mixed" : nil
        )
    }

    /// Returns the common color tag if all selected items share one, otherwise .none
    private var multiSelectColorTag: ColorTag {
        let tags = Set(store.selectedIDs.compactMap { id in
            store.items.first { $0.id == id }?.colorTag
        })
        return tags.count == 1 ? tags.first! : .none
    }

    /// Returns true if ALL selected items have autoFollow
    private var multiSelectAutoFollow: Bool {
        store.selectedIDs.allSatisfy { id in
            store.items.first { $0.id == id }?.autoFollow ?? false
        }
    }

    /// True if `busID` is configured as mono-sum on the currently active
    /// output device. Used to show the "L+R are summed" caption under the
    /// Output picker — the routing shape is per-device now, not per-bus.
    private func isMonoSumOnCurrentDevice(busID: UUID) -> Bool {
        guard let uid = audioOut.currentDevice?.uid,
              let asn = busStore.assignment(busID: busID, deviceUID: uid) else { return false }
        return asn.isMonoSum
    }

    /// Returns the common output bus ID if all selected items share one, otherwise nil.
    private var multiSelectBusID: UUID? {
        let ids = Set(store.selectedIDs.compactMap { id in
            store.items.first { $0.id == id }?.outputRouting.busID
        })
        return ids.count == 1 ? ids.first : nil
    }

    private func multiSelectVolume(_ keyPath: KeyPath<PlaylistItem, Float>) -> Float? {
        let vals = Set(store.selectedIDs.compactMap { id in
            store.items.first { $0.id == id }?[keyPath: keyPath]
        })
        return vals.count == 1 ? vals.first : nil
    }

    private func applyToSelection(_ mutate: (inout PlaylistItem) -> Void) {
        for id in store.selectedIDs {
            if let idx = store.items.firstIndex(where: { $0.id == id }) {
                mutate(&store.items[idx])
                playbackEngine.updateVolume(for: store.items[idx])
            }
        }
    }

    // MARK: - Tempo

    private func tempoBeats(for itemID: UUID) -> [Double] {
        tempo.tempoData(forItemID: itemID, store: store)?.beats ?? []
    }

    private var snapModeButton: some View {
        Button(action: { snapModeRaw = snapMode.next().rawValue }) {
            Text(snapMode.label)
                .font(.caption2)
                .foregroundColor(snapMode == .off ? .secondary : .accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill((snapMode == .off ? Color.secondary : Color.accentColor).opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help("Click to cycle: measure → beat → off")
    }

    @ViewBuilder
    private func tempoLabel(for itemID: UUID) -> some View {
        let sourcePath = store.tempoSourcePath(forItemID: itemID)
        HStack(spacing: 6) {
            Image(systemName: "metronome")
                .font(.caption)
                .foregroundColor(.secondary)

            if let path = sourcePath, let data = tempo.cache[path] {
                Text(String(format: "%.1f BPM", data.bpm))
                    .font(.system(.callout, design: .monospaced).bold())
                    .foregroundColor(.primary)
                Spacer()
                snapModeButton
            } else if let path = sourcePath, tempo.analyzing.contains(path) {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                Text("Analyzing tempo…").font(.caption).foregroundColor(.secondary)
                Spacer()
            } else if sourcePath == nil {
                Text("No tempo source in chain")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            } else {
                Text("No beats detected")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Single Item Inspector

    private func inspectorContent(for index: Int, id: UUID) -> some View {
        Group {
            if store.items[safe: index]?.isDivider == true {
                dividerBody(for: index)
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: Binding(
                        get: { inspectorTab },
                        set: { inspectorTabRaw = $0.rawValue }
                    )) {
                        ForEach(InspectorTab.allCases, id: \.self) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    switch inspectorTab {
                    case .track:
                        trackTabBody(for: index, id: id)
                    case .lyrics:
                        LyricsTabView(itemIndex: index, itemID: id)
                    }
                }
            }
        }
    }

    private func nameField(for index: Int) -> some View {
        TextField("Name", text: Binding(
            get: { store.items[safe: index]?.name ?? "" },
            set: { newValue in
                guard index < store.items.count else { return }
                store.items[index].name = newValue
            }
        ), onEditingChanged: { began in
            if began { store.pushUndo() }
        })
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func dividerBody(for index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nameField(for: index)
                ColorTagPicker(
                    value: store.items[safe: index]?.colorTag ?? .none,
                    onChange: { newTag in
                        guard index < store.items.count else { return }
                        store.pushUndo()
                        store.items[index].colorTag = newTag
                    }
                )
                Spacer()
            }
            .padding()
        }
    }

    private func trackTabBody(for index: Int, id: UUID) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nameField(for: index)

                FileDropField(
                    filePath: store.items[safe: index]?.filePath ?? "",
                    onDrop: { url in
                        guard index < store.items.count else { return }
                        let ext = url.pathExtension.lowercased()
                        let allowed: Set<String> = ["mp3", "aif", "aiff", "mp4", "mov"]
                        guard allowed.contains(ext) else { return }
                        store.pushUndo()
                        store.items[index].filePath = url.path
                        store.items[index].name = url.deletingPathExtension().lastPathComponent
                        store.items[index].mediaType = MediaType.detect(from: url)
                    }
                )

                WaveformView(
                    filePath: store.items[safe: index]?.filePath ?? "",
                    itemID: id,
                    startPosition: Binding(
                        get: { store.items[safe: index]?.startPosition ?? 0 },
                        set: { newValue in
                            guard index < store.items.count else { return }
                            store.items[index].startPosition = newValue
                        }
                    ),
                    endPosition: Binding(
                        get: { store.items[safe: index]?.endPosition },
                        set: { newValue in
                            guard index < store.items.count else { return }
                            store.items[index].endPosition = newValue
                        }
                    ),
                    masterVolume: store.items[safe: index]?.masterVolume ?? 1.0,
                    leftVolume: store.items[safe: index]?.leftVolume ?? 1.0,
                    rightVolume: store.items[safe: index]?.rightVolume ?? 1.0,
                    beats: tempoBeats(for: id),
                    snapMode: snapMode
                )

                tempoLabel(for: id)

                HStack {
                    Text("Type").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if let item = store.items[safe: index] {
                        HStack(spacing: 4) {
                            Image(systemName: item.mediaType.icon)
                            Text(item.mediaType.rawValue.capitalized)
                        }
                        .font(.callout)
                    }
                }

                // Target display (video only — audio uses this field via Lyrics tab)
                if store.items[safe: index]?.mediaType == .video {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Display").font(.caption).foregroundColor(.secondary)
                        Picker("Display", selection: Binding(
                            get: { store.items[safe: index]?.targetDisplayIndex ?? 0 },
                            set: { newValue in
                                guard index < store.items.count else { return }
                                store.pushUndo()
                                store.items[index].targetDisplayIndex = newValue
                            }
                        )) {
                            Text("Main Display").tag(0)
                            Text("2nd Display").tag(1)
                        }
                        .labelsHidden()
                        if store.items[safe: index]?.targetDisplayIndex == 1 && NSScreen.screens.count < 2 {
                            Text("2nd display not connected — video will not play")
                                .font(.caption2).foregroundColor(.orange)
                        }
                    }
                }

                Divider()

                ColorTagPicker(
                    value: store.items[safe: index]?.colorTag ?? .none,
                    onChange: { newTag in
                        guard index < store.items.count else { return }
                        store.pushUndo()
                        store.items[index].colorTag = newTag
                    }
                )

                Divider()

                Toggle(isOn: Binding(
                    get: { store.items[safe: index]?.autoFollow ?? false },
                    set: { newValue in
                        guard index < store.items.count else { return }
                        store.pushUndo()
                        store.items[index].autoFollow = newValue
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text("Also play next")
                        Text("Simultaneously triggers the next item when this one is played")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Output").font(.headline)
                    GlobalOutputDevicePicker()
                    let currentBusID = store.items[safe: index]?.outputRouting.busID
                    BusPicker(
                        currentBusID: currentBusID,
                        onSelect: { newBusID in
                            guard index < store.items.count else { return }
                            store.pushUndo()
                            store.items[index].outputRouting = OutputRouting(busID: newBusID)
                            playbackEngine.updateVolume(for: store.items[index])
                        },
                        onEdit: { showMappingEditor = true }
                    )
                    if let id = currentBusID, isMonoSumOnCurrentDevice(busID: id) {
                        Text("L+R are summed (-3 dB) and sent to a single channel on this device. Use this when one interface output feeds IEMs and the other feeds FOH.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Volume").font(.headline)
                    VolumeSlider(label: "Master", value: Binding(
                        get: { store.items[safe: index]?.masterVolume ?? 1.0 },
                        set: { newValue in
                            guard index < store.items.count else { return }
                            store.items[index].masterVolume = newValue
                            playbackEngine.updateVolume(for: store.items[index])
                        }
                    ), onEditStart: { store.pushUndo() })
                    VolumeSlider(label: "Left", value: Binding(
                        get: { store.items[safe: index]?.leftVolume ?? 1.0 },
                        set: { newValue in
                            guard index < store.items.count else { return }
                            store.items[index].leftVolume = newValue
                            playbackEngine.updateVolume(for: store.items[index])
                        }
                    ), onEditStart: { store.pushUndo() })
                    VolumeSlider(label: "Right", value: Binding(
                        get: { store.items[safe: index]?.rightVolume ?? 1.0 },
                        set: { newValue in
                            guard index < store.items.count else { return }
                            store.items[index].rightVolume = newValue
                            playbackEngine.updateVolume(for: store.items[index])
                        }
                    ), onEditStart: { store.pushUndo() })
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Color Tag Picker

struct ColorTagPicker: View {
    let value: ColorTag
    let onChange: (ColorTag) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.caption).foregroundColor(.secondary)
            HStack(spacing: 6) {
                ForEach(ColorTag.allCases, id: \.self) { tag in
                    if tag == .none {
                        Button(action: { onChange(tag) }) {
                            ZStack {
                                Circle()
                                    .fill(Color.secondary.opacity(0.08))
                                    .frame(width: 20, height: 20)
                                Circle()
                                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                                    .frame(width: 20, height: 20)
                                if value == .none {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("No color")
                    } else {
                        Button(action: { onChange(tag) }) {
                            ZStack {
                                Circle()
                                    .fill(swiftUIColor(for: tag))
                                    .frame(width: 20, height: 20)
                                if value == tag {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(tag.displayName)
                    }
                }
            }
        }
    }

    private func swiftUIColor(for tag: ColorTag) -> Color {
        switch tag {
        case .none:   return .clear
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        }
    }
}

// MARK: - Volume Slider

struct VolumeSlider: View {
    let label: String
    @Binding var value: Float
    var maxValue: Float = 2.0
    var onEditStart: (() -> Void)? = nil
    /// When non-nil, replaces the right-hand percentage label and renders
    /// the slider in a "neutral" appearance — used in multi-select to mean
    /// "selected items have different values; touching this will set them all".
    var mixedLabel: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 46, alignment: .trailing)
                .font(.callout)
            Slider(value: $value, in: 0...maxValue) { editing in
                if editing { onEditStart?() }
            }
            .opacity(mixedLabel != nil ? 0.5 : 1.0)
            if let mixed = mixedLabel {
                Text(mixed)
                    .frame(width: 44, alignment: .trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .italic()
            } else {
                Text(String(format: "%.0f%%", value * 100))
                    .frame(width: 44, alignment: .trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(value > 1.0 ? .orange : .secondary)
            }
        }
    }
}

// MARK: - File Drop Field

struct FileDropField: View {
    let filePath: String
    let onDrop: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("File").font(.caption).foregroundColor(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                          style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                Text(filePath.isEmpty ? "Drop a file here" : filePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { FileDropReceiver(isTargeted: $isTargeted, onDrop: onDrop) }
        }
    }
}

struct FileDropReceiver: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: (URL) -> Void
    func makeNSView(context: Context) -> FileDropNSView {
        let v = FileDropNSView()
        v.onDrop = onDrop
        v.onTargetChanged = { t in DispatchQueue.main.async { isTargeted = t } }
        v.registerForDraggedTypes([.fileURL])
        return v
    }
    func updateNSView(_ v: FileDropNSView, context: Context) { v.onDrop = onDrop }
}

class FileDropNSView: NSView {
    var onDrop: ((URL) -> Void)?
    var onTargetChanged: ((Bool) -> Void)?
    private static let exts: Set<String> = ["mp3","aif","aiff","mp4","mov"]
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { valid(s) != nil ? (onTargetChanged?(true), .copy).1 : [] }
    override func draggingExited(_ s: NSDraggingInfo?) { onTargetChanged?(false) }
    override func draggingEnded(_ s: NSDraggingInfo) { onTargetChanged?(false) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { onTargetChanged?(false); guard let u = valid(s) else { return false }; onDrop?(u); return true }
    private func valid(_ i: NSDraggingInfo) -> URL? {
        guard let urls = i.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first else { return nil }
        return Self.exts.contains(u.pathExtension.lowercased()) ? u : nil
    }
}

// MARK: - Device Picker

/// Compact dropdown for the global output device. Mirrors the Audio menu's
/// device picker so the user can switch rigs from the Inspector without
/// leaving the track tab. Selection is global, not per-cue — every cue
/// follows whichever device this picks.
struct GlobalOutputDevicePicker: View {
    @ObservedObject private var audioOut = AudioOutputManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Device").font(.caption).foregroundColor(.secondary)
            Menu {
                Button(action: { audioOut.currentUID = nil }) {
                    if audioOut.currentUID == nil {
                        Label("System Default", systemImage: "checkmark")
                    } else {
                        Text("System Default")
                    }
                }
                Divider()
                let resolvedUID = audioOut.currentDevice?.uid
                ForEach(audioOut.devices) { dev in
                    Button(action: { audioOut.currentUID = dev.uid }) {
                        let label = "\(dev.name) — \(dev.channelCount) ch"
                        if dev.uid == resolvedUID {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(closedLabel)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.1))
                )
            }
            .menuStyle(.borderlessButton)
        }
    }

    /// Closed-state label is always the *resolved* device name plus a
    /// "(default)" suffix when the user is on System Default — helpful
    /// when configuring a rig you'll plug in later.
    private var closedLabel: String {
        if let dev = audioOut.currentDevice {
            let suffix = audioOut.currentUID == nil ? " (default)" : ""
            return "\(dev.name) — \(dev.channelCount) ch\(suffix)"
        }
        return audioOut.currentUID == nil ? "System Default" : "—"
    }
}

// MARK: - Bus Picker

/// Per-cue output routing dropdown. Shows each named bus alongside the
/// physical channel(s) it occupies on the currently selected device, plus
/// a small gear button that opens the mapping editor sheet directly.
struct BusPicker: View {
    /// The bus the cue (or selection) currently routes to. Pass nil to render
    /// the closed dropdown in a "Mixed" state for multi-select.
    var currentBusID: UUID?
    /// Called when the user picks a bus from the menu.
    var onSelect: (UUID) -> Void
    /// Called when the user clicks the gear button or the menu's "Edit
    /// Mappings…" item.
    var onEdit: () -> Void
    /// When non-nil, replaces the closed-state label and renders it in
    /// secondary/italic style — used by the multi-select inspector.
    var mixedLabel: String? = nil

    @ObservedObject private var busStore = OutputBusStore.shared
    @ObservedObject private var audioOut = AudioOutputManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(busStore.buses) { bus in
                    Button(action: { onSelect(bus.id) }) {
                        let label = "\(bus.name) — \(channelLabel(for: bus.id))"
                        if currentBusID == bus.id {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
                Divider()
                Button("Edit Mappings…") { onEdit() }
            } label: {
                HStack {
                    closedLabelView
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.1))
                )
            }
            .menuStyle(.borderlessButton)

            Button(action: onEdit) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Edit output mappings")
        }
    }

    @ViewBuilder
    private var closedLabelView: some View {
        if let mixed = mixedLabel {
            Text(mixed).foregroundColor(.secondary).italic()
        } else if let id = currentBusID, let bus = busStore.bus(id: id) {
            let chan = channelLabel(for: id)
            let warn = chan == "Muted" || chan == "Out of range"
            Text("\(bus.name) — \(chan)")
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(warn ? .orange : .primary)
        } else {
            Text("Unknown bus").foregroundColor(.orange).italic()
        }
    }

    private func channelLabel(for busID: UUID) -> String {
        busStore.channelLabel(
            busID: busID,
            deviceUID: audioOut.currentDevice?.uid,
            deviceChannelCount: audioOut.currentChannelCount
        )
    }
}

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
