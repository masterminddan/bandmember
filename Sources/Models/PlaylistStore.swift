import SwiftUI
import Combine

private let kLastPlaylistPath = "lastPlaylistPath"
private let kLastSelectedItemIDs = "lastSelectedItemIDs"
private let kCollapsedGroupIDs = "collapsedGroupIDs"

extension Notification.Name {
    /// Fired by `PlaylistStore.load` after it finishes installing newly
    /// loaded items. Listeners can use this to run post-load checks
    /// (e.g. validating that referenced output buses exist).
    static let playlistDidLoad = Notification.Name("BandMember.playlistDidLoad")
}

class PlaylistStore: ObservableObject {
    @Published var items: [PlaylistItem] = [] {
        didSet { normalizeGroups() }
    }
    @Published var selectedIDs: Set<UUID> = []
    @Published var playingItemIDs: Set<UUID> = []
    @Published var currentFilePath: URL? = nil
    private var savedSnapshot: [PlaylistItem] = []

    /// Mirrors `selectedIDs` to `UserDefaults` on every change so the
    /// selection survives across launches. Restored by `restoreLastSession`
    /// after the playlist itself loads.
    private var selectionPersistenceCancellable: AnyCancellable?

    /// Groups the user has collapsed in the playlist, keyed by the ID of
    /// the group's header. View state only — it isn't part of the
    /// playlist document — but it's kept in `UserDefaults` so a set list
    /// folded down to one row per song stays that way across launches.
    @Published var collapsedGroupIDs: Set<UUID> = Set(
        (UserDefaults.standard.array(forKey: kCollapsedGroupIDs) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
    )
    private var collapsePersistenceCancellable: AnyCancellable?

    init() {
        selectionPersistenceCancellable = $selectedIDs
            .dropFirst()
            .sink { ids in
                let strs = ids.map { $0.uuidString }
                UserDefaults.standard.set(strs, forKey: kLastSelectedItemIDs)
            }
        collapsePersistenceCancellable = $collapsedGroupIDs
            .dropFirst()
            .sink { ids in
                let strs = ids.map { $0.uuidString }
                UserDefaults.standard.set(strs, forKey: kCollapsedGroupIDs)
            }
    }

    // MARK: - Undo/Redo

    private var undoStack: [(items: [PlaylistItem], selectedIDs: Set<UUID>)] = []
    private var redoStack: [(items: [PlaylistItem], selectedIDs: Set<UUID>)] = []
    private var isUndoRedoing = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call before any mutation to save the current state for undo.
    func pushUndo() {
        guard !isUndoRedoing else { return }
        undoStack.append((items: items, selectedIDs: selectedIDs))
        redoStack.removeAll()
        // Cap at 50 levels
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        isUndoRedoing = true
        redoStack.append((items: items, selectedIDs: selectedIDs))
        items = prev.items
        selectedIDs = prev.selectedIDs
        isUndoRedoing = false
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        isUndoRedoing = true
        undoStack.append((items: items, selectedIDs: selectedIDs))
        items = next.items
        selectedIDs = next.selectedIDs
        isUndoRedoing = false
    }

    // MARK: - Computed

    var hasUnsavedChanges: Bool {
        items != savedSnapshot
    }

    var firstSelectedItem: PlaylistItem? {
        for item in items {
            if selectedIDs.contains(item.id) { return item }
        }
        return nil
    }

    var firstSelectedIndex: Int? {
        items.firstIndex { selectedIDs.contains($0.id) }
    }

    // MARK: - Groups

    /// Keeps group membership consistent with the order of the list. A
    /// group is its header followed directly by its tracks, so a track
    /// only counts as a member while it sits in the unbroken run under its
    /// own header; anywhere else its `groupID` is dropped and it becomes a
    /// loose track. Runs after every change to `items`, which means code
    /// that puts a track into a group must set `groupID` and position in
    /// the same assignment.
    private func normalizeGroups() {
        var fixed = items
        var changed = false
        var openGroup: UUID? = nil
        for i in fixed.indices {
            if fixed[i].isGroup {
                openGroup = fixed[i].id
                if fixed[i].groupID != nil { fixed[i].groupID = nil; changed = true }
            } else if fixed[i].isMedia, let group = fixed[i].groupID, group == openGroup {
                continue
            } else {
                openGroup = nil
                if fixed[i].groupID != nil { fixed[i].groupID = nil; changed = true }
            }
        }
        if changed { items = fixed }
    }

    /// Indices of the tracks belonging to the group whose header is at
    /// `headerIndex` (empty for an empty group).
    func memberRange(ofGroupAt headerIndex: Int) -> Range<Int> {
        let headerID = items[headerIndex].id
        var end = headerIndex + 1
        while end < items.count, items[end].groupID == headerID { end += 1 }
        return (headerIndex + 1)..<end
    }

    /// Index of the header of the group that the item at `index` belongs
    /// to — its own index if it is a header, nil for loose rows.
    func groupHeaderIndex(forItemAt index: Int) -> Int? {
        if items[index].isGroup { return index }
        guard let groupID = items[index].groupID else { return nil }
        return items[..<index].lastIndex { $0.id == groupID }
    }

    /// Everything that plays when `item` is triggered: all the enabled
    /// tracks of its group if it is a group header or sits inside a group,
    /// otherwise just the item itself. Disabled entries never play, and a
    /// disabled header switches off its whole group.
    func playSet(for item: PlaylistItem) -> [PlaylistItem] {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            return item.isMedia && item.isEnabled ? [item] : []
        }
        if let header = groupHeaderIndex(forItemAt: index) {
            guard items[header].isEnabled else { return [] }
            return items[memberRange(ofGroupAt: header)].filter(\.isEnabled)
        }
        return items[index].isMedia && items[index].isEnabled ? [items[index]] : []
    }

