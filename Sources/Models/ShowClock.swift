import Combine
import Foundation

/// Times the set against the show's slot. Start it when the show starts;
/// from then on it counts the slot down and, as each song of the set is
/// triggered, marks it played so the music still to come keeps shrinking.
/// The buffer is what's left of the slot once the remaining music has been
/// played back to back — the breathing room for talking between songs. It
/// goes negative, and stays negative, once the show runs over.
final class ShowClock: ObservableObject {
    static let defaultShowLength: TimeInterval = 30 * 60

    /// When the clock was last started; nil while it is stopped.
    @Published private(set) var runningSince: Date?
    /// Time on the clock accumulated before the current run.
    @Published private(set) var elapsedBeforeRun: TimeInterval = 0
    /// Songs of the set (by entry ID, see `PlaylistStore.setEntries`)
    /// played since the clock was last reset.
    @Published private(set) var playedEntryIDs: Set<UUID> = []

    private weak var store: PlaylistStore?
    private weak var engine: PlaybackEngine?
    private var playingCancellable: AnyCancellable?

    var isRunning: Bool { runningSince != nil }
    /// True from the first start until the next reset.
    var hasStarted: Bool { runningSince != nil || elapsedBeforeRun > 0 }

    func attach(store: PlaylistStore, engine: PlaybackEngine) {
        self.store = store
        self.engine = engine
        // Watch for songs starting. Only the ones that start while the
        // clock runs count as played — a sound check before the show
        // doesn't use up the set.
        playingCancellable = store.$playingItemIDs
            .scan((previous: Set<UUID>(), current: Set<UUID>())) { ($0.current, $1) }
            .sink { [weak self] pair in
                self?.notePlaying(pair.current.subtracting(pair.previous))
            }
    }

    private func notePlaying(_ trackIDs: Set<UUID>) {
        guard isRunning, !trackIDs.isEmpty, let store else { return }
        for entry in store.setEntries where entry.tracks.contains(where: { trackIDs.contains($0.id) }) {
            playedEntryIDs.insert(entry.id)
        }
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        elapsedBeforeRun + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func start() {
        guard !isRunning else { return }
        runningSince = Date()
        // Whatever is already playing is part of the show.
        if let store { notePlaying(store.playingItemIDs) }
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
        playedEntryIDs = []
    }

    func setPlayed(_ played: Bool, entryID: UUID) {
        if played { playedEntryIDs.insert(entryID) } else { playedEntryIDs.remove(entryID) }
    }

    // MARK: - Status

    struct Status {
        var showLength: TimeInterval
        var elapsed: TimeInterval
        /// Slot time left. Negative once the show runs over.
        var remaining: TimeInterval { showLength - elapsed }
        /// Music still to be played in the set, back to back: the unplayed
        /// songs in full plus the rest of whatever is playing now.
        var musicLeft: TimeInterval
        /// Slot time left over after the remaining music. Negative means
        /// the set no longer fits even without a break.
        var buffer: TimeInterval { remaining - musicLeft }
        /// Songs of the set not yet started.
        var songsLeft: Int
        var songsTotal: Int
        /// Songs left out of `musicLeft` because no length is known for
        /// them yet (file missing, or still being read).
        var unknownCount: Int
        /// False when no divider marks where the set starts.
        var hasSet: Bool
    }

    func status(at now: Date = Date()) -> Status {
        let showLength = store?.showLengthSeconds ?? Self.defaultShowLength
        var status = Status(showLength: showLength, elapsed: elapsed(at: now),
                            musicLeft: 0, songsLeft: 0, songsTotal: 0,
                            unknownCount: 0, hasSet: false)
        guard let store else { return status }
        status.hasSet = store.setRange != nil
        let durations = MediaDurationCache.shared
        for entry in store.setEntries {
            status.songsTotal += 1
            let playing = entry.tracks.filter { store.playingItemIDs.contains($0.id) }
            if !playing.isEmpty {
                // The rest of what is playing. Lengths are known here: the
                // file opened, so the cache will have read it too.
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
                if !playedEntryIDs.contains(entry.id) { status.songsLeft += 1 }
            } else if playedEntryIDs.contains(entry.id) {
                continue
            } else {
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
