import SwiftUI
import AppKit
import Combine

/// Fullscreen karaoke-style lyric display. Creates a borderless black window
/// on the requested screen and renders the current line large + next line
/// smaller. Driven by a timer that polls the `PlaybackEngine` for the current
/// playhead. Highlighting is line-level (not word-level) — hand-edited lyrics
/// routinely change word counts, which would make any stored per-word timings
/// stale and wrong.
final class LyricsPresenter {
    private struct Session {
        let itemID: UUID
        let doc: LyricsDocument
        let window: NSWindow
        let state: PresenterState
        let timer: Timer
    }

    private static var sessions: [UUID: Session] = [:]

    /// Opens a presenter for the given item on `screenIndex`.
    static func show(
        item: PlaylistItem,
        lyrics: LyricsDocument,
        screenIndex: Int,
        engine: PlaybackEngine
    ) {
        // Clean up any prior session for this item.
        hide(itemID: item.id)

        let screens = NSScreen.screens
        guard screenIndex >= 0, screenIndex < screens.count else {
            debugLog("LyricsPresenter: screen index \(screenIndex) unavailable")
            return
        }
        let screen = screens[screenIndex]

        let state = PresenterState()
        state.setDocument(lyrics)
        let hosting = NSHostingView(rootView: LyricsDisplayView(state: state))

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = hosting
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        var lastLoggedBucket: Int = -2
        let timerStart = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak engine] _ in
            guard let engine = engine else { return }
            let t = engine.currentTime(for: item.id) ?? item.startPosition
            // Log once per second (bucketed on floor(t)) so the log shows the
            // reported time progression without spamming 30 lines/sec.
            let bucket = Int(t.rounded(.down))
            if bucket != lastLoggedBucket {
                lastLoggedBucket = bucket
                let wall = Date().timeIntervalSince(timerStart)
                debugLog(String(format: "LyricsTimer[%@]: t=%.2fs (wall=%.2fs)", item.name, t, wall))
            }
            DispatchQueue.main.async {
                state.update(time: t)
            }
        }
        debugLog("LyricsTimer[\(item.name)]: started, item.startPosition=\(item.startPosition)")
        RunLoop.main.add(timer, forMode: .common)

        sessions[item.id] = Session(itemID: item.id, doc: lyrics,
                                    window: window, state: state, timer: timer)
        debugLog("LyricsPresenter: opened for \(item.name) on display \(screenIndex)")
    }

    /// Closes the presenter for a specific item, if one is open.
    static func hide(itemID: UUID) {
        guard let session = sessions.removeValue(forKey: itemID) else { return }
        session.timer.invalidate()
        session.window.orderOut(nil)
        session.window.close()
        debugLog("LyricsTimer: stopped for item \(itemID)")
    }

    static func hideAll() {
        for id in Array(sessions.keys) { hide(itemID: id) }
    }
}

/// Observable state shared with the SwiftUI view. Owns the filtered
/// (lyric-only) segment list and tracks which segment is the current "top"
/// line in the two-line scrolling display.
final class PresenterState: ObservableObject {
    /// Maximum lead-in for a lyric line that is preceded by silence. The
    /// line becomes the highlighted "current" row up to this many seconds
    /// before its actual start time — but only if the previous line ended
    /// at least this long ago. Back-to-back lines still switch on the
    /// new line's actual start so singers don't lose the current line
    /// while it's still being sung.
    static let leadTime: Double = 1.0

    @Published var visibleSegments: [LyricSegment] = []
    /// Index into `visibleSegments` of the current (top) line, or -1 before
    /// any lyric has come up.
    @Published var topIndex: Int = -1

    /// Effective trigger time per segment: `start - leadTime` when there's a
    /// silent gap of at least `leadTime` before the segment; otherwise the
    /// previous segment's end (back-to-back case). Precomputed here so
    /// `update` stays O(n) in number of segments without re-deriving this.
    private var effectiveStarts: [Double] = []

    func setDocument(_ doc: LyricsDocument) {
        // Clean each segment's text of music symbols and drop any segment
        // that's left empty (pure-music passages).
        visibleSegments = doc.segments.compactMap { seg in
            let cleanedText = Self.stripNonLyricMarks(seg.text)
            guard Self.isLyric(cleanedText) else { return nil }
            return LyricSegment(id: seg.id, text: cleanedText,
                                start: seg.start, end: seg.end)
        }
        effectiveStarts = Self.computeEffectiveStarts(visibleSegments, leadTime: Self.leadTime)
        topIndex = -1
    }

    func update(time: Double) {
        // Largest i such that effectiveStarts[i] <= time.
        var newTop = -1
        for (i, trigger) in effectiveStarts.enumerated() {
            if trigger <= time { newTop = i } else { break }
        }
        if newTop != topIndex {
            topIndex = newTop
        }
    }