    /// False for an entry that is unchecked, or that sits in a group whose
    /// header is unchecked.
    func isEffectivelyEnabled(at index: Int) -> Bool {
        guard items[index].isEnabled else { return false }
        if let header = groupHeaderIndex(forItemAt: index) { return items[header].isEnabled }
        return true
    }

    /// Checks or unchecks the entry with `id`. When that entry is part of
    /// a multi-row selection, the whole selection follows.
    func setEnabled(_ enabled: Bool, id: UUID) {
        let targets: Set<UUID> = selectedIDs.contains(id) ? selectedIDs : [id]
        pushUndo()
        var updated = items
        for i in updated.indices where targets.contains(updated[i].id) && !updated[i].isDivider {
            updated[i].isEnabled = enabled
        }
        items = updated
    }

    /// True if anything `item` would trigger is currently playing.
    func isPlaying(_ item: PlaylistItem) -> Bool {
        if playingItemIDs.contains(item.id) { return true }
        return item.isGroup && playSet(for: item).contains { playingItemIDs.contains($0.id) }
    }

    /// IDs of the tracks currently folded away inside collapsed groups.
    var hiddenItemIDs: Set<UUID> {
        Set(items.compactMap { item in
            guard let groupID = item.groupID, collapsedGroupIDs.contains(groupID) else { return nil }
            return item.id
        })
    }

    /// The row at `index` together with everything that belongs to it: a
    /// header stands for its whole group, so moving, copying or deleting it
    /// takes the tracks along. Any other row is just itself.
    func rowRange(at index: Int) -> ClosedRange<Int> {
        guard items[index].isGroup else { return index...index }
        return index...(memberRange(ofGroupAt: index).upperBound - 1)
    }

    /// `ids` plus the tracks of every group whose header is among them.
    func includingGroupMembers(_ ids: Set<UUID>) -> Set<UUID> {
        var result = ids
        for item in items {
            if let groupID = item.groupID, ids.contains(groupID) { result.insert(item.id) }
        }
        return result
    }

    /// The group a track would land in if it were inserted into `list` at
    /// `index`. Dropping above a group's track puts you inside that group,
    /// and so does dropping straight below the header or last track of a
    /// group that is open. Nil means top level.
    private func groupContext(in list: [PlaylistItem], at index: Int) -> UUID? {
        if index < list.count, let group = list[index].groupID { return group }
        guard index > 0 else { return nil }
        let above = list[index - 1]
        let group = above.isGroup ? above.id : above.groupID
        if let group = group, !collapsedGroupIDs.contains(group) { return group }
        return nil
    }

    /// Nearest position in `list` at or after `index` that isn't in the
    /// middle of a group — where headers and dividers, which can't live
    /// inside a group, have to go.
    private func topLevelIndex(in list: [PlaylistItem], atOrAfter index: Int) -> Int {
        var i = index
        while i < list.count, list[i].groupID != nil { i += 1 }
        return i
    }

    /// Index just past the last selected row and anything belonging to it.
    /// End of the list when nothing is selected.
    private var indexAfterSelection: Int {
        guard let last = items.indices.last(where: { selectedIDs.contains(items[$0].id) }) else {
            return items.count
        }
        return rowRange(at: last).upperBound + 1
    }

