import Foundation

/// Times the set against the show's slot. Start it when the show starts;
/// from then on it counts the slot down. The music still to come is read
/// off the selection: the spacebar leaves the next song selected after
/// each one it fires, so the selected song and everything below it in the
/// set are still to play, plus the rest of whatever is playing now. The
/// buffer is what's left of the slot once that music has been played back
/// to back — the breathing room for talking between songs. It goes
/// negative, and stays negative, once the show runs over.
final class ShowClock: ObservableObject {
    static let defaultShowLength: TimeInterval = 30 * 60

    /// How the slot is given: as a length the clock counts down from
    /// Start, or as the time of day the set has to be over by, which the
    /// wall clock counts down to on its own.
    enum Mode: String, Codable, CaseIterable {
        case length
        case endTime
    }

    /// What the clock is set to. Saved with the playlist.
    struct Settings: Equatable {
        var mode: Mode = .length
        var length: TimeInterval = ShowClock.defaultShowLength
        /// The end time as seconds after local midnight; nil until one is
        /// typed. With none set, end-time mode falls back to the length.
        var endTime: TimeInterval? = nil

        /// The end time as a date: the occurrence of that time of day
        /// closest to `now`, so a set that ends just after midnight still
        /// reads right at a quarter to twelve.
        func endDate(near now: Date) -> Date? {
            guard mode == .endTime, let endTime else { return nil }
            return ShowClock.date(atSecondsAfterMidnight: endTime, nearest: now)
        }
    }

    /// When the clock was last started; nil while it is stopped.
    @Published private(set) var runningSince: Date?
    /// Time on the clock accumulated before the current run.
    @Published private(set) var elapsedBeforeRun: TimeInterval = 0

    private weak var store: PlaylistStore?
    private weak var engine: PlaybackEngine?

    var isRunning: Bool { runningSince != nil }
    /// True from the first start until the next reset.
    var hasStarted: Bool { runningSince != nil || elapsedBeforeRun > 0 }

    func attach(store: PlaylistStore, engine: PlaybackEngine) {
        self.store = store
        self.engine = engine
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        elapsedBeforeRun + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func start() {
        guard !isRunning else { return }
        runningSince = Date()
    }

    func pause() {
        guard let since = runningSince else { return }
        elapsedBeforeRun += max(0, Date().timeIntervalSince(since))
        runningSince = nil
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    func reset() {
        runningSince = nil
        elapsedBeforeRun = 0
    }

    // MARK: - Status

    struct Status {
        var mode: Mode
        /// In end-time mode, when the set has to be over.
        var endDate: Date?
        /// Slot time left: the length less the time on the clock, or the
        /// time until the end time. Negative once the show runs over.
        var remaining: TimeInterval
        /// Music still to be played in the set, back to back: the selected
        /// song and those below it in full, plus the rest of whatever is
        /// playing now.
        var musicLeft: TimeInterval
        /// Slot time left over after the remaining music. Negative means
        /// the set no longer fits even without a break.
        var buffer: TimeInterval { remaining - musicLeft }
        /// Songs of the set from the selection down (not counting one that
        /// is already playing).
        var songsLeft: Int
        var songsTotal: Int
        /// Songs left out of `musicLeft` because no length is known for
        /// them yet (file missing, or still being read).
        var unknownCount: Int
        /// False when no divider marks where the set starts.
        var hasSet: Bool
    }

    func status(at now: Date = Date()) -> Status {
        let settings = store?.clockSettings ?? Settings()
        let endDate = settings.endDate(near: now)
        let remaining = endDate.map { $0.timeIntervalSince(now) } ?? (settings.length - elapsed(at: now))
        var status = Status(mode: endDate == nil ? .length : .endTime, endDate: endDate,
                            remaining: remaining, musicLeft: 0, songsLeft: 0, songsTotal: 0,
                            unknownCount: 0, hasSet: false)
        guard let store else { return status }
        status.hasSet = store.setRange != nil
        let durations = MediaDurationCache.shared
        let cutoff = stillToComeCutoff(in: store)
        for entry in store.setEntries {
            status.songsTotal += 1
            let playing = entry.tracks.filter { store.playingItemIDs.contains($0.id) }
            if !playing.isEmpty {
                // The rest of what is playing, however it was selected.
                let left = playing.compactMap { track -> Double? in
                    guard let length = durations.duration(forPath: track.filePath) else { return nil }
                    let position = engine?.currentTime(for: track.id) ?? 0
                    return max(0, length - position)
                }
                if let longest = left.max() {
                    status.musicLeft += longest
                } else {
                    status.unknownCount += 1
                }
            } else if entry.index >= cutoff {
                status.songsLeft += 1
                if let length = durations.duration(of: entry.tracks) {
                    status.musicLeft += length
                } else {
                    status.unknownCount += 1
                }
            }
        }
        return status
    }

    /// Row index from which set entries count as still to come: the
    /// selected row (its group's header if it is a track in a group). With
    /// nothing selected, or the selection above the set, the whole set is
    /// still to come; a selection below the set leaves nothing.
    private func stillToComeCutoff(in store: PlaylistStore) -> Int {
        guard let selected = store.firstSelectedIndex, let range = store.setRange else { return Int.min }
        if selected < range.lowerBound { return Int.min }
        return store.groupHeaderIndex(forItemAt: selected) ?? selected
    }

    // MARK: - Times of day

    /// The date on which the time of day `seconds` after midnight falls
    /// closest to `now`: today, or yesterday or tomorrow if that is nearer.
    static func date(atSecondsAfterMidnight seconds: TimeInterval, nearest now: Date) -> Date {
        let calendar = Calendar.current
        let total = Int(seconds.rounded())
        let candidates = (-1...1).compactMap { offset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            return calendar.date(bySettingHour: (total / 3600) % 24, minute: (total % 3600) / 60,
                                 second: total % 60, of: day)
        }
        return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) } ?? now
    }

