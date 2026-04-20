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

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak engine] _ in
            guard let engine = engine else { return }
            let t = engine.currentTime(for: item.id) ?? 0
            DispatchQueue.main.async {
                state.update(time: t, doc: lyrics)
            }
        }
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
    }

    static func hideAll() {
        for id in Array(sessions.keys) { hide(itemID: id) }
    }
}

/// Observable state shared with the SwiftUI view.
final class PresenterState: ObservableObject {
    @Published var currentText: String = ""
    @Published var nextText: String = ""
    @Published var words: [LyricWord] = []
    @Published var currentTime: Double = 0

    func update(time: Double, doc: LyricsDocument) {
        self.currentTime = time
        if let idx = doc.currentOrUpcomingSegmentIndex(at: time) {
            let seg = doc.segments[idx]
            // If we're before the segment starts, show it as upcoming only
            if time < seg.start {
                currentText = ""
                nextText = seg.text
                words = []
            } else {
                currentText = seg.text
                nextText = idx + 1 < doc.segments.count ? doc.segments[idx + 1].text : ""
                words = seg.words
            }
        } else {
            currentText = ""
            nextText = ""
            words = []
        }
    }
}

private struct LyricsDisplayView: View {
    @ObservedObject var state: PresenterState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                if state.words.isEmpty {
                    Text(state.currentText)
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else {
                    wordHighlightedLine
                }
                Text(state.nextText)
                    .font(.system(size: 48, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            .padding(.horizontal, 80)
        }
    }

    /// Lays out words with the currently-sung one highlighted in accent color
    /// and already-passed words dimmer.
    private var wordHighlightedLine: some View {
        WrappingHStack(state.words, spacing: 18, lineSpacing: 18) { word in
            let isPast = state.currentTime >= word.end
            let isNow = state.currentTime >= word.start && state.currentTime < word.end
            Text(word.text)
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundColor(isNow ? .yellow : (isPast ? .white.opacity(0.85) : .white.opacity(0.35)))
                .animation(.easeOut(duration: 0.08), value: isNow)
        }
    }
}

/// Tiny flow layout so words wrap naturally on large screens.
private struct WrappingHStack<Data: RandomAccessCollection, Content: View>: View
where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 12, lineSpacing: CGFloat = 12,
         @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: lineSpacing) {
            ForEach(Array(data), id: \.self) { element in
                content(element)
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
