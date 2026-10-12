import SwiftUI
import AppKit

/// The strip under the playlist that times the show: the length of the
/// slot, the countdown, the music left in the set and the buffer between
/// the two. See `ShowClock`.
struct ShowClockBar: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var showClock: ShowClock
    // Durations arrive in the background; redraw as they land.
    @ObservedObject private var durations = MediaDurationCache.shared

    @State private var now = Date()
    @State private var lengthText = ""
    @State private var editingLength = false
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let status = showClock.status(at: now)
        HStack(spacing: 16) {
            showLengthField

            Divider().frame(height: 32)

            readout("Remaining", value: ShowClock.format(status.remaining),
                    color: status.remaining < 0 ? .red : .primary, large: true)

            if status.hasSet {
                readout("Music left",
                        value: ShowClock.format(status.musicLeft),
                        detail: musicDetail(status),
                        color: .primary)
                readout("Buffer",
                        value: ShowClock.format(status.buffer, showSign: true),
                        detail: status.buffer < 0 ? "over" : nil,
                        color: bufferColor(status.buffer), large: true)
            } else {
                Text("No set marked. Right-click a divider and choose “Set Starts Here”.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: { showClock.toggle() }) {
                Label(startButtonTitle, systemImage: showClock.isRunning ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut("t", modifiers: .command)
            .help(showClock.isRunning ? "Pause the show clock (⌘T)" : "Start the show clock (⌘T)")

            Button(action: { showClock.reset() }) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(!showClock.hasStarted)
            .help("Back to the full show length (⇧⌘T)")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onReceive(ticker) { now = $0 }
        .onAppear { syncLengthText() }
        .onChange(of: store.showLengthSeconds) { _ in if !editingLength { syncLengthText() } }
    }

    private var startButtonTitle: String {
        if showClock.isRunning { return "Pause" }
        return showClock.hasStarted ? "Resume" : "Start"
    }

    // MARK: - Show length

    private var showLengthField: some View {
        VStack(alignment: .leading, spacing: 1) {
            caption("Show length")
            TextField("30:00", text: $lengthText, onEditingChanged: { began in
                editingLength = began
                if !began { commitLength() }
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(width: 72)
            .onSubmit {
                commitLength()
                // Hand the keyboard back to the playlist so the spacebar
                // plays the next song instead of typing into this field.
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .help("Total time the show is allowed to run: minutes, mm:ss or h:mm:ss")
        }
    }

    private func syncLengthText() {
        lengthText = ShowClock.format(store.showLengthSeconds)
    }

    private func commitLength() {
        if let seconds = ShowClock.parseLength(lengthText), seconds != store.showLengthSeconds {
            store.showLengthSeconds = seconds
        }
        syncLengthText()
    }

    // MARK: - Readouts

    private func readout(_ title: String, value: String, detail: String? = nil,
                         color: Color, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            caption(title)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: large ? 22 : 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(color)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
    }

    /// "6 of 10 songs", from the selected one down, plus a note when some
    /// lengths are unknown.
    private func musicDetail(_ status: ShowClock.Status) -> String {
        var text = status.songsLeft == status.songsTotal
            ? (status.songsTotal == 1 ? "1 song" : "\(status.songsTotal) songs")
            : "\(status.songsLeft) of \(status.songsTotal) songs"
        if status.unknownCount > 0 {
            text += " · \(status.unknownCount) unknown length"
        }
        return text
    }

    /// Red once the set no longer fits, orange with under two minutes of
    /// room, green otherwise.
    private func bufferColor(_ buffer: TimeInterval) -> Color {
        if buffer < 0 { return .red }
        if buffer < 120 { return .orange }
        return .green
    }
}
