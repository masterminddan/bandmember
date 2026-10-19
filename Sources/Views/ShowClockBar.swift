import SwiftUI
import AppKit

/// The strip under the playlist that times the show: the slot (as a
/// length, or as the time it ends), the countdown, the music left in the
/// set and the buffer between the two. See `ShowClock`.
struct ShowClockBar: View {
    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var showClock: ShowClock
    // Durations arrive in the background; redraw as they land.
    @ObservedObject private var durations = MediaDurationCache.shared

    @State private var now = Date()
    @State private var slotText = ""
    @State private var editingSlot = false
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let status = showClock.status(at: now)
        HStack(spacing: 16) {
            slotField

            Divider().frame(height: 32)

            if status.mode == .endTime {
                readout("Now", value: timeOfDay(now), color: .secondary)
            }

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

            // Running to an end time, the wall clock does the counting;
            // there is nothing to start or reset.
            if status.mode == .length {
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
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onReceive(ticker) { now = $0 }
        .onAppear { syncSlotText() }
        .onChange(of: store.clockSettings) { _ in if !editingSlot { syncSlotText() } }
    }

    private var startButtonTitle: String {
        if showClock.isRunning { return "Pause" }
        return showClock.hasStarted ? "Resume" : "Start"
    }

    // MARK: - The slot

    private var isEndTimeMode: Bool { store.clockSettings.mode == .endTime }

    /// Mode switch plus the field for the length or the end time.
    private var slotField: some View {
        VStack(alignment: .leading, spacing: 1) {
            caption(isEndTimeMode ? "Set ends at" : "Show length")
            HStack(spacing: 6) {
                Picker("", selection: modeBinding) {
                    Image(systemName: "timer").tag(ShowClock.Mode.length)
                        .help("Count a show length down from Start")
                    Image(systemName: "clock").tag(ShowClock.Mode.endTime)
                        .help("Count down to the time the set has to end")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 64)
                .help("Give the slot as a length, or as the time it ends")

                TextField(isEndTimeMode ? "7:15 PM" : "30:00", text: $slotText, onEditingChanged: { began in
                    editingSlot = began
                    if !began { commitSlot() }
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: isEndTimeMode ? 84 : 72)
                .onSubmit {
                    commitSlot()
                    // Hand the keyboard back to the playlist so the spacebar
                    // plays the next song instead of typing into this field.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .help(isEndTimeMode
                      ? "Time of day the set has to be over by: 7:15pm, 7:15 or 19:15"
                      : "Total time the show is allowed to run: minutes, mm:ss or h:mm:ss")
            }
        }
    }

    /// Switching to end time for the first time starts from the time the
    /// show would end if it began now, rounded up to five minutes, so the
    /// field never sits empty.
    private var modeBinding: Binding<ShowClock.Mode> {
        Binding(
            get: { store.clockSettings.mode },
            set: { mode in
                var settings = store.clockSettings
                settings.mode = mode
                if mode == .endTime, settings.endTime == nil {
                    let end = ShowClock.secondsAfterMidnight(of: now) + settings.length
                    settings.endTime = (end / 300).rounded(.up) * 300
                }
                store.clockSettings = settings
            }
        )
    }

    private func syncSlotText() {
        let settings = store.clockSettings
        if settings.mode == .endTime, let end = settings.endTime {
            slotText = ShowClock.formatTimeOfDay(end, now: now)
        } else {
            slotText = ShowClock.format(settings.length)
        }
    }

    private func commitSlot() {
        var settings = store.clockSettings
        if settings.mode == .endTime {
            if let seconds = ShowClock.parseTimeOfDay(slotText, now: now) { settings.endTime = seconds }
        } else if let seconds = ShowClock.parseLength(slotText) {
            settings.length = seconds
        }
        if settings != store.clockSettings { store.clockSettings = settings }
        syncSlotText()
    }

    private func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
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

    /// Red once the set no longer fits, green while there is any room left.
    private func bufferColor(_ buffer: TimeInterval) -> Color {
        buffer < 0 ? .red : .green
    }
}