    /// Where a new top-level row (divider, group) goes: after the selection,
    /// and clear of whatever group the selection is in.
    var topLevelInsertionIndexAfterSelection: Int {
        topLevelIndex(in: items, atOrAfter: indexAfterSelection)
    }

    func setGroupCollapsed(_ collapsed: Bool, groupID: UUID) {
        if collapsed {
            collapsedGroupIDs.insert(groupID)
            moveSelectionOutOfHiddenRows()
        } else {
            collapsedGroupIDs.remove(groupID)
        }
    }

    func setAllGroupsCollapsed(_ collapsed: Bool) {
        let groupIDs = items.filter(\.isGroup).map(\.id)
        if collapsed {
            collapsedGroupIDs.formUnion(groupIDs)
            moveSelectionOutOfHiddenRows()
        } else {
            collapsedGroupIDs.subtract(groupIDs)
        }
    }

    /// A selected track that has just been folded away hands its selection
    /// to the group's header, so the selection never points at something
    /// that isn't on screen.
    private func moveSelectionOutOfHiddenRows() {
        var selection = selectedIDs
        for item in items {
            if let groupID = item.groupID, collapsedGroupIDs.contains(groupID),
               selection.remove(item.id) != nil {
                selection.insert(groupID)
            }
        }
        if selection != selectedIDs { selectedIDs = selection }
    }

    /// Moves the rows at `source` (indices into `items`; a header brings its
    /// group) so they sit before the item currently at `destination`.
    /// Tracks join the group they are dropped into and leave the one they
    /// are dragged out of. Groups and dividers can't go inside a group, so
    /// a drop there lands them just after it instead.
    func moveRows(at source: IndexSet, to destination: Int) {
        var moving = IndexSet()
        for index in source { moving.insert(integersIn: rowRange(at: index)) }
        guard !moving.isEmpty else { return }

        let movingItems = moving.map { items[$0] }
        var result = items
        result.remove(atOffsets: moving)
        var insertAt = destination - moving.filter { $0 < destination }.count

        let placed: [PlaylistItem]
        if movingItems.contains(where: { !$0.isMedia }) {
            insertAt = topLevelIndex(in: result, atOrAfter: insertAt)
            placed = movingItems
        } else {
            let group = groupContext(in: result, at: insertAt)
            placed = movingItems.map { item in
                var item = item
                item.groupID = group
                return item
            }
        }
        result.insert(contentsOf: placed, at: insertAt)

        guard result != items else { return }
        pushUndo()
        items = result
    }

    /// Puts the selected tracks into a new group, placed where the first of
    /// them was and named after what their names have in common. Tracks
    /// taken from other groups leave those groups.
    func groupSelected() {
        let trackIndices = items.indices.filter { selectedIDs.contains(items[$0].id) && items[$0].isMedia }
        guard let first = trackIndices.first else { return }
        let tracks = trackIndices.map { items[$0] }

        var header = PlaylistItem(groupName: Self.suggestedGroupName(for: tracks.map(\.name)))
        header.colorTag = tracks[0].colorTag

        // The new group can't sit inside the group its first track came
        // from; it goes just after that group.
        var insertAt = first
        if let home = groupHeaderIndex(forItemAt: first) {
            insertAt = memberRange(ofGroupAt: home).upperBound
        }
        insertAt -= trackIndices.filter { $0 < insertAt }.count

        var result = items
        result.remove(atOffsets: IndexSet(trackIndices))
        let members = tracks.map { track -> PlaylistItem in
            var track = track
            track.groupID = header.id
            return track
        }
        result.insert(contentsOf: [header] + members, at: insertAt)

        pushUndo()
        items = result
        selectedIDs = [header.id]
    }

    /// True when `groupSelected` has something to work with.
    var canGroupSelection: Bool {
        items.contains { selectedIDs.contains($0.id) && $0.isMedia }
    }

    /// Groups touched by the selection: selected headers, plus the groups
    /// of selected tracks.
    private var selectedGroupIDs: Set<UUID> {
        Set(items.compactMap { item in
            guard selectedIDs.contains(item.id) else { return nil }
            return item.isGroup ? item.id : item.groupID
        })
    }

    var canUngroupSelection: Bool { !selectedGroupIDs.isEmpty }

