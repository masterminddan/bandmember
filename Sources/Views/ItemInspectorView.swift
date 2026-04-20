import SwiftUI
import AppKit

struct ItemInspectorView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var playbackEngine: PlaybackEngine
    @ObservedObject private var tempo = TempoCoordinator.shared
    @AppStorage("snapMode") private var snapModeRaw: String = SnapMode.measure.rawValue

    private var snapMode: SnapMode {
        SnapMode(rawValue: snapModeRaw) ?? .measure
    }

    var body: some View {
        if store.selectedIDs.count > 1 {
            multiSelectInspector
        } else if let selectedID = store.selectedIDs.first,
                  let itemIndex = store.items.firstIndex(where: { $0.id == selectedID }) {
            inspectorContent(for: itemIndex, id: selectedID)
        } else {
            emptyState
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

                Spacer()
            }
            .padding()
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    Text("Inspector")
                        .font(.headline)
                    Spacer()
                    if store.playingItemIDs.contains(id) {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Playing").font(.caption).foregroundColor(.green)
                        }
                    }
                }

                Divider()

                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
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

                // File path (only for media items)
                if store.items[safe: index]?.isDivider == false {
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

                    // Waveform with start/end positions, modulated by volume
                    WaveformView(
                        filePath: store.items[safe: index]?.filePath ?? "",
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

                    // Type
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

                    // Target display (video only)
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
                }

                Divider()

                // Color tag
                ColorTagPicker(
                    value: store.items[safe: index]?.colorTag ?? .none,
                    onChange: { newTag in
                        guard index < store.items.count else { return }
                        store.pushUndo()
                        store.items[index].colorTag = newTag
                    }
                )

                // Auto-follow (not for dividers)
                if store.items[safe: index]?.isDivider == false {
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

                    // Volume controls
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

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 46, alignment: .trailing)
                .font(.callout)
            Slider(value: $value, in: 0...maxValue) { editing in
                if editing { onEditStart?() }
            }
            Text(String(format: "%.0f%%", value * 100))
                .frame(width: 44, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(value > 1.0 ? .orange : .secondary)
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

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
