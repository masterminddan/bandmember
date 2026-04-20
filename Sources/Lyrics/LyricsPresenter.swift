import SwiftUI
import AppKit
import Combine

/// Fullscreen karaoke-style lyric display. Creates a borderless black window
/// on the requested screen and renders the current line large + next line
/// smaller, with word-level highlighting. Driven by a timer that polls the
/// `PlaybackEngine` for the current playhead.
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
    /// How far ahead of the actual playhead we treat a line as "current". The
    /// two-line display already shows the upcoming line at the bottom, so this
    /// is 0 by default (scroll on segment start, not early).
    static let leadTime: Double = 0.0

    @Published var visibleSegments: [LyricSegment] = []
    /// Index into `visibleSegments` of the current (top) line, or -1 before
    /// any lyric has come up.
    @Published var topIndex: Int = -1
    /// Word-level timings for the current top line (used for per-word highlight).
    @Published var currentWords: [LyricWord] = []
    @Published var currentTime: Double = 0

    func setDocument(_ doc: LyricsDocument) {
        // Clean each segment's text and words of music symbols and drop any
        // segment that's left empty (pure-music passages).
        visibleSegments = doc.segments.compactMap { seg in
            let cleanedText = Self.stripNonLyricMarks(seg.text)
            guard Self.isLyric(cleanedText) else { return nil }
            let cleanedWords: [LyricWord] = seg.words.compactMap { w in
                let ct = Self.stripNonLyricMarks(w.text)
                guard !ct.isEmpty else { return nil }
                return LyricWord(text: ct, start: w.start, end: w.end)
            }
            return LyricSegment(id: seg.id, text: cleanedText,
                                start: seg.start, end: seg.end,
                                words: cleanedWords)
        }
        topIndex = -1
        currentWords = []
    }

    func update(time: Double) {
        self.currentTime = time
        let adjusted = time + Self.leadTime
        // Largest i such that visibleSegments[i].start <= adjusted.
        var newTop = -1
        for (i, seg) in visibleSegments.enumerated() {
            if seg.start <= adjusted { newTop = i } else { break }
        }
        if newTop != topIndex {
            topIndex = newTop
            if newTop >= 0 {
                currentWords = visibleSegments[newTop].words.filter { Self.isLyric($0.text) }
            } else {
                currentWords = []
            }
        }
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

private struct LyricsDisplayView: View {
    @ObservedObject var state: PresenterState

    private let lineFontSize: CGFloat = 72
    private let rowHeight: CGFloat = 140
    private let lineSpacing: CGFloat = 30

    private var lineFont: Font {
        .system(size: lineFontSize, weight: .bold, design: .rounded)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                // All lines live in one VStack and the whole stack slides up
                // as a single rigid body on line transitions — no per-word
                // jitter, because only the container's offset is animated.
                VStack(spacing: lineSpacing) {
                    ForEach(Array(state.visibleSegments.enumerated()), id: \.element.id) { i, seg in
                        lineView(seg, at: i)
                            .frame(width: max(200, geo.size.width - 120),
                                   height: rowHeight)
                            .opacity(opacity(for: i))
                    }
                }
                .frame(width: geo.size.width, alignment: .top)
                .offset(y: stackOffset(in: geo))
            }
            .clipped()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: state.topIndex)
    }

    /// Vertical offset for the full VStack of lines such that
    /// `visibleSegments[topIndex]` (or index 0 before the first transition)
    /// sits at roughly 38 % of the screen height.
    private func stackOffset(in geo: GeometryProxy) -> CGFloat {
        let anchor = geo.size.height * 0.38
        let ref = max(0, state.topIndex)
        return anchor - CGFloat(ref) * (rowHeight + lineSpacing)
    }

    /// Always returns the same view structure (a word-level flow layout), so
    /// SwiftUI preserves identity across transitions — only per-word colors
    /// change based on whether this line is the current one and whether each
    /// word has been sung yet. Color changes are NOT individually animated —
    /// the parent's 0.45s animation governs line transitions as a rigid body.
    private func lineView(_ seg: LyricSegment, at i: Int) -> some View {
        let words = seg.words.isEmpty
            ? [LyricWord(text: seg.text, start: seg.start, end: seg.end)]
            : seg.words
        let isCurrent = (i == state.topIndex)
        return WrappingHStack(words, spacing: 18, lineSpacing: 12) { word in
            let isPast = isCurrent && state.currentTime >= word.end
            let isNow  = isCurrent && state.currentTime >= word.start && state.currentTime < word.end
            let color: Color = {
                if isNow { return .yellow }
                if isPast { return .white }
                return isCurrent ? .white.opacity(0.7) : .white.opacity(0.85)
            }()
            Text(word.text)
                .font(lineFont)
                .foregroundColor(color)
        }
    }

    /// Only the top line and its successor are fully visible; everything
    /// else is off-screen conceptually (opacity 0).
    private func opacity(for i: Int) -> Double {
        guard state.topIndex >= 0 else { return 0 }
        if i == state.topIndex || i == state.topIndex + 1 { return 1 }
        return 0
    }
}

/// Tiny flow layout that wraps words naturally on large screens. Uses array
/// index as identity so repeated words ("la la la") each get their own slot.
private struct WrappingHStack<Content: View>: View {
    let words: [LyricWord]
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: (LyricWord) -> Content

    init(_ words: [LyricWord], spacing: CGFloat = 12, lineSpacing: CGFloat = 12,
         @ViewBuilder content: @escaping (LyricWord) -> Content) {
        self.words = words
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: lineSpacing) {
            ForEach(words.indices, id: \.self) { i in
                content(words[i])
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: min(maxWidth, totalWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        // First pass: compute total width of line and start offset to center-align
        struct PlacedLine { var items: [(Subviews.Element, CGSize)]; var width: CGFloat; var height: CGFloat }
        var lines: [PlacedLine] = []
        var currentLine = PlacedLine(items: [], width: 0, height: 0)
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if currentLine.width + (currentLine.items.isEmpty ? 0 : spacing) + size.width > maxWidth, !currentLine.items.isEmpty {
                lines.append(currentLine)
                currentLine = PlacedLine(items: [], width: 0, height: 0)
            }
            if !currentLine.items.isEmpty { currentLine.width += spacing }
            currentLine.items.append((sub, size))
            currentLine.width += size.width
            currentLine.height = max(currentLine.height, size.height)
        }
        if !currentLine.items.isEmpty { lines.append(currentLine) }

        for line in lines {
            let startX = bounds.minX + (maxWidth - line.width) / 2
            x = startX
            rowHeight = line.height
            for (sub, size) in line.items {
                sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
