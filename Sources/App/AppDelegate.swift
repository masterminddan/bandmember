import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App struct on appear so we can check dirty state on quit.
    weak var store: PlaylistStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView {
                return event
            }

            // Cmd+key shortcuts
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "z":
                    if event.modifierFlags.contains(.shift) {
                        self.store?.redo()
                    } else {
                        self.store?.undo()
                    }
                    return nil
                case "x":
                    self.store?.cutSelected()
                    return nil
                case "c":
                    self.store?.copySelected()
                    return nil
                case "v":
                    self.store?.paste()
                    return nil
                default:
                    break
                }
            }

            switch event.keyCode {
            case 49: // Spacebar
                debugLog("[KEY] Spacebar pressed")
                NotificationCenter.default.post(name: .spacebarPressed, object: nil)
                return nil
            case 36: // Return
                NotificationCenter.default.post(name: .returnPressed, object: nil)
                return nil
            case 53: // Escape
                debugLog("[KEY] Escape pressed")
                NotificationCenter.default.post(name: .escapePressed, object: nil)
                return nil
            default:
                return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = store, store.hasUnsavedChanges else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your playlist before quitting?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Save
            if store.currentFilePath != nil {
                store.saveToCurrentFile()
                return .terminateNow
            } else {
                // No existing file — show save panel
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "Playlist.json"
                if panel.runModal() == .OK, let url = panel.url {
                    try? store.save(to: url)
                    return .terminateNow
                }
                return .terminateCancel
            }

        case .alertSecondButtonReturn:
            // Don't Save
            return .terminateNow

        default:
            // Cancel
            return .terminateCancel
        }
    }
}

extension Notification.Name {
    static let spacebarPressed = Notification.Name("spacebarPressed")
    static let returnPressed = Notification.Name("returnPressed")
    static let escapePressed = Notification.Name("escapePressed")
}
