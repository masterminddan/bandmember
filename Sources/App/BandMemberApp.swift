import SwiftUI

@main
struct BandMemberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = PlaylistStore()
    @StateObject private var playbackEngine = PlaybackEngine()
    @ObservedObject private var audioOut = AudioOutputManager.shared
    @ObservedObject private var busStore = OutputBusStore.shared
    @State private var showMappingEditor = false
    @AppStorage("darkMode") private var darkMode = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(playbackEngine)
                .onAppear {
                    playbackEngine.store = store
                    appDelegate.store = store
                    TempoCoordinator.shared.attach(to: store)
                    store.restoreLastSession()
                    warnAboutMissingBuses()
                }
                .onReceive(NotificationCenter.default.publisher(for: .playlistDidLoad)) { _ in
                    warnAboutMissingBuses()
                }
                .sheet(isPresented: $showMappingEditor) {
                    OutputMappingEditor()
                        .frame(minWidth: 620, minHeight: 420)
                }
                .preferredColorScheme(darkMode ? .dark : .light)
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

            CommandGroup(after: .toolbar) {
                Toggle("Dark Mode", isOn: $darkMode)
                    .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("Playback") {
                Button("Fade Out & Stop All") {
                    playbackEngine.fadeOutAndStopAll()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            CommandMenu("Audio") {
                // Inline picker renders native macOS checkmarks for the
                // selected device automatically. Selecting "System Default"
                // unpins (`currentUID = nil`); selecting a named device
                // pins to it. PlaybackEngine subscribes to currentUID
                // changes and re-routes its output AU accordingly.
                Picker("Output Device", selection: $audioOut.currentUID) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    ForEach(audioOut.devices) { dev in
                        Text("\(dev.name) — \(dev.channelCount) ch")
                            .tag(String?.some(dev.uid))
                    }
                }
                Divider()
                Button("Edit Output Mappings…") {
                    showMappingEditor = true
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }
    }

    /// Scans the just-loaded playlist for cues whose bus has gone missing
    /// (e.g. the playlist came from another machine, or the user deleted
    /// the bus). Surfaces an alert summarizing how many cues are affected
    /// and offers to remap them to Main, or leave them alone for manual
    /// fix-up via the mapping editor.
    private func warnAboutMissingBuses() {
        let known = Set(busStore.buses.map { $0.id })
        let missing = store.items.filter {
            !$0.isDivider && !known.contains($0.outputRouting.busID)
        }
        guard !missing.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Output bus missing"
        alert.informativeText = """
            \(missing.count) cue\(missing.count == 1 ? "" : "s") route to a bus that is not defined on this machine. Until you fix this, those cues will play to the Main bus.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reroute to Main")
        alert.addButton(withTitle: "Leave as-is")
        alert.addButton(withTitle: "Edit Mappings…")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            store.pushUndo()
            for item in missing {
                if let idx = store.items.firstIndex(where: { $0.id == item.id }) {
                    store.items[idx].outputRouting = OutputRouting(busID: busStore.mainBusID)
                }
            }
        case .alertThirdButtonReturn:
            showMappingEditor = true
        default:
            break  // leave as-is; engine still falls back to ch 1 stereo
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaFileTypes.contentTypes

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