    /// For each segment, compute the earliest time the presenter should light
    /// it up: pull forward by `leadTime` when possible, but never before the
    /// previous segment ends (and never before 0 for the first line).
    static func computeEffectiveStarts(_ segments: [LyricSegment],
                                       leadTime: Double) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(segments.count)
        for (i, seg) in segments.enumerated() {
            let earliest = seg.start - leadTime
            let floor = (i == 0) ? 0.0 : segments[i - 1].end
            out.append(max(floor, earliest))
        }
        return out
    }

    /// Whisper emits tokens like "[Music]", "[Applause]", "(instrumental)",
    /// etc. for non-speech passages. Skip those entirely.
    static func isLyric(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        let first = trimmed.first!
        let last = trimmed.last!
        if (first == "[" && last == "]") || (first == "(" && last == ")") {
            return false
        }
        return true
    }

    /// Whisper also emits unicode music symbols (♪ ♫ ♩ ♬ etc.) for purely
    /// musical passages — strip those so the presenter doesn't show them.
    static func stripNonLyricMarks(_ text: String) -> String {
        let symbols: Set<Character> = ["♪", "♫", "♩", "♬", "♭", "♮", "♯", "𝄞"]
        let filtered = String(text.unicodeScalars.filter { scalar in
            if let c = Character(String(scalar)) as Character?, symbols.contains(c) { return false }
            return true
        })
        return filtered.trimmingCharacters(in: .whitespaces)
    }
}

/// Collects each lyric row's measured height, keyed by segment id. The
/// presenter needs real heights (not a fixed `rowHeight`) because long lines
/// wrap to 2+ visual rows and we still need the VStack's `y` offset to land
/// on the correct segment.
private struct LineHeightsKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat],
                       nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

private struct LyricsDisplayView: View {
    @ObservedObject var state: PresenterState
    @State private var lineHeights: [UUID: CGFloat] = [:]

    private let lineFontSize: CGFloat = 72
    /// Fallback height used before a row has been measured (first layout).
    private let fallbackRowHeight: CGFloat = 140
    private let lineSpacing: CGFloat = 30

    private var lineFont: Font {
        .system(size: lineFontSize, weight: .bold, design: .rounded)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                // All lines live in one VStack and the whole stack slides up
                // as a single rigid body on line transitions. Each row sizes
                // itself to its wrapped-text height and reports it back via
                // `LineHeightsKey`.
                VStack(spacing: lineSpacing) {
                    ForEach(Array(state.visibleSegments.enumerated()), id: \.element.id) { i, seg in
                        lineView(seg, at: i)
                            .frame(width: max(200, geo.size.width - 120))
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: LineHeightsKey.self,
                                        value: [seg.id: proxy.size.height]
                                    )
                                }
                            )
                            .opacity(opacity(for: i))
                    }
                }
                .frame(width: geo.size.width, alignment: .top)
                .offset(y: stackOffset(in: geo))
            }
            .clipped()
            .onPreferenceChange(LineHeightsKey.self) { heights in
                lineHeights = heights
            }
        }
        .ignoresSafeArea()
        // 0.25s is short enough that a line preceded by silence is fully
        // visible for most of the 1-second `leadTime` buffer (≈0.75 s
        // fully-opaque before the singer needs to read it), while still
        // smooth enough that mid-song line-to-line scroll transitions don't
        // feel jumpy.
        .animation(.easeInOut(duration: 0.25), value: state.topIndex)
    }

    /// Vertical offset for the full VStack of lines such that
    /// `visibleSegments[topIndex]` (or index 0 before the first transition)
    /// sits at roughly 38 % of the screen height. Heights above the anchor
    /// are summed from the measured `lineHeights` map; any row not yet
    /// measured falls back to `fallbackRowHeight`.
    private func stackOffset(in geo: GeometryProxy) -> CGFloat {
        let anchor = geo.size.height * 0.38
        let ref = max(0, state.topIndex)
        var consumed: CGFloat = 0
        let segs = state.visibleSegments
        let upper = min(ref, segs.count)
        for i in 0..<upper {
            let id = segs[i].id
            consumed += (lineHeights[id] ?? fallbackRowHeight) + lineSpacing
        }
        return anchor - consumed
    }

    /// Current line renders in full white; the upcoming line is dimmer.
    /// `Text` wraps naturally at the row's fixed width, so lines longer than
    /// one screen width flow to multiple visual rows.
    /// The parent's 0.45s animation governs line transitions as a rigid body.
    private func lineView(_ seg: LyricSegment, at i: Int) -> some View {
        let isCurrent = (i == state.topIndex)
        let color: Color = isCurrent ? .white : .white.opacity(0.55)
        return Text(seg.text)
            .font(lineFont)
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Only the top line and its successor are fully visible; everything
    /// else is off-screen conceptually (opacity 0).
    private func opacity(for i: Int) -> Double {
        guard state.topIndex >= 0 else { return 0 }
        if i == state.topIndex || i == state.topIndex + 1 { return 1 }
        return 0
    }
}
