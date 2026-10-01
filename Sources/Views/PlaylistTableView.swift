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

    /// One row of the list: an item, where it sits in `store.items`, and
    /// its place in a play group (if any).
    private struct Row: Identifiable {
        let item: PlaylistItem
        let index: Int
        let group: PlaylistRowView.GroupRole
        /// The rest of the group, when this row is a collapsed group's
        /// first item and is standing in for all of them.
        let foldedItems: [PlaylistItem]
        var id: UUID { item.id }
    }

    /// The playlist with collapsed groups folded down to their first item.
    private var rows: [Row] {
        let items = store.items
        var roles = [PlaylistRowView.GroupRole](repeating: .none, count: items.count)
        var folded: [Int: [PlaylistItem]] = [:]
        var hidden = IndexSet()
        for group in store.playGroups {
            let head = group.lowerBound
            let collapsed = store.collapsedGroupIDs.contains(items[head].id)
            let trackCount = group.filter { !items[$0].isDivider }.count
            roles[head] = .head(trackCount: trackCount, collapsed: collapsed)
            for index in group.dropFirst() { roles[index] = .member }
            if collapsed {
                folded[head] = group.dropFirst().map { items[$0] }
                hidden.insert(integersIn: (head + 1)...group.upperBound)
            }
        }
        return items.indices.compactMap { index in
            hidden.contains(index) ? nil : Row(item: items[index], index: index,
                                               group: roles[index],
                                               foldedItems: folded[index] ?? [])
        }
    }

    var body: some View {
        let rows = self.rows
        return List(selection: selectionBinding) {
            ForEach(rows) { row in
                let item = row.item
                PlaylistRowView(
                    item: item,
                    index: row.index,
                    isPlaying: store.playingItemIDs.contains(item.id)
                        || row.foldedItems.contains { store.playingItemIDs.contains($0.id) },
                    group: row.group,
                    foldedItems: row.foldedItems
                )
                .tag(item.id)
                .listRowBackground(rowBackground(for: item))
                .contextMenu {
                    if !item.isDivider {
                        Button("Play") { playbackEngine.play(item: item) }
                        Button("Stop") { stopPlayback(ofRow: row) }
                            .disabled(!store.playingItemIDs.contains(item.id))
                        Divider()
                        Button("Show in Finder") { showInFinder(item.fileURL) }
                            .disabled(!item.fileExists)
                        Divider()
                    }
                    if case .head(_, let collapsed) = row.group {
                        Button(collapsed ? "Expand Group" : "Collapse Group") {
                            store.setGroupCollapsed(!collapsed, headID: item.id)
                        }
                        Divider()
                    }
                    Button(row.foldedItems.isEmpty ? "Delete" : "Delete Group") {
                        stopPlayback(ofRow: row)
                        store.deleteItem(id: item.id)
                    }
                }
            }
            .onMove { source, destination in
                // Offsets are positions among the visible rows; translate
                // them back to positions in the full playlist. A collapsed
                // group travels as a unit.
                let itemSource = IndexSet(source.map { rows[$0].index })
                let itemDestination = destination < rows.count
                    ? rows[destination].index : store.items.count
                store.moveRows(at: itemSource, to: itemDestination)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            for id in store.includingCollapsedMembers(store.selectedIDs) {
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

    /// Stops the row's item and, for a collapsed group, everything folded
    /// inside it.
    private func stopPlayback(ofRow row: Row) {
        for item in [row.item] + row.foldedItems where store.playingItemIDs.contains(item.id) {
            playbackEngine.stop(itemID: item.id)
        }
    }

    /// Reveals the cue's file in a Finder window.
    private func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
    /// Where a row sits in a play group — a run of items chained together
    /// with "play next" so they start as one.
    enum GroupRole {
        case none
        /// First item of a group; carries the disclosure arrow.
        case head(trackCount: Int, collapsed: Bool)
        case member
    }

    let item: PlaylistItem
    let index: Int
    let isPlaying: Bool
    var group: GroupRole = .none
    /// The other items of the group when this row is a collapsed group's
    /// first item; empty otherwise.
    var foldedItems: [PlaylistItem] = []
    @EnvironmentObject var store: PlaylistStore

    private var isMember: Bool {
        if case .member = group { return true }
        return false
    }

    /// Files missing among the items folded inside this row.
    private var foldedMissing: [PlaylistItem] {
        foldedItems.filter { !$0.fileExists }
    }

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
            // Disclosure arrow on the first item of a play group
            ZStack {
                if case .head(_, let collapsed) = group {
                    Button(action: {
                        // Option-click folds or unfolds every group, as in Finder.
                        if NSEvent.modifierFlags.contains(.option) {
                            store.setAllGroupsCollapsed(!collapsed)
                        } else {
                            store.setGroupCollapsed(!collapsed, headID: item.id)
                        }
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 14, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(collapsed ? "Show the tracks that play with this one"
                                    : "Hide the tracks that play with this one")
                }
            }
            .frame(width: 14)

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

            // Type icon (items inside a group sit indented under its first)
            Image(systemName: item.mediaType.icon)
                .foregroundColor(item.mediaType == .video ? .blue : .orange)
                .frame(width: 20)
                .font(.callout)
                .padding(.leading, isMember ? 14 : 0)

            // Name
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.body)

            // Collapsed group: say how much is folded into this row
            if case .head(let trackCount, true) = group {
                Text("\(trackCount) tracks")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            Spacer()

            // File missing warning
            if !item.fileExists {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .font(.caption)
                    .help("File not found: \(item.filePath)")
            } else if !foldedMissing.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .font(.caption)
                    .help("File not found for: " + foldedMissing.map(\.name).joined(separator: ", "))
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