    /// Dissolves the selected groups: the headers go, the tracks stay where
    /// they are as loose tracks.
    func ungroupSelected() {
        let groupIDs = selectedGroupIDs
        guard !groupIDs.isEmpty else { return }
        pushUndo()
        var freed: Set<UUID> = []
        var result: [PlaylistItem] = []
        for var item in items {
            if item.isGroup, groupIDs.contains(item.id) { continue }
            if let groupID = item.groupID, groupIDs.contains(groupID) {
                item.groupID = nil
                freed.insert(item.id)
            }
            result.append(item)
        }
        items = result
        collapsedGroupIDs.subtract(groupIDs)
        selectedIDs = selectedIDs.subtracting(groupIDs).union(freed)
    }

    /// True when a selected track is inside a group.
    var canRemoveSelectionFromGroup: Bool {
        items.contains { selectedIDs.contains($0.id) && $0.groupID != nil }
    }

    /// Takes the selected tracks out of their groups, leaving them as loose
    /// tracks directly after the group they came from.
    func removeSelectedFromGroup() {
        guard canRemoveSelectionFromGroup else { return }
        var result: [PlaylistItem] = []
        var pending: [PlaylistItem] = []   // removed tracks waiting for their group to end
        for item in items {
            if item.groupID == nil, !pending.isEmpty {
                result.append(contentsOf: pending)
                pending.removeAll()
            }
            if item.groupID != nil, selectedIDs.contains(item.id) {
                var loose = item
                loose.groupID = nil
                pending.append(loose)
            } else {
                result.append(item)
            }
        }
        result.append(contentsOf: pending)
        pushUndo()
        items = result
    }

    // MARK: - Converting "play next" chains

    /// Words that describe a track's role in a song rather than the song
    /// itself, so they don't belong in a group's name.
    private static let roleWords: Set<String> = [
        "click", "music", "synth", "bvox", "vox", "synthvox",
        "lyrics", "lyric", "full", "drums", "video", "43",
    ]
    /// Role words that are also ordinary words in song titles ("Tell Me
    /// How to Live", "Trapped in the Song"). These only count as a role
    /// when the tracks disagree about them.
    private static let ambiguousRoleWords: Set<String> = [
        "in", "out", "live", "vocal", "vocals", "bass", "guitar", "keys",
    ]

    private static func isRoleWord(_ word: String, in set: Set<String>) -> Bool {
        // "synth2", "click.aif" → "synth", "click"
        var w = word.lowercased()
        if let dot = w.lastIndex(of: "."), dot != w.startIndex { w = String(w[..<dot]) }
        if set.contains(w) { return true }
        while let last = w.last, last.isNumber { w.removeLast() }
        return set.contains(w)
    }

    /// A name for a group of tracks: the leading words most of the track
    /// names share ("Evolver synth", "Evolver click" → "Evolver"). Falls
    /// back to the first track's name without its trailing role words.
    static func suggestedGroupName(for names: [String]) -> String {
        guard let firstName = names.first else { return "Group" }
        let words = names.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let firstWords = words[0]

        var shared = 0
        while shared < firstWords.count, !isRoleWord(firstWords[shared], in: roleWords) {
            let prefix = firstWords[...shared].map { $0.lowercased() }
            let agreeing = words.filter { $0.count > shared && $0[...shared].map { $0.lowercased() } == prefix }
            guard agreeing.count * 2 > names.count else { break }
            if agreeing.count < names.count, isRoleWord(firstWords[shared], in: ambiguousRoleWords) { break }
            shared += 1
        }
        if names.count > 1, shared > 0 {
            return firstWords[..<shared].joined(separator: " ")
        }

        var trimmed = firstWords
        while trimmed.count > 1, let last = trimmed.last,
              isRoleWord(last, in: roleWords.union(ambiguousRoleWords)) { trimmed.removeLast() }
        return trimmed.isEmpty ? firstName : trimmed.joined(separator: " ")
    }

    /// Header ID for a converted chain. Derived from the chain's first
    /// track rather than random so that reopening an unconverted playlist
    /// produces the same groups — collapse state and selection keep working
    /// until the playlist is saved in the new format.
    private static func groupID(derivedFrom trackID: UUID) -> UUID {
        var bytes = trackID.uuid
        bytes.0 ^= 0xA5
        bytes.15 ^= 0x5A
        return UUID(uuid: bytes)
    }

