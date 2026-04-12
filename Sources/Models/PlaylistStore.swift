import SwiftUI
import Combine

private let kLastPlaylistPath = "lastPlaylistPath"

class PlaylistStore: ObservableObject {
    @Published var items: [PlaylistItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var playingItemIDs: Set<UUID> = []
    @Published var currentFilePath: URL? = nil
    private var savedSnapshot: [PlaylistItem] = []

    var hasUnsavedChanges: Bool {
        items != savedSnapshot
    }

    /// The first selected item (for inspector / spacebar).
    var firstSelectedItem: PlaylistItem? {
        // Return the selected item that appears first in the playlist order
        for item in items {
            if selectedIDs.contains(item.id) { return item }
        }
        return nil
    }

    /// Index of the first selected item.
    var firstSelectedIndex: Int? {
        items.firstIndex { selectedIDs.contains($0.id) }
    }

    func addItems(urls: [URL]) {
        for url in urls {
            let item = PlaylistItem(url: url)
            items.append(item)
        }
    }

    func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
        selectedIDs.remove(id)
    }

    func deleteSelected() {
        let idsToDelete = selectedIDs
        guard !idsToDelete.isEmpty else { return }
        // Find the index of the first selected item to select its neighbor after deletion
        let firstIdx = items.firstIndex { idsToDelete.contains($0.id) }
        items.removeAll { idsToDelete.contains($0.id) }
        selectedIDs = []
        // Select the item that took the first deleted item's position
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
        items.swapAt(index, index - 1)
    }

    func moveDown() {
        guard selectedIDs.count == 1,
              let index = firstSelectedIndex, index < items.count - 1 else { return }
        items.swapAt(index, index + 1)
    }

    func updateItem(_ item: PlaylistItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }

    func newPlaylist() {
        items = []
        savedSnapshot = []
        selectedIDs = []
        playingItemIDs = []
        currentFilePath = nil
    }

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
        // Give each pasted item a new UUID so they're independent copies
        pasted = pasted.map { item in
            var copy = item
            copy.id = UUID()
            return copy
        }
        // Insert after the last selected item, or at the end
        let insertIndex: Int
        if let lastIdx = selectedIDs.compactMap({ id in
            items.firstIndex { $0.id == id }
        }).max() {
            insertIndex = lastIdx + 1
        } else {
            insertIndex = items.count
        }
        items.insert(contentsOf: pasted, at: insertIndex)
        selectedIDs = Set(pasted.map { $0.id })
    }
}
