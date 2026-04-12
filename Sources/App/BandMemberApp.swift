import SwiftUI

@main
struct BandMemberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PlaylistStore()
    @StateObject private var playbackEngine = PlaybackEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(playbackEngine)
                .onAppear {
                    playbackEngine.store = store
                    appDelegate.store = store
                    store.restoreLastSession()
                }
        }
        .defaultSize(width: 950, height: 600)
        .commands {
            // Replace "New Window" with "New Playlist"
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") {
                    playbackEngine.stopAll()
                    store.newPlaylist()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Add Media Files...") {
                    addFiles()
                }
                .keyboardShortcut("d", modifiers: [.command])

                Divider()

                Button("Save Playlist") {
                    savePlaylist()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save Playlist As...") {
                    savePlaylistAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Load Playlist...") {
                    loadPlaylist()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Import from QLab...") {
                    importFromQLab()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandMenu("Playback") {
                Button("Fade Out & Stop All") {
                    playbackEngine.fadeOutAndStopAll()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
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

    /// Save: if we have a current file, save silently. Otherwise show Save As.
    private func savePlaylist() {
        if store.currentFilePath != nil {
            store.saveToCurrentFile()
        } else {
            savePlaylistAs()
        }
    }

    /// Save As: always shows a save panel.
    private func savePlaylistAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Playlist.json"

        if panel.runModal() == .OK, let url = panel.url {
            try? store.save(to: url)
        }
    }

    private func loadPlaylist() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            playbackEngine.stopAll()
            try? store.load(from: url)
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
                let alert = NSAlert()
                alert.messageText = "Import Complete"
                alert.informativeText = "Imported \(imported.count) cues from \(url.lastPathComponent)"
                alert.alertStyle = .informational
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