    /// Converts a playlist that chains tracks with "play next" checkboxes
    /// into one with groups. Each run of chained tracks becomes a group,
    /// named after what the tracks have in common and colored like its
    /// first track. Returns the new items and, for each group, the ID of
    /// the track that used to head the chain.
    static func convertChainsToGroups(_ source: [PlaylistItem]) -> (items: [PlaylistItem], heads: [UUID: UUID]) {
        var result: [PlaylistItem] = []
        var heads: [UUID: UUID] = [:]
        var i = 0
        while i < source.count {
            guard source[i].autoFollow, source[i].isMedia else {
                var item = source[i]
                item.autoFollow = false
                result.append(item)
                i += 1
                continue
            }
            // Same walk the old play logic did: keep taking the next row
            // while the current one says "play next". Stop at anything that
            // isn't a track.
            var end = i
            while source[end].autoFollow, end + 1 < source.count, source[end + 1].isMedia { end += 1 }
            var members = Array(source[i...end])
            if members.count < 2 {
                members[0].autoFollow = false
                result.append(members[0])
                i = end + 1
                continue
            }

            var header = PlaylistItem(groupName: suggestedGroupName(for: members.map(\.name)),
                                      id: groupID(derivedFrom: members[0].id))
            header.colorTag = members[0].colorTag
            // A color on only the first track was marking the start of the
            // song; that's the header's job now.
            if members.contains(where: { $0.colorTag != members[0].colorTag }) {
                members[0].colorTag = .none
            }
            for m in members.indices {
                members[m].autoFollow = false
                members[m].groupID = header.id
            }
            heads[header.id] = source[i].id
            result.append(header)
            result.append(contentsOf: members)
            i = end + 1
        }
        return (result, heads)
    }

    /// Installs items that still use "play next" chains, converting them to
    /// groups and carrying over which ones were collapsed.
    func installConvertingChains(_ source: [PlaylistItem]) {
        let converted = Self.convertChainsToGroups(source)
        for (groupID, headTrackID) in converted.heads where collapsedGroupIDs.contains(headTrackID) {
            collapsedGroupIDs.insert(groupID)
        }
        items = converted.items
    }

    /// `items` with the legacy "play next" flags filled in from the groups,
    /// for writing to disk: every track of a group but the last gets the
    /// flag, which is exactly how an older build chains them.
    private var itemsWithLegacyChainFlags: [PlaylistItem] {
        Self.withLegacyChainFlags(items)
    }

    static func withLegacyChainFlags(_ items: [PlaylistItem]) -> [PlaylistItem] {
        var out = items
        for i in out.indices {
            out[i].autoFollow = out[i].groupID != nil
                && i + 1 < out.count && out[i + 1].groupID == out[i].groupID
        }
        return out
    }

    // MARK: - Mutations (all call pushUndo)

    func addItems(urls: [URL]) {
        pushUndo()
        for url in urls {
            let item = PlaylistItem(url: url)
            items.append(item)
        }
    }

    func deleteItem(id: UUID) {
        let idsToDelete = includingGroupMembers([id])
        pushUndo()
        items.removeAll { idsToDelete.contains($0.id) }
        selectedIDs.subtract(idsToDelete)
    }

    func deleteSelected() {
        let idsToDelete = includingGroupMembers(selectedIDs)
        guard !idsToDelete.isEmpty else { return }
        pushUndo()
        let firstIdx = items.firstIndex { idsToDelete.contains($0.id) }
        items.removeAll { idsToDelete.contains($0.id) }
        selectedIDs = []
        if let firstIdx = firstIdx {
            if firstIdx < items.count {
                selectedIDs = [items[firstIdx].id]
            } else if !items.isEmpty {
                selectedIDs = [items[items.count - 1].id]
            }
        }
    }

    func moveUp() {
        guard selectedIDs.count == 1,
              let index = firstSelectedIndex, index > 0 else { return }
        pushUndo()
        items.swapAt(index, index - 1)
    }

    func moveDown() {
        guard selectedIDs.count == 1,
              let index = firstSelectedIndex, index < items.count - 1 else { return }
        pushUndo()
        items.swapAt(index, index + 1)
    }

