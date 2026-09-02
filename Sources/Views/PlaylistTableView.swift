import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PlaylistTableView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var playbackEngine: PlaybackEngine

    /// Highlights the list while a droppable file hovers over it.
    @State private var isDropTargeted = false

    /// SwiftUI's `List(selection: Set<ID>)` virtualizes off-screen rows.
    /// When a selected row scrolls out of view its row body is destroyed,
    /// but the binding keeps the ID — and a plain single-click elsewhere
    /// arrives as a binding update that *includes* the phantom off-screen
    /// ID, so the selection accumulates instead of being replaced. This
    /// wrapper detects that case (binding wants multi-select but neither
    /// Cmd nor Shift is held) and collapses to just the newly-added row.
    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { store.selectedIDs },
            set: { newValue in
                let mods = NSEvent.modifierFlags
                let intentionalMulti =
                    mods.contains(.command) || mods.contains(.shift)
                if intentionalMulti || newValue.count <= 1 {
                    store.selectedIDs = newValue
                    return
                }
                // Pick the freshly-added ID (the actual click target) and
                // drop everything else. Falls back to any one ID if the
                // diff is empty (degenerate states like reordering).
                let added = newValue.subtracting(store.selectedIDs)
                if let one = added.first {
                    store.selectedIDs = [one]
                } else if let any = newValue.first {
                    store.selectedIDs = [any]
                } else {
                    store.selectedIDs = []
                }
            }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
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
        // Dropping audio/video files anywhere in the playlist appends them
        // as cues.
        //
        // Deliberately NOT `ForEach.onInsert`: that registers the underlying
        // `ListCoreTableView` for `public.file-url`, which then wins the
        // AppKit dragging-destination search (it's the view under the cursor)
        // and rejects every drop that doesn't land exactly on an inter-row
        // insertion point — the drag just springs back to the Finder. With
        // the table unregistered, the search walks up to SwiftUI's own
        // dragging-destination view, which is what backs this modifier.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(providers) { urls in
                store.addItems(urls: urls)
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Resolves dropped item providers to supported media URLs, preserving the
    /// order they were dropped in. `completion` runs on the main queue and is
    /// skipped entirely when nothing in the drop is playable.
    private func loadDroppedURLs(_ providers: [NSItemProvider],
                                 completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var resolved: [Int: URL] = [:]

        for (offset, provider) in providers.enumerated() {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url, MediaFileTypes.isSupported(url) else { return }
                lock.lock()
                resolved[offset] = url
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let urls = resolved.keys.sorted().compactMap { resolved[$0] }
            guard !urls.isEmpty else { return }
            completion(urls)
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

            // Play-next label (refers to the checkbox beside it)
            Text("Play next")
                .foregroundColor(.secondary)
                .font(.caption)

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
}
