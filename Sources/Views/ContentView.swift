import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var playbackEngine: PlaybackEngine

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                PlaylistTableView()
            }
            .frame(minWidth: 400)

            ItemInspectorView()
                .frame(width: 280)
        }
        .frame(minWidth: 700, minHeight: 400)
        .navigationTitle(windowTitle)
        .onReceive(NotificationCenter.default.publisher(for: .spacebarPressed)) { _ in
            handleSpacebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .returnPressed)) { _ in
            addDivider()
        }
        .onReceive(NotificationCenter.default.publisher(for: .escapePressed)) { _ in
            playbackEngine.fadeOutAndStopAll(duration: 1.0)
        }
    }

    private var windowTitle: String {
        let name: String
        if let url = store.currentFilePath {
            name = "Band Member — \(url.lastPathComponent)"
        } else {
            name = "Band Member — Untitled"
        }
        return store.hasUnsavedChanges ? "\(name) (edited)" : name
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: addFiles) {
                Label("Add", systemImage: "plus")
            }
            .help("Add media files")

            Button(action: addDivider) {
                Label("Divider", systemImage: "text.justify.leading")
            }
            .help("Add text divider")

            Button(action: {
                // Stop any selected playing items first
                for id in store.selectedIDs {
                    if store.playingItemIDs.contains(id) {
                        playbackEngine.stop(itemID: id)
                    }
                }
                store.deleteSelected()
            }) {
                Label("Delete", systemImage: "minus")
            }
            .disabled(store.selectedIDs.isEmpty)
            .help("Delete selected items")

            Divider().frame(height: 20)

            Button(action: { handleSpacebar() }) {
                Label("GO", systemImage: "play.fill")
            }
            .disabled(store.firstSelectedItem == nil)
            .help("Play selected item (Spacebar)")

            Button(action: { playbackEngine.fadeOutAndStopAll() }) {
                Label("Stop All", systemImage: "stop.fill")
            }
            .disabled(store.playingItemIDs.isEmpty)
            .help("Fade out and stop all (Escape)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func handleSpacebar() {
        guard let item = store.firstSelectedItem else { return }

        if !store.playingItemIDs.contains(item.id) {
            playbackEngine.play(item: item)
        }

        advanceSelectionToNextIdle()
    }

    private func advanceSelectionToNextIdle() {
        guard let currentIndex = store.firstSelectedIndex else { return }
        for i in (currentIndex + 1)..<store.items.count {
            let candidate = store.items[i]
            if !store.playingItemIDs.contains(candidate.id) {
                store.selectedIDs = [candidate.id]
                return
            }
        }
    }

    private func addDivider() {
        let divider = PlaylistItem(dividerName: "— Section —")
        // Insert after the last selected item, or at the end
        if let lastIdx = store.selectedIDs.compactMap({ id in
            store.items.firstIndex { $0.id == id }
        }).max() {
            store.items.insert(divider, at: lastIdx + 1)
        } else {
            store.items.append(divider)
        }
        store.selectedIDs = [divider.id]
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mp3, .aiff, .mpeg4Movie, .quickTimeMovie]

        if panel.runModal() == .OK {
            store.addItems(urls: panel.urls)
        }
    }

    private func savePlaylist() {
        if store.currentFilePath != nil {
            store.saveToCurrentFile()
        } else {
            savePlaylistAs()
        }
    }

    private func savePlaylistAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Playlist.json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.save(to: url)
            } catch {
                showAlert(title: "Save Failed", message: error.localizedDescription)
            }
        }
    }

    private func loadPlaylist() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                playbackEngine.stopAll()
                try store.load(from: url)
            } catch {
                showAlert(title: "Load Failed", message: error.localizedDescription)
            }
        }
    }

    private func importFromQLab() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["qlab5", "qlab4"]
        panel.message = "Select a QLab workspace to import"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let imported = try QLabImporter.importCues(from: url)
                playbackEngine.stopAll()
                store.items = []
                store.currentFilePath = nil
                for cue in imported {
                    var item = PlaylistItem(url: URL(fileURLWithPath: cue.filePath))
                    item.name = cue.name
                    item.autoFollow = cue.autoFollow
                    store.items.append(item)
                }
                showAlert(title: "Import Complete",
                          message: "Imported \(imported.count) cues from \(url.lastPathComponent)")
            } catch {
                showAlert(title: "Import Failed", message: error.localizedDescription)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