    func updateItem(_ item: PlaylistItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            pushUndo()
            items[index] = item
        }
    }

    func newPlaylist() {
        pushUndo()
        items = []
        savedSnapshot = []
        selectedIDs = []
        playingItemIDs = []
        currentFilePath = nil
    }

    // MARK: - Save / Load

    func save(to url: URL) throws {
        // Alongside each absolute path, record where the file sits relative
        // to the playlist, so the playlist still finds its media if the two
        // are moved (or copied to another machine) together.
        let folder = url.deletingLastPathComponent()
        let doc = PlaylistDocument(items: itemsWithLegacyChainFlags.map { item in
            var item = item
            if item.isMedia {
                item.relativePath = PlaylistPaths.relativePath(from: folder, to: item.filePath)
            }
            return item
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: url)
        currentFilePath = url
        savedSnapshot = items
        UserDefaults.standard.set(url.path, forKey: kLastPlaylistPath)
    }

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var doc = try JSONDecoder().decode(PlaylistDocument.self, from: data)
        // Settle each item on the path its media is actually at.
        let folder = url.deletingLastPathComponent()
        doc.items = doc.items.map { PlaylistPaths.resolved($0, playlistFolder: folder) }
        pushUndo()
        if doc.version < PlaylistDocument.currentVersion {
            // Saved before groups existed: build them from the chains.
            installConvertingChains(doc.items)
        } else {
            // The flags in the file are only there for older builds.
            items = doc.items.map { item in
                var item = item
                item.autoFollow = false
                return item
            }
        }
        savedSnapshot = items
        selectedIDs = []
        playingItemIDs = []
        currentFilePath = url
        UserDefaults.standard.set(url.path, forKey: kLastPlaylistPath)
        // Notify listeners (e.g. BandMemberApp) so they can surface bus
        // sanity warnings now that we have new items to inspect.
        NotificationCenter.default.post(name: .playlistDidLoad, object: self)
    }

    func restoreLastSession() {
        guard let path = UserDefaults.standard.string(forKey: kLastPlaylistPath),
              FileManager.default.fileExists(atPath: path) else { return }
        // Capture the saved selection BEFORE `load` runs — load resets
        // `selectedIDs = []`, which fires the persistence sink and clobbers
        // the very thing we're trying to restore.
        let savedSelection: Set<UUID> = (UserDefaults.standard.array(forKey: kLastSelectedItemIDs)
            as? [String])
            .map { Set($0.compactMap(UUID.init(uuidString:))) } ?? []

        try? load(from: URL(fileURLWithPath: path))

        let stillPresent = savedSelection.intersection(items.map(\.id))
        if !stillPresent.isEmpty {
            selectedIDs = stillPresent
        }

        // Clear undo stack on launch — nothing to undo from a fresh start
        undoStack.removeAll()
        redoStack.removeAll()
    }

    @discardableResult
    func saveToCurrentFile() -> Bool {
        guard let url = currentFilePath else { return false }
        do {
            try save(to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Clipboard

    private static let pasteboardType = NSPasteboard.PasteboardType("com.fuqlab.playlistItems")

    /// The selected rows, in list order, as they go on the clipboard. A
    /// selected header brings its tracks.
    var selectionForCopy: [PlaylistItem] {
        let idsToCopy = includingGroupMembers(selectedIDs)
        return items.filter { idsToCopy.contains($0.id) }
    }

    func copySelected() {
        let selected = selectionForCopy
        guard !selected.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(selected) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
    }

    func cutSelected() {
        copySelected()
        deleteSelected()
    }

    func paste() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: Self.pasteboardType),
              let pasted = try? JSONDecoder().decode([PlaylistItem].self, from: data) else { return }
        insertPasted(pasted)
    }

    /// Inserts copies of `source` after the selection and selects them.
    func insertPasted(_ source: [PlaylistItem]) {
        guard !source.isEmpty else { return }
        var pasted = source
        // Fresh IDs all round, keeping copied tracks attached to copied
        // headers. A track copied without its header arrives loose.
        var newIDs: [UUID: UUID] = [:]
        for item in pasted { newIDs[item.id] = UUID() }
        pasted = pasted.map { item in
            var copy = item
            copy.id = newIDs[item.id] ?? UUID()
            copy.groupID = item.groupID.flatMap { newIDs[$0] }
            return copy
        }

        var insertIndex = indexAfterSelection
        if pasted.contains(where: { !$0.isMedia }) {
            // Groups and dividers can't go inside a group.
            insertIndex = topLevelIndex(in: items, atOrAfter: insertIndex)
        } else if let group = groupContext(in: items, at: insertIndex) {
            // Plain tracks pasted into an open group join it.
            pasted = pasted.map { item in
                var copy = item
                copy.groupID = group
                return copy
            }
        }
        pushUndo()
        items.insert(contentsOf: pasted, at: insertIndex)
        selectedIDs = Set(pasted.map { $0.id })
    }
}
