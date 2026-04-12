import SwiftUI
import UniformTypeIdentifiers

private let allowedExtensions: Set<String> = ["mp3", "aif", "aiff", "mp4", "mov"]

struct PlaylistTableView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var playbackEngine: PlaybackEngine

    var body: some View {
        List(selection: $store.selectedIDs) {
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                PlaylistRowView(
                    item: item,
                    index: index,
                    isPlaying: store.playingItemIDs.contains(item.id)
                )
                .tag(item.id)
                .listRowBackground(rowBackground(for: item))
                .contextMenu {
                    if !item.isDivider {
                        Button("Play") { playbackEngine.play(item: item) }
                        Button("Stop") { playbackEngine.stop(itemID: item.id) }
                            .disabled(!store.playingItemIDs.contains(item.id))
                        Divider()
                    }
                    Button("Delete") {
                        if store.playingItemIDs.contains(item.id) {
                            playbackEngine.stop(itemID: item.id)
                        }
                        store.deleteItem(id: item.id)
                    }
                }
            }
            .onMove { source, destination in
                store.items.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            for id in store.selectedIDs {
                if store.playingItemIDs.contains(id) {
                    playbackEngine.stop(itemID: id)
                }
            }
            store.deleteSelected()
        }
        .background {
            DropReceiverView { urls in
                let valid = urls.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
                if !valid.isEmpty {
                    store.addItems(urls: valid)
                }
            }
        }
    }

    private func rowBackground(for item: PlaylistItem) -> some View {
        colorForTag(item.colorTag)
    }

    private func colorForTag(_ tag: ColorTag) -> Color {
        switch tag {
        case .none:   return .clear
        case .red:    return .red.opacity(0.15)
        case .orange: return .orange.opacity(0.15)
        case .yellow: return .yellow.opacity(0.15)
        case .green:  return .green.opacity(0.15)
        case .blue:   return .blue.opacity(0.15)
        case .purple: return .purple.opacity(0.15)
        }
    }
}

// MARK: - Row View

struct PlaylistRowView: View {
    let item: PlaylistItem
    let index: Int
    let isPlaying: Bool
    @EnvironmentObject var store: PlaylistStore

    var body: some View {
        if item.isDivider {
            dividerRow
        } else {
            mediaRow
        }
    }

    private var dividerRow: some View {
        HStack {
            Text(item.name)
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var mediaRow: some View {
        HStack(spacing: 8) {
            // Playing indicator
            ZStack {
                if isPlaying {
                    Image(systemName: "play.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            .frame(width: 16)

            // Index number
            Text("\(index + 1)")
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
                .monospacedDigit()
                .font(.callout)

            // Type icon
            Image(systemName: item.mediaType.icon)
                .foregroundColor(item.mediaType == .video ? .blue : .orange)
                .frame(width: 20)
                .font(.callout)

            // Name
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.body)

            Spacer()

            // File missing warning
            if !item.fileExists {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .font(.caption)
                    .help("File not found: \(item.filePath)")
            }

            // Volume indicator
            Image(systemName: volumeIcon)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 16)

            // Auto-follow checkbox
            Toggle("", isOn: Binding(
                get: { item.autoFollow },
                set: { newValue in
                    if let idx = store.items.firstIndex(where: { $0.id == item.id }) {
                        store.pushUndo()
                        store.items[idx].autoFollow = newValue
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .help("Also play next item simultaneously")
            .frame(width: 20)
        }
        .padding(.vertical, 2)
        .opacity(item.fileExists ? 1.0 : 0.5)
    }

    private var volumeIcon: String {
        if item.masterVolume == 0 {
            return "speaker.slash"
        } else if item.masterVolume < 0.33 {
            return "speaker"
        } else if item.masterVolume < 0.66 {
            return "speaker.wave.1"
        } else {
            return "speaker.wave.2"
        }
    }
}

// MARK: - AppKit Drop Receiver

struct DropReceiverView: NSViewRepresentable {
    var onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropNSView {
        let view = DropNSView()
        view.onDrop = onDrop
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: DropNSView, context: Context) {
        nsView.onDrop = onDrop
    }
}

class DropNSView: NSView {
    var onDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasValidFiles(sender) { return .copy }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if hasValidFiles(sender) { return .copy }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: sender), !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func hasValidFiles(_ info: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: info) else { return false }
        return !urls.isEmpty
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL]? {
        let pasteboard = info.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else { return nil }
        return urls.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }
}
