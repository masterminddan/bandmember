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
    @Published var items: [PlaylistItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var playingItemIDs: Set<UUID> = []
    @Published var currentFilePath: URL? = nil
    private var savedSnapshot: [PlaylistItem] = []

    /// Mirrors `selectedIDs` to `UserDefaults` on every change so the
    /// selection survives across launches. Restored by `restoreLastSession`
    /// after the playlist itself loads.
    private var selectionPersistenceCancellable: AnyCancellable?

    /// Play groups the user has collapsed in the playlist, keyed by the ID
    /// of the group's first item. View state only — it isn't part of the
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

    // MARK: - Play groups

    /// Runs of items that start together: a first item with "play next"
    /// checked, plus everything the chain of checkboxes pulls in after it
    /// (the same walk `PlaybackEngine.play` does). Dividers at either end
    /// of a run aren't counted as part of it.
    var playGroups: [ClosedRange<Int>] {
        var groups: [ClosedRange<Int>] = []
        var i = 0
        while i < items.count {
            guard items[i].autoFollow else { i += 1; continue }
            var chainEnd = i
            while items[chainEnd].autoFollow && chainEnd + 1 < items.count { chainEnd += 1 }
            var first = i, last = chainEnd
            while first < last && items[first].isDivider { first += 1 }
            while last > first && items[last].isDivider { last -= 1 }
            if last > first { groups.append(first...last) }
            i = chainEnd + 1
        }
        return groups
    }

    /// IDs of the items currently folded away inside collapsed groups
    /// (every member of a collapsed group except its first item).
    var hiddenItemIDs: Set<UUID> {
        var hidden: Set<UUID> = []
        for group in playGroups where collapsedGroupIDs.contains(items[group.lowerBound].id) {
            for index in group.dropFirst() { hidden.insert(items[index].id) }
        }
        return hidden
    }

    /// The row at `index` as the user sees it: just that item, or — when it
    /// is the first item of a collapsed group — the whole group. A collapsed
    /// group is one row on screen, so moving, copying or deleting that row
    /// has to take everything folded inside it along.
    func rowRange(at index: Int) -> ClosedRange<Int> {
        if collapsedGroupIDs.contains(items[index].id),
           let group = playGroups.first(where: { $0.lowerBound == index }) {
            return group
        }
        return index...index
    }

    /// `ids` plus the hidden members of any collapsed group whose first
    /// item is among them.
    func includingCollapsedMembers(_ ids: Set<UUID>) -> Set<UUID> {
        var result = ids
        for group in playGroups {
            let headID = items[group.lowerBound].id
            if ids.contains(headID) && collapsedGroupIDs.contains(headID) {
                for index in group { result.insert(items[index].id) }
            }
        }
        return result
    }

    /// Where something inserted "after the selection" should go: past the
    /// last selected row, including anything folded inside it. End of the
    /// list when nothing is selected.
    var insertionIndexAfterSelection: Int {
        let lastSelected = items.indices.last { selectedIDs.contains(items[$0].id) }
        guard let index = lastSelected else { return items.count }
        return rowRange(at: index).upperBound + 1
    }

    func setGroupCollapsed(_ collapsed: Bool, headID: UUID) {
        if collapsed {
            collapsedGroupIDs.insert(headID)
            moveSelectionOutOfHiddenRows()
        } else {
            collapsedGroupIDs.remove(headID)
        }
    }

    func setAllGroupsCollapsed(_ collapsed: Bool) {
        let headIDs = playGroups.map { items[$0.lowerBound].id }
        if collapsed {
            collapsedGroupIDs.formUnion(headIDs)
            moveSelectionOutOfHiddenRows()
        } else {
            collapsedGroupIDs.subtract(headIDs)
        }
    }

    /// A selected row that has just been folded away hands its selection to
    /// the group's first item, so the selection never points at something
    /// that isn't on screen.
    private func moveSelectionOutOfHiddenRows() {
        var selection = selectedIDs
        for group in playGroups where collapsedGroupIDs.contains(items[group.lowerBound].id) {
            let memberIDs = group.dropFirst().map { items[$0].id }
            if !selection.isDisjoint(with: memberIDs) {
                selection.subtract(memberIDs)
                selection.insert(items[group.lowerBound].id)
            }
        }
        if selection != selectedIDs { selectedIDs = selection }
    }

    /// Moves the rows at `source` (indices into `items`, each standing for
    /// its whole `rowRange`) so they sit before the item currently at
    /// `destination`.
    func moveRows(at source: IndexSet, to destination: Int) {
        var moving = IndexSet()
        for index in source { moving.insert(integersIn: rowRange(at: index)) }
        pushUndo()
        items.move(fromOffsets: moving, toOffset: destination)
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
        let idsToDelete = includingCollapsedMembers([id])
        pushUndo()
        items.removeAll { idsToDelete.contains($0.id) }
        selectedIDs.subtract(idsToDelete)
    }

    func deleteSelected() {
        let idsToDelete = includingCollapsedMembers(selectedIDs)
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
        let doc = PlaylistDocument(items: items)
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
        let doc = try JSONDecoder().decode(PlaylistDocument.self, from: data)
        pushUndo()
        items = doc.items
        savedSnapshot = doc.items
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

    func copySelected() {
        let idsToCopy = includingCollapsedMembers(selectedIDs)
        let selected = items.filter { idsToCopy.contains($0.id) }
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
              var pasted = try? JSONDecoder().decode([PlaylistItem].self, from: data) else { return }
        pasted = pasted.map { item in
            var copy = item
            copy.id = UUID()
            return copy
        }
        let insertIndex = insertionIndexAfterSelection
        pushUndo()
        items.insert(contentsOf: pasted, at: insertIndex)
        selectedIDs = Set(pasted.map { $0.id })
    }
}