    /// Seconds after local midnight of `date`.
    static func secondsAfterMidnight(of date: Date) -> TimeInterval {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hours = parts.hour ?? 0, minutes = parts.minute ?? 0, seconds = parts.second ?? 0
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    /// "7:15 PM" (or "19:15" where the clock is 24-hour).
    static func formatTimeOfDay(_ seconds: TimeInterval, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date(atSecondsAfterMidnight: seconds, nearest: now))
    }

    /// Reads a time of day typed as "7:15pm", "7:15 PM", "715pm", "7pm",
    /// "19:15" or "7:15:30". Without am or pm, an hour up to 12 is taken as
    /// the next time that hour comes round, so "7:15" typed in the
    /// afternoon means the evening. Returns seconds after midnight, or nil
    /// when it doesn't parse.
    static func parseTimeOfDay(_ text: String, now: Date = Date()) -> TimeInterval? {
        var body = text.lowercased().filter { !$0.isWhitespace && $0 != "." }
        var meridiem: String? = nil
        for suffix in ["am", "pm", "a", "p"] where body.hasSuffix(suffix) {
            meridiem = String(suffix.prefix(1))
            body.removeLast(suffix.count)
            break
        }
        guard !body.isEmpty else { return nil }
        var fields: [Int]
        if body.contains(":") {
            let parts = body.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else { return nil }
            fields = parts.map { $0! }
        } else {
            // Digits only: "7", "19", "715", "1915".
            guard let number = Int(body), body.count <= 4 else { return nil }
            fields = body.count <= 2 ? [number] : [number / 100, number % 100]
        }
        var hour = fields[0]
        let minute = fields.count > 1 ? fields[1] : 0
        let second = fields.count > 2 ? fields[2] : 0
        guard (0...59).contains(minute), (0...59).contains(second) else { return nil }
        switch meridiem {
        case "a":
            guard (1...12).contains(hour) else { return nil }
            hour %= 12
        case "p":
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + 12
        default:
            guard (0...23).contains(hour) else { return nil }
            if (1...12).contains(hour) {
                // Ambiguous: the next time that reading comes round.
                let morning = TimeInterval((hour % 12) * 3600 + minute * 60 + second)
                let current = secondsAfterMidnight(of: now)
                let evening = morning + 12 * 3600
                if current >= morning && current < evening { return evening }
                return morning
            }
        }
        return TimeInterval(hour * 3600 + minute * 60 + second)
    }

    // MARK: - Formatting

    /// "4:07", "1:02:33"; negative values get a leading minus and keep
    /// counting ("-0:41" is 41 seconds over). With `showSign`, positive
    /// values get a plus.
    static func format(_ seconds: TimeInterval, showSign: Bool = false) -> String {
        guard seconds.isFinite else { return "–:––" }
        let total = Int(abs(seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let body = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if seconds <= -1 { return "-" + body }
        return showSign ? "+" + body : body
    }

    /// Reads a show length typed as minutes ("30", "45.5"), "mm:ss" or
    /// "h:mm:ss". Nil when it doesn't parse or isn't positive.
    static func parseLength(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, !numbers.isEmpty, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        let seconds: Double
        switch numbers.count {
        case 1: seconds = numbers[0] * 60
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
        return seconds > 0 ? seconds : nil
    }
}
