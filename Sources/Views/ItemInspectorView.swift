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

                // Target display (applies to the selected video items)
                let videoCount = selectedVideoCount
                if videoCount > 0 {
                    Divider()

                    let commonDisplay = multiSelectTargetDisplay
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Display").font(.caption).foregroundColor(.secondary)
                        Picker("Display", selection: Binding(
                            get: { commonDisplay ?? mixedDisplayTag },
                            set: { newValue in
                                guard newValue != mixedDisplayTag else { return }
                                store.pushUndo()
                                for id in store.selectedIDs {
                                    if let idx = store.items.firstIndex(where: { $0.id == id }),
                                       store.items[idx].mediaType == .video {
                                        store.items[idx].targetDisplayIndex = newValue
                                    }
                                }
                            }
                        )) {
                            if commonDisplay == nil { Text("Mixed").tag(mixedDisplayTag) }
                            Text("Main Display").tag(0)
                            Text("2nd Display").tag(1)
                        }
                        .labelsHidden()
                        if videoCount < store.selectedIDs.count {
                            Text("Applies to the \(videoCount) selected video\(videoCount == 1 ? "" : "s")")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        if commonDisplay == 1 && NSScreen.screens.count < 2 {
                            Text("2nd display not connected — video will not play")
                                .font(.caption2).foregroundColor(.orange)
                        }
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

                // Limiter (applies to the selected audio items)
                if selectedAudioCount > 0 {
                    Divider()

                    let commonBoost = multiSelectLimiterBoost
                    LimiterControl(
                        isOn: Binding(
                            get: { multiSelectLimiterEnabled },
                            set: { newValue in
                                store.pushUndo()
                                applyToSelectedAudio { $0.limiterEnabled = newValue }
                            }
                        ),
                        boostDB: Binding(
                            get: { commonBoost ?? PlaylistItem.defaultLimiterBoostDB },
                            set: { newValue in
                                applyToSelectedAudio { $0.limiterBoostDB = newValue }
                            }
                        ),
                        onEditStart: { store.pushUndo() },
                        mixedLabel: commonBoost == nil ? "Mixed" : nil
                    )
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

    /// True if `busID` is configured as mono-sum on the currently active
    /// output device. Used to show the "L+R are summed" caption under the
    /// Output picker — the routing shape is per-device now, not per-bus.
    private func isMonoSumOnCurrentDevice(busID: UUID) -> Bool {
        guard let uid = audioOut.currentDevice?.uid,
              let asn = busStore.assignment(busID: busID, deviceUID: uid) else { return false }
        return asn.isMonoSum
    }

    /// Sentinel tag for the "Mixed" row of the multi-select display picker.
    private var mixedDisplayTag: Int { -1 }

    /// Number of selected items that are videos — the display picker only
    /// touches those (audio items set the same field from the Lyrics tab).
    private var selectedVideoCount: Int {
        store.selectedIDs.filter { id in
            store.items.first { $0.id == id }?.mediaType == .video
        }.count
    }

    /// Returns the common target display if all selected videos share one, otherwise nil.
    private var multiSelectTargetDisplay: Int? {
        let indices = Set(store.selectedIDs.compactMap { id -> Int? in
            guard let item = store.items.first(where: { $0.id == id }),
                  item.mediaType == .video else { return nil }
            return item.targetDisplayIndex
        })
        return indices.count == 1 ? indices.first : nil
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

    /// Number of selected items that are audio — the limiter only exists on
    /// those (video plays through AVPlayer, outside the audio engine).
    private var selectedAudioCount: Int {
        store.selectedIDs.filter { id in
            store.items.first { $0.id == id }?.mediaType == .audio
        }.count
    }

    /// Returns true if ALL selected audio items have the limiter on
    private var multiSelectLimiterEnabled: Bool {
        store.selectedIDs.allSatisfy { id in
            guard let item = store.items.first(where: { $0.id == id }),
                  item.mediaType == .audio else { return true }
            return item.limiterEnabled
        }
    }

    /// Returns the common limiter boost if all selected audio items share one, otherwise nil.
    private var multiSelectLimiterBoost: Float? {
        let vals = Set(store.selectedIDs.compactMap { id -> Float? in
            guard let item = store.items.first(where: { $0.id == id }),
                  item.mediaType == .audio else { return nil }
            return item.limiterBoostDB
        })
        return vals.count == 1 ? vals.first : nil
    }

    private func applyToSelectedAudio(_ mutate: (inout PlaylistItem) -> Void) {
        applyToSelection { item in
            if item.mediaType == .audio { mutate(&item) }
        }
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
            } else if store.items[safe: index]?.isGroup == true {
                groupBody(for: index, id: id)
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

    /// Boost for the waveform's limiter preview, or nil when the item's
    /// limiter is off (or it's a video, which has no limiter).
    private func limiterPreviewBoost(for index: Int) -> Float? {
        guard let item = store.items[safe: index],
              item.mediaType == .audio, item.limiterEnabled else { return nil }
        return item.limiterBoostDB
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

    /// Inspector for a group header: its name and color, and the start /
    /// loop points used when the group is triggered from the header. The
    /// header has no audio of its own, so those are set on the waveform of
    /// one of the group's tracks.
    @ViewBuilder
    private func groupBody(for index: Int, id: UUID) -> some View {
        let members = index < store.items.count
            ? Array(store.items[store.memberRange(ofGroupAt: index)]) : []
        let reference = members.first { $0.mediaType == .audio && $0.fileExists }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nameField(for: index)

                Text(members.count == 1 ? "1 track plays together" : "\(members.count) tracks play together")
                    .font(.caption).foregroundColor(.secondary)

                if let reference = reference {
                    WaveformView(
                        filePath: reference.filePath,
                        itemID: reference.id,
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
                        masterVolume: reference.masterVolume,
                        leftVolume: reference.leftVolume,
                        rightVolume: reference.rightVolume,
                        limiterBoostDB: reference.limiterEnabled ? reference.limiterBoostDB : nil,
                        beats: tempoBeats(for: id),
                        snapMode: snapMode
                    )
                    Text("Showing \(reference.name). The start and loop points set here apply to the whole group when it is played from this row.")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    tempoLabel(for: id)
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

                Button("Ungroup") {
                    store.selectedIDs = [id]
                    store.ungroupSelected()
                }
                .help("Remove the group and keep its tracks (⇧⌘G)")

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
                        guard MediaFileTypes.isSupported(url) else { return }
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
                    limiterBoostDB: limiterPreviewBoost(for: index),
                    beats: tempoBeats(for: id),
                    snapMode: snapMode
                )

                tempoLabel(for: id)

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

                // Limiter (audio only — video plays through AVPlayer)
                if store.items[safe: index]?.mediaType == .audio {
                    Divider()

                    LimiterControl(
                        isOn: Binding(
                            get: { store.items[safe: index]?.limiterEnabled ?? false },
                            set: { newValue in
                                guard index < store.items.count else { return }
                                store.pushUndo()
                                store.items[index].limiterEnabled = newValue
                                playbackEngine.updateVolume(for: store.items[index])
                            }
                        ),
                        boostDB: Binding(
                            get: { store.items[safe: index]?.limiterBoostDB
                                    ?? PlaylistItem.defaultLimiterBoostDB },
                            set: { newValue in
                                guard index < store.items.count else { return }
                                store.items[index].limiterBoostDB = newValue
                                playbackEngine.updateVolume(for: store.items[index])
                            }
                        ),
                        onEditStart: { store.pushUndo() }
                    )
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
    var maxValue: Float = 4.0
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

// MARK: - Limiter Control

/// Per-cue limiter: an on/off switch plus how far to push the cue into it.
struct LimiterControl: View {
    @Binding var isOn: Bool
    @Binding var boostDB: Float
    var onEditStart: (() -> Void)? = nil
    /// When non-nil, replaces the right-hand dB label — used in multi-select
    /// to mean "selected items have different values; touching this will set
    /// them all".
    var mixedLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Limiter").font(.headline)
                Spacer()
                Toggle("Limiter", isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                Text("Boost")
                    .frame(width: 46, alignment: .trailing)
                    .font(.callout)
                Slider(value: $boostDB, in: PlaylistItem.limiterBoostRangeDB) { editing in
                    if editing { onEditStart?() }
                }
                .opacity(mixedLabel != nil ? 0.5 : 1.0)
                if let mixed = mixedLabel {
                    Text(mixed)
                        .frame(width: 50, alignment: .trailing)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                        .italic()
                } else {
                    Text(String(format: "+%.0f dB", boostDB))
                        .frame(width: 50, alignment: .trailing)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .disabled(!isOn)
            Text("Turns the quiet parts up by this much and holds the loud parts at their original level.")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            .contextMenu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: filePath)])
                }
                .disabled(filePath.isEmpty
                          || !FileManager.default.fileExists(atPath: filePath))
            }
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
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { valid(s) != nil ? (onTargetChanged?(true), .copy).1 : [] }
    override func draggingExited(_ s: NSDraggingInfo?) { onTargetChanged?(false) }
    override func draggingEnded(_ s: NSDraggingInfo) { onTargetChanged?(false) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { onTargetChanged?(false); guard let u = valid(s) else { return false }; onDrop?(u); return true }
    private func valid(_ i: NSDraggingInfo) -> URL? {
        guard let urls = i.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first else { return nil }
        return MediaFileTypes.isSupported(u) ? u : nil
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
