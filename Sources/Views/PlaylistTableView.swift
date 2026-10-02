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
    /// its place in a group (if any).
    private struct Row: Identifiable {
        let item: PlaylistItem
        let index: Int
        /// For a track, its number counting tracks only — headers and
        /// dividers don't use one up.
        let number: Int
        let group: PlaylistRowView.GroupRole
        /// For a header, the tracks of its group.
        let members: [PlaylistItem]
        /// False for a track whose group header is disabled.
        var groupEnabled = true
        var id: UUID { item.id }
    }

    /// The playlist as shown: tracks of collapsed groups are left out.
    private var rows: [Row] {
        let items = store.items
        let collapsed = store.collapsedGroupIDs
        var rows: [Row] = []
        rows.reserveCapacity(items.count)
        var trackNumber = 0
        var headerEnabled = true   // of the group being walked through
        for (index, item) in items.enumerated() {
            if item.isMedia { trackNumber += 1 }
            if item.isGroup {
                headerEnabled = item.isEnabled
                let members = Array(items[store.memberRange(ofGroupAt: index)])
                rows.append(Row(item: item, index: index, number: 0,
                                group: .header(trackCount: members.count,
                                               collapsed: collapsed.contains(item.id)),
                                members: members))
            } else if let groupID = item.groupID {
                if collapsed.contains(groupID) { continue }
                rows.append(Row(item: item, index: index, number: trackNumber,
                                group: .member, members: [],
                                groupEnabled: headerEnabled))
            } else {
                rows.append(Row(item: item, index: index, number: trackNumber,
                                group: .none, members: []))
            }
        }
        return rows
    }

    var body: some View {
        let rows = self.rows
        return List(selection: selectionBinding) {
            ForEach(rows) { row in
                let item = row.item
                PlaylistRowView(
                    item: item,
                    number: row.number,
                    isPlaying: store.playingItemIDs.contains(item.id)
                        || row.members.contains { store.playingItemIDs.contains($0.id) },
                    group: row.group,
                    members: row.members,
                    groupEnabled: row.groupEnabled
                )
                .tag(item.id)
                .listRowBackground(rowBackground(for: item))
                .contextMenu { contextMenu(for: row) }
            }
            .onMove { source, destination in
                // Offsets are positions among the visible rows; translate
                // them back to positions in the full playlist.
                let itemSource = IndexSet(source.map { rows[$0].index })
                let itemDestination = destination < rows.count
                    ? rows[destination].index : store.items.count
                store.moveRows(at: itemSource, to: itemDestination)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand {
            for id in store.includingGroupMembers(store.selectedIDs) {
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

    @ViewBuilder
    private func contextMenu(for row: Row) -> some View {
        let item = row.item
        if !item.isDivider {
            Button(item.isGroup ? "Play Group" : "Play") { playbackEngine.play(item: item) }
                .disabled(store.playSet(for: item).isEmpty)
            if case .member = row.group {
                Button("Play Only This Track") { playbackEngine.play(item: item, alone: true) }
                    .disabled(!item.isEnabled)
            }
            Button("Stop") { stopPlayback(ofRow: row) }
                .disabled(!store.isPlaying(item))
            Divider()
        }
        if item.isMedia {
            Button("Show in Finder") { showInFinder(item.fileURL) }
                .disabled(!item.fileExists)
            Divider()
            Button("Group Selected Tracks") {
                selectForMenuAction(item)
                store.groupSelected()
            }
            if case .member = row.group {
                Button("Remove from Group") {
                    selectForMenuAction(item)
                    store.removeSelectedFromGroup()
                }
            }
            Divider()
        }
        if case .header(_, let collapsed) = row.group {
            Button(collapsed ? "Expand Group" : "Collapse Group") {
                store.setGroupCollapsed(!collapsed, groupID: item.id)
            }
            Button("Ungroup") {
                selectForMenuAction(item)
                store.ungroupSelected()
            }
            Divider()
        }
        Button(item.isGroup ? "Delete Group" : "Delete") {
            stopPlayback(ofRow: row)
            store.deleteItem(id: item.id)
        }
    }

    /// Menu actions that work on the selection apply to the clicked row
    /// alone when it isn't part of the selection.
    private func selectForMenuAction(_ item: PlaylistItem) {
        if !store.selectedIDs.contains(item.id) { store.selectedIDs = [item.id] }
    }

    /// Stops the row's item and, for a group header, every track in the
    /// group.
    private func stopPlayback(ofRow row: Row) {
        for item in [row.item] + row.members where store.playingItemIDs.contains(item.id) {
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
    /// Where a row sits relative to groups.
    enum GroupRole {
        case none
        /// A group's header row; carries the disclosure arrow.
        case header(trackCount: Int, collapsed: Bool)
        /// A track inside a group.
        case member
    }

    let item: PlaylistItem
    /// Track number shown in the row (unused for headers and dividers).
    let number: Int
    let isPlaying: Bool
    var group: GroupRole = .none
    /// For a header, the tracks of its group; empty otherwise.
    var members: [PlaylistItem] = []
    /// False for a track whose group header is disabled.
    var groupEnabled = true
    @EnvironmentObject var store: PlaylistStore

    /// Dimmed when the entry won't play: unchecked itself, or inside an
    /// unchecked group.
    private var isActive: Bool { item.isEnabled && groupEnabled }

    /// Enable / disable checkbox at the right-hand end of the row.
    private var enabledCheckbox: some View {
        Toggle("", isOn: Binding(
            get: { item.isEnabled },
            set: { store.setEnabled($0, id: item.id) }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help(item.isGroup
              ? "Uncheck to skip this whole group"
              : "Uncheck to leave this track out when its group plays")
        .frame(width: 20)
    }

    var body: some View {
        if item.isDivider {
            dividerRow
        } else if case .header(let trackCount, let collapsed) = group {
            headerRow(trackCount: trackCount, collapsed: collapsed)
        } else {
            mediaRow
        }
    }

    private var isMember: Bool {
        if case .member = group { return true }
        return false
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

    private var playingIndicator: some View {
        ZStack {
            if isPlaying {
                Image(systemName: "play.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .frame(width: 16)
    }

    private func headerRow(trackCount: Int, collapsed: Bool) -> some View {
        HStack(spacing: 8) {
            headerContent(trackCount: trackCount, collapsed: collapsed)
                .opacity(isActive ? 1.0 : 0.45)
            enabledCheckbox
        }
        .padding(.vertical, 3)
    }

    private func headerContent(trackCount: Int, collapsed: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                // Option-click folds or unfolds every group, as in Finder.
                if NSEvent.modifierFlags.contains(.option) {
                    store.setAllGroupsCollapsed(!collapsed)
                } else {
                    store.setGroupCollapsed(!collapsed, groupID: item.id)
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
            .help(collapsed ? "Show this group's tracks" : "Hide this group's tracks")

            playingIndicator

            Image(systemName: item.mediaType.icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
                .font(.callout)

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.body.weight(.semibold))

            Text(trackCountLabel(trackCount))
                .foregroundColor(.secondary)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            // With the tracks folded away, the header has to speak for them.
            let missing = collapsed ? members.filter { !$0.fileExists } : []
            if !missing.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .font(.caption)
                    .help("File not found for: " + missing.map(\.name).joined(separator: ", "))
            }
        }
    }

    /// "6 tracks", or "5 of 6 tracks" when some are switched off.
    private func trackCountLabel(_ trackCount: Int) -> String {
        let enabled = members.filter(\.isEnabled).count
        if enabled < trackCount { return "\(enabled) of \(trackCount) tracks" }
        return trackCount == 1 ? "1 track" : "\(trackCount) tracks"
    }

    private var mediaRow: some View {
        HStack(spacing: 8) {
            mediaContent.opacity(rowOpacity)
            enabledCheckbox
        }
        .padding(.vertical, 2)
    }

    private var mediaContent: some View {
        HStack(spacing: 8) {
            // Lines up with the disclosure arrow on group headers; tracks
            // inside a group sit one step further in.
            Color.clear.frame(width: isMember ? 28 : 14, height: 1)

            playingIndicator

            // Index number
            Text("\(number)")
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
        }
    }

    /// Rows that won't play — file missing, unchecked, or in an unchecked
    /// group — are dimmed. (The checkbox itself is kept at full strength.)
    private var rowOpacity: Double {
        if !isActive { return 0.45 }
        return item.fileExists ? 1.0 : 0.5
    }
}
