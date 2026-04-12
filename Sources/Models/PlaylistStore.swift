import SwiftUI
import Combine

private let kLastPlaylistPath = "lastPlaylistPath"

class PlaylistStore: ObservableObject {
    @Published var items: [PlaylistItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var playingItemIDs: Set<UUID> = []
    @Published var currentFilePath: URL? = nil
    private var savedSnapshot: [PlaylistItem] = []

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

    // MARK: - Mutations (all call pushUndo)

    func addItems(urls: [URL]) {
        pushUndo()
        for url in urls {
            let item = PlaylistItem(url: url)
            items.append(item)
        }
    }

    func deleteItem(id: UUID) {
        pushUndo()
        items.removeAll { $0.id == id }
        selectedIDs.remove(id)
    }

    func deleteSelected() {
        let idsToDelete = selectedIDs
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
    }

    func restoreLastSession() {
        guard let path = UserDefaults.standard.string(forKey: kLastPlaylistPath),
              FileManager.default.fileExists(atPath: path) else { return }
        try? load(from: URL(fileURLWithPath: path))
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
        let selected = items.filter { selectedIDs.contains($0.id) }
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
        let insertIndex: Int
        if let lastIdx = selectedIDs.compactMap({ id in
            items.firstIndex { $0.id == id }
        }).max() {
            insertIndex = lastIdx + 1
        } else {
            insertIndex = items.count
        }
        pushUndo()
        items.insert(contentsOf: pasted, at: insertIndex)
        selectedIDs = Set(pasted.map { $0.id })
    }
}
