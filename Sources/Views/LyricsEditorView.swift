import SwiftUI
import AVFoundation
import AppKit

/// Identifier we stamp on the editor's NSWindow. `AppDelegate`'s local key
/// monitor and the editor's own local monitor both use it to route spacebar,
/// arrow keys, and ⌘S to whichever window is frontmost.
let lyricsEditorWindowIdentifier = "com.avlistplayer.lyrics-editor"

// MARK: - Window controller

/// Opens the lyrics editor in a standalone resizable NSWindow. A SwiftUI
/// `.sheet` centers on the parent and resizes symmetrically from the center
/// (corner-drags "expanding both ways" is the symptom). A plain NSWindow
/// gets normal corner-anchored resize behavior for free, plus a real title
/// bar, minimize / zoom, and a spot in the Window menu.
@MainActor
enum LyricsEditorWindow {
    private static var controller: NSWindowController?

    /// Opens the editor for `filePath`. Calling again for the same file
    /// re-focuses the existing window; calling for a different file closes
    /// the old one and opens a fresh editor, so stale state from the
    /// previous song never lingers.
    static func show(filePath: String, doc: LyricsDocument, beats: [Double], title: String) {
        if let existing = controller?.window {
            if let hosting = existing.contentViewController as? NSHostingController<LyricsEditorView>,
               hosting.rootView.filePath == filePath {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            close()
        }

        let view = LyricsEditorView(
            filePath: filePath,
            doc: doc,
            beats: beats,
            title: title,
            onClose: { close() }
        )
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Lyrics Editor — \(title)"
        window.identifier = NSUserInterfaceItemIdentifier(lyricsEditorWindowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 560))
        window.minSize = NSSize(width: 720, height: 440)

        // Mirror the main app's light/dark setting on first show. SwiftUI's
        // `.preferredColorScheme` inside the hosted view keeps it in sync if
        // the user toggles while the editor is open.
        let isDark = UserDefaults.standard.object(forKey: "darkMode") as? Bool ?? true
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        window.center()
        window.isReleasedWhenClosed = false

        let c = NSWindowController(window: window)
        controller = c

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in controller = nil }
        }

        c.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        controller?.window?.close()
        controller = nil
    }
}

// MARK: - Drag kind (shared between model & view)

enum LyricsDragKind { case move, leftEdge, rightEdge }

// MARK: - Model

@MainActor
final class LyricsEditorModel: ObservableObject {
    @Published var doc: LyricsDocument
    @Published var currentTime: Double = 0
    @Published var isPlaying: Bool = false
    @Published var selectedSegmentID: UUID? = nil
    @Published var waveform: WaveformData? = nil
    /// True iff the in-memory `doc` differs from what was last persisted to
    /// the sidecar. Drives the Save button's enabled state and styling; on
    /// window-close without saving the edits are dropped per the user's
    /// requirement.
    @Published var hasUnsavedChanges: Bool = false

    let filePath: String
    let beats: [Double]
    let duration: Double

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Snapshot of neighbor state captured at drag start. Used by
    /// retain-order drags so neighbor pushes are relative to where things
    /// were when the drag began, not where they've ended up mid-drag.
    private var dragContext: DragContext?
    private struct DragContext {
        let segmentID: UUID
        let originalStart: Double
        let originalEnd: Double
        let retainOrder: Bool
        let prev: NeighborSnapshot?
        let next: NeighborSnapshot?
    }
    private struct NeighborSnapshot {
        let id: UUID
        let originalStart: Double
        let originalEnd: Double
        /// True iff the neighbor wasn't already overlapping our segment at
        /// drag start. Pre-existing overlaps disconnect the neighbor for the
        /// duration of the drag — we don't try to "fix" them by pulling the
        /// neighbor along, because that would yank it unexpectedly the
        /// moment the user grabs a rectangle that happens to overlap. The
        /// user can fix overlaps by dragging each one manually with
        /// retain-order off, then re-enable.
        let connected: Bool
    }

    init(filePath: String, doc: LyricsDocument, beats: [Double]) {
        self.filePath = filePath
        self.doc = doc
        self.beats = beats

        let url = URL(fileURLWithPath: filePath)
        let p = try? AVAudioPlayer(contentsOf: url)
        p?.prepareToPlay()
        self.player = p
        self.duration = p?.duration ?? 0

        if let cached = WaveformCache.shared.get(for: filePath) {
            self.waveform = cached
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let wf = WaveformGenerator.generate(from: url, sampleCount: 1200)
                DispatchQueue.main.async { [weak self] in
                    if let wf { WaveformCache.shared.set(wf, for: filePath) }
                    self?.waveform = wf
                }
            }
        }
    }

    // MARK: - Transport

    func togglePlay() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            timer?.invalidate()
            timer = nil
        } else {
            if currentTime >= duration - 0.05 { currentTime = 0 }
            p.currentTime = currentTime
            p.play()
            isPlaying = true
            let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard let pl = self.player else { return }
                    if !pl.isPlaying {
                        self.isPlaying = false
                        self.timer?.invalidate()
                        self.timer = nil
                        return
                    }
                    self.currentTime = pl.currentTime
                    self.syncSelectionToPlayhead()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func seek(to time: Double) {
        let t = max(0, min(time, duration))
        currentTime = t
        player?.currentTime = t
        syncSelectionToPlayhead()
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    /// Move the selection to match what the karaoke presenter would show:
    /// the lyric with the largest `start` that's `<= currentTime`. Once a
    /// lyric begins, it stays selected even past its own `end`, until a
    /// later lyric's `start` arrives — and overlapping lyrics resolve to
    /// whichever started most recently. Selection stays nil before the
    /// very first lyric.
    private func syncSelectionToPlayhead() {
        var newID: UUID? = nil
        var bestStart: Double = -.infinity
        for seg in doc.segments where seg.start <= currentTime {
            if seg.start > bestStart {
                bestStart = seg.start
                newID = seg.id
            }
        }
        if newID != selectedSegmentID { selectedSegmentID = newID }
    }

    // MARK: - Snap

    func snap(_ time: Double, mode: SnapMode) -> Double {
        let anchors: [Double]
        switch mode {
        case .off:     return time
        case .beat:    anchors = beats
        case .measure: anchors = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        }
        guard !anchors.isEmpty else { return time }
        var lo = 0, hi = anchors.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if anchors[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        let after = anchors[lo]
        let before = lo > 0 ? anchors[lo - 1] : after
        return (time - before) <= (after - time) ? before : after
    }

    // MARK: - Mutations (no auto-save — the editor is explicit-save now)

    func addAtPlayhead() {
        let start = currentTime
        let defaultDur = 2.0
        let end = min(duration, start + defaultDur)
        guard end > start + 0.1 else { return }
        let seg = LyricSegment(text: "New lyric", start: start, end: end)
        doc.segments.append(seg)
        doc.segments.sort { $0.start < $1.start }
        selectedSegmentID = seg.id
        markDirty()
    }

    func deleteSelected() {
        guard let id = selectedSegmentID else { return }
        doc.segments.removeAll { $0.id == id }
        selectedSegmentID = nil
        markDirty()
    }

    func updateSegmentText(id: UUID, text: String) {
        guard let i = doc.segments.firstIndex(where: { $0.id == id }) else { return }
        guard doc.segments[i].text != text else { return }
        doc.segments[i].text = text
        markDirty()
    }

    /// Shift the whole [start, end] of the selected lyric by `delta` seconds,
    /// preserving duration. Used by left/right arrow keys. Retain-order is
    /// honored when enabled — neighbors can be pushed / pulled in the same
    /// way as a drag.
    func nudgeSelected(by delta: Double, retainOrder: Bool) {
        guard let id = selectedSegmentID,
              let i = doc.segments.firstIndex(where: { $0.id == id }) else { return }
        beginDrag(segmentID: id, retainOrder: retainOrder)
        let ctx = dragContext!
        let dur = ctx.originalEnd - ctx.originalStart
        let targetStart = ctx.originalStart + delta
        let (ns, ne) = clampAndPush(kind: .move,
                                    desiredStart: targetStart,
                                    desiredEnd: targetStart + dur,
                                    duration: dur,
                                    ctx: ctx)
        doc.segments[i].start = ns
        doc.segments[i].end = ne
        applyNeighborPush(ns: ns, ne: ne, ctx: ctx)
        endDrag()
    }

    // MARK: - Drag lifecycle

    /// Called by a segment-rectangle gesture on first onChanged. Captures
    /// neighbor state and settings for the drag so subsequent moves can push
    /// neighbors relative to where they started.
    func beginDrag(segmentID id: UUID, retainOrder: Bool) {
        guard let i = doc.segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = doc.segments[i]

        // Neighbors in time order. `doc.segments` is sorted-by-start after
        // the last commit, so adjacent indices are the right place to look.
        let prev: NeighborSnapshot? = i > 0 ? {
            let p = doc.segments[i - 1]
            return NeighborSnapshot(
                id: p.id,
                originalStart: p.start,
                originalEnd: p.end,
                connected: p.end <= seg.start + 0.001
            )
        }() : nil
        let next: NeighborSnapshot? = i + 1 < doc.segments.count ? {
            let n = doc.segments[i + 1]
            return NeighborSnapshot(
                id: n.id,
                originalStart: n.start,
                originalEnd: n.end,
                connected: n.start >= seg.end - 0.001
            )
        }() : nil

        dragContext = DragContext(
            segmentID: id,
            originalStart: seg.start,
            originalEnd: seg.end,
            retainOrder: retainOrder,
            prev: prev,
            next: next
        )
    }

    /// Apply a drag update during an ongoing drag. `translationSeconds` is
    /// the cumulative cursor translation since drag start, already converted
    /// from pixels to seconds by the caller. The model clamps / snaps /
    /// pushes neighbors per retain-order.
    func updateDrag(kind: LyricsDragKind,
                    translationSeconds dt: Double,
                    snapMode: SnapMode) {
        guard let ctx = dragContext,
              let i = doc.segments.firstIndex(where: { $0.id == ctx.segmentID }) else { return }

        let dur = ctx.originalEnd - ctx.originalStart

        // Compute desired new range purely from the translation.
        var desiredStart = ctx.originalStart
        var desiredEnd = ctx.originalEnd
        switch kind {
        case .move:
            desiredStart = ctx.originalStart + dt
            desiredEnd = ctx.originalEnd + dt
        case .leftEdge:
            desiredStart = ctx.originalStart + dt
        case .rightEdge:
            desiredEnd = ctx.originalEnd + dt
        }

        // Snap the driving boundary, keeping duration for move-kind.
        switch kind {
        case .move:
            let snapped = snap(desiredStart, mode: snapMode)
            desiredStart = snapped
            desiredEnd = snapped + dur
        case .leftEdge:
            desiredStart = snap(desiredStart, mode: snapMode)
        case .rightEdge:
            desiredEnd = snap(desiredEnd, mode: snapMode)
        }

        let (ns, ne) = clampAndPush(kind: kind,
                                    desiredStart: desiredStart,
                                    desiredEnd: desiredEnd,
                                    duration: dur,
                                    ctx: ctx)

        doc.segments[i].start = ns
        doc.segments[i].end = ne
        applyNeighborPush(ns: ns, ne: ne, ctx: ctx)
    }

    func endDrag() {
        dragContext = nil
        // Sort so adjacent indices remain meaningful for the next drag.
        doc.segments.sort { $0.start < $1.start }
        markDirty()
    }

    // MARK: - Retain-order math

    /// Clamp the desired start/end to retain-order constraints (if enabled)
    /// and audio bounds, without pushing neighbors yet. Pushing happens in
    /// `applyNeighborPush`.
    private func clampAndPush(kind: LyricsDragKind,
                              desiredStart: Double,
                              desiredEnd: Double,
                              duration dur: Double,
                              ctx: DragContext) -> (Double, Double) {
        var ns = desiredStart
        var ne = desiredEnd

        // Left-side constraint.
        if ctx.retainOrder, let prev = ctx.prev, prev.connected {
            // We can push prev.end as far left as prev.originalStart + 0.1,
            // so our seg's start can't go any further than that either.
            let minStart = prev.originalStart + 0.1
            if kind == .move {
                ns = max(minStart, ns)
                ne = ns + dur
            } else if kind == .leftEdge {
                ns = max(minStart, ns)
            }
        } else {
            if kind == .move {
                ns = max(0, ns)
                ne = ns + dur
            } else if kind == .leftEdge {
                ns = max(0, ns)
            }
        }

        // Right-side constraint.
        if ctx.retainOrder, let next = ctx.next, next.connected {
            let maxEnd = next.originalEnd - 0.1
            if kind == .move {
                ne = min(maxEnd, ne)
                ns = ne - dur
            } else if kind == .rightEdge {
                ne = min(maxEnd, ne)
            }
        } else {
            if kind == .move {
                ne = min(self.duration, ne)
                ns = ne - dur
            } else if kind == .rightEdge {
                ne = min(self.duration, ne)
            }
        }

        // Keep at least 0.1s of duration on every kind.
        switch kind {
        case .move:
            // Both bounds already enforced against each other via dur.
            break
        case .leftEdge:
            ns = min(ns, ne - 0.1)
        case .rightEdge:
            ne = max(ne, ns + 0.1)
        }

        return (ns, ne)
    }

    /// Push connected neighbors to follow `ns` / `ne`. Connected prev.end
    /// drops to ns when we cross into it (and lengthens back up to its
    /// original end when we move away). Same logic mirrored for next.start.
    private func applyNeighborPush(ns: Double, ne: Double, ctx: DragContext) {
        guard ctx.retainOrder else { return }

        if let prev = ctx.prev, prev.connected,
           let pi = doc.segments.firstIndex(where: { $0.id == prev.id }) {
            let newEnd = max(prev.originalStart + 0.1, min(ns, prev.originalEnd))
            doc.segments[pi].end = newEnd
        }
        if let next = ctx.next, next.connected,
           let ni = doc.segments.firstIndex(where: { $0.id == next.id }) {
            let newStart = min(next.originalEnd - 0.1, max(ne, next.originalStart))
            doc.segments[ni].start = newStart
        }
    }

    // MARK: - Save

    private func markDirty() { hasUnsavedChanges = true }

    /// Persist the current in-memory doc to the sidecar. Called by the Save
    /// button and ⌘S. Explicit — changes are otherwise in-memory only.
    func save() {
        LyricsStore.shared.save(doc, for: filePath)
        hasUnsavedChanges = false
    }
}

// MARK: - View

struct LyricsEditorView: View {
    @StateObject private var model: LyricsEditorModel
    let filePath: String
    let title: String
    let onClose: () -> Void

    @AppStorage("snapMode") private var snapModeRaw: String = SnapMode.measure.rawValue
    @AppStorage("darkMode") private var darkMode: Bool = true
    @AppStorage("lyricsEditor.retainOrder") private var retainOrder: Bool = false
    /// Horizontal zoom factor for the timeline. 1.0 = fit-to-width (no
    /// scrolling needed); higher values widen the content and let the user
    /// scroll. Persisted across sessions because the right zoom for, say,
    /// per-syllable nudging tends to be the same every time.
    @AppStorage("lyricsEditor.zoom") private var zoom: Double = 1.0
    private static let minZoom: Double = 1.0
    private static let maxZoom: Double = 60.0
    private var snapMode: SnapMode { SnapMode(rawValue: snapModeRaw) ?? .measure }

    @State private var keyMonitor: Any?

    init(filePath: String, doc: LyricsDocument, beats: [Double], title: String,
         onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: LyricsEditorModel(filePath: filePath, doc: doc, beats: beats))
        self.filePath = filePath
        self.title = title
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            selectedLyricPanel
            TimelineView(
                model: model,
                snapMode: snapMode,
                retainOrder: retainOrder,
                zoom: $zoom,
                minZoom: Self.minZoom,
                maxZoom: Self.maxZoom
            )
            .padding(.horizontal, 14)
            .padding(.top, 4)
            transport
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .preferredColorScheme(darkMode ? .dark : .light)
        .onAppear { installKeyMonitor() }
        .onDisappear {
            removeKeyMonitor()
            model.stop()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: { model.addAtPlayhead() }) {
                Label("Add Lyric", systemImage: "plus")
            }
            .help("Add a new lyric line starting at the playhead")

            Toggle(isOn: $retainOrder) {
                Text("Retain lyric order")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .help("When on, moving or resizing a lyric shortens and lengthens its neighbors so order is preserved. Overlaps that already exist at drag start are left alone.")

            Spacer()

            zoomControls

            // Click-to-cycle toggle — same control as the track tab.
            Button(action: { snapModeRaw = snapMode.next().rawValue }) {
                Text(snapMode.label)
                    .font(.caption2)
                    .foregroundColor(snapMode == .off ? .secondary : .accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill((snapMode == .off ? Color.secondary : Color.accentColor).opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Click to cycle: measure → beat → off")

            Button(action: { model.save() }) {
                Label(model.hasUnsavedChanges ? "Save*" : "Save",
                      systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: .command)
            .help(model.hasUnsavedChanges
                  ? "Save changes to disk (⌘S). Closing the window without saving loses them."
                  : "No unsaved changes.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Selected lyric panel

    /// The only editor surface for a single lyric. Shows timecodes, text
    /// (click-to-edit), and delete. When nothing is selected the panel
    /// renders an empty stub of the same height so the timeline below
    /// doesn't jump vertically as the playhead moves in and out of lyrics.
    @ViewBuilder
    private var selectedLyricPanel: some View {
        if let id = model.selectedSegmentID,
           let idx = model.doc.segments.firstIndex(where: { $0.id == id }) {
            let seg = model.doc.segments[idx]
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(timeRange(seg))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        model.deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this lyric")
                }
                EditableLyricText(
                    text: seg.text,
                    onCommit: { model.updateSegmentText(id: id, text: $0) }
                )
                .id(seg.id)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .background(Color.yellow.opacity(0.10))
        } else {
            // No text — just hold the vertical space so the timeline
            // doesn't shift up/down as the playhead enters/exits lyrics.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func timeRange(_ seg: LyricSegment) -> String {
        "\(formatTime(seg.start)) → \(formatTime(seg.end))"
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 10) {
            Button(action: { model.togglePlay() }) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .help("Play / Pause (Space)")

            Text(formatTime(model.currentTime))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 70, alignment: .trailing)

            Slider(value: Binding(
                get: { model.currentTime },
                set: { model.seek(to: $0) }
            ), in: 0...(max(model.duration, 0.01)))

            Text(formatTime(model.duration))
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
        }
    }

    // MARK: Zoom controls

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button(action: zoomOut) {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(zoom <= Self.minZoom + 0.001)
            .help("Zoom out (⌘−)")

            Button(action: { zoom = 1.0 }) {
                Text(String(format: "%.0f%%", zoom * 100))
                    .font(.caption2)
                    .frame(minWidth: 38)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Fit to width (⌘0)")

            Button(action: zoomIn) {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(zoom >= Self.maxZoom - 0.001)
            .help("Zoom in (⌘+)")
        }
    }

    private func zoomIn() {
        zoom = min(Self.maxZoom, zoom * 1.5)
    }

    private func zoomOut() {
        zoom = max(Self.minZoom, zoom / 1.5)
    }

    private func formatTime(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    // MARK: Key handling

    /// Owns spacebar (play/pause) and left/right arrows (nudge selected
    /// lyric by 0.1 s — or 1 s with Shift). `AppDelegate`'s global monitor
    /// checks `event.window?.identifier` and bails out for this window, so
    /// the playlist doesn't also fire.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard ev.window?.identifier?.rawValue == lyricsEditorWindowIdentifier else {
                return ev
            }
            // Never steal keys from an active text editor — they belong to
            // cursor movement / text input.
            if let resp = ev.window?.firstResponder, resp is NSTextView {
                return ev
            }
            let shift = ev.modifierFlags.contains(.shift)
            switch ev.keyCode {
            case 49: // spacebar
                model.togglePlay()
                return nil
            case 123: // left arrow
                model.nudgeSelected(by: shift ? -1.0 : -0.1, retainOrder: retainOrder)
                return nil
            case 124: // right arrow
                model.nudgeSelected(by: shift ? 1.0 : 0.1, retainOrder: retainOrder)
                return nil
            default:
                return ev
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Timeline

private struct TimelineView: View {
    @ObservedObject var model: LyricsEditorModel
    let snapMode: SnapMode
    let retainOrder: Bool
    @Binding var zoom: Double
    let minZoom: Double
    let maxZoom: Double

    /// Captured at the start of a trackpad pinch so subsequent
    /// `MagnifyGesture` updates can multiply against a stable baseline,
    /// instead of compounding zoom on each tick.
    @State private var pinchBaseZoom: Double? = nil

    /// Owned horizontal scroll offset (pixels). Updated together with
    /// `zoom` in `.onChange(of: zoom)` so the new pxPerSecond and the
    /// scroll position land in the same SwiftUI render frame —
    /// previously a SwiftUI `ScrollView` only caught up its scroll a
    /// frame later, which made the waveform appear to drift during a
    /// pinch even though the final zoom was correct.
    @State private var scrollOffset: CGFloat = 0

    /// Captured exactly once per pinch — at the gesture's first
    /// onChanged using `value.startLocation`. Button-driven zooms
    /// (⌘+/⌘−/⌘0) leave this nil and the `.onChange` handler falls back
    /// to viewport center. Cleared in `MagnifyGesture.onEnded`.
    @State private var zoomAnchor: ZoomAnchor? = nil
    private struct ZoomAnchor {
        let viewportX: CGFloat
        let time: Double
    }

    /// Playhead's viewport x captured at pinch start. While set, we
    /// render a "frozen" copy of the playhead outside the scrolling
    /// content at this fixed x and hide the in-content playhead — so
    /// the playhead visually doesn't move during the pinch even though
    /// the zoom is anchored on the cursor (which can be elsewhere).
    /// Cleared on `onEnded`; the in-content playhead reappears at its
    /// correct post-zoom position.
    @State private var pinchFrozenPlayheadX: CGFloat? = nil

    /// Named coordinate space anchored to the non-moving timeline container.
    /// The `SegmentRectangle`s position themselves with `.offset()`, which
    /// shifts their local coordinate space with them; measuring a
    /// `DragGesture`'s translation against their local space therefore drifts
    /// (the classic "rectangle jitters / snaps back" bug). Pinning the
    /// gesture's coordinate space to this name keeps translations stable
    /// regardless of where the rectangle has moved.
    private static let coordSpaceName = "lyrics-editor-timeline"

    private let waveformHeight: CGFloat = 240
    private let laneHeight: CGFloat = 56
    private let laneGap: CGFloat = 4
    private let rectanglesTopPadding: CGFloat = 6

    var body: some View {
        // Lane count and the resulting rectangle-row height depend only on
        // the segment timings, not on the available width — so we compute
        // them outside the GeometryReader and use them to set an explicit
        // outer frame height. Without this, the GeometryReader (which
        // always fills its proposed space) and the VStack inside it
        // disagreed about size whenever the rectangle row grew past the
        // single-lane default — content spilled past the bottom edge and
        // overlapped the transport row.
        let lanes = assignLanes(model.doc.segments)
        let laneCount = max(1, (lanes.values.max() ?? 0) + 1)
        let rectRowHeight = CGFloat(laneCount) * laneHeight
            + CGFloat(max(0, laneCount - 1)) * laneGap
            + rectanglesTopPadding * 2
        let interRowGap: CGFloat = 4
        let totalHeight = waveformHeight + interRowGap + rectRowHeight

        return GeometryReader { geo in
            // The viewport is the visible width on screen. Content width =
            // viewport × zoom, so zoom = 1 fits the song to the viewport
            // (no scrolling needed) and higher zoom widens the content,
            // engaging the horizontal scroller.
            let viewportWidth = geo.size.width
            let duration = max(model.duration, 0.01)
            let contentWidth = viewportWidth * CGFloat(zoom)
            let pxPerSecond = contentWidth / CGFloat(duration)

            AtomicHorizontalScrollView(
                contentWidth: contentWidth,
                contentHeight: totalHeight,
                scrollOffset: $scrollOffset
            ) {
                VStack(alignment: .leading, spacing: interRowGap) {
                    waveformRow(width: contentWidth, duration: duration)
                        .frame(width: contentWidth, height: waveformHeight)

                    rectangleRow(
                        width: contentWidth,
                        duration: duration,
                        pxPerSecond: pxPerSecond,
                        lanes: lanes,
                        laneCount: laneCount
                    )
                    .frame(width: contentWidth, height: rectRowHeight)
                }
                .coordinateSpace(name: Self.coordSpaceName)
                .overlay(alignment: .topLeading) {
                    // In-content playhead. Hidden during a pinch so the
                    // outer "frozen" copy below can hold the playhead's
                    // visual position constant while the rest of the
                    // timeline rescales around the cursor.
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 1.5, height: totalHeight)
                        .offset(x: CGFloat(model.currentTime) * pxPerSecond)
                        .opacity(pinchFrozenPlayheadX == nil ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            // Frozen playhead — only present during a pinch. Sits
            // outside the scrolling content at the viewport x captured
            // when the gesture started, so it appears not to move while
            // the user pinches.
            .overlay(alignment: .topLeading) {
                if let frozenX = pinchFrozenPlayheadX {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 1.5, height: totalHeight)
                        .offset(x: frozenX)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: zoom) { oldZoom, newZoom in
                // Pinch anchors on the cursor (captured once at gesture
                // start). Button-driven zooms anchor on viewport center —
                // they fire from the toolbar / a keyboard shortcut where
                // the cursor isn't necessarily over the timeline, and
                // center is the predictable choice.
                //
                // Updating `scrollOffset` here together with `zoom`
                // lets `AtomicHorizontalScrollView` resize the document
                // view and set the scroll position in the same
                // `updateNSView` call, eliminating the one-frame "scroll
                // catches up later" gap that previously made the
                // waveform drift mid-pinch.
                let anchor = zoomAnchor ?? captureAnchor(
                    atViewportX: viewportWidth / 2,
                    viewportWidth: viewportWidth,
                    oldZoom: oldZoom,
                    duration: duration
                )
                let newPxPerSec = (viewportWidth * CGFloat(newZoom)) / CGFloat(duration)
                let newScroll = CGFloat(anchor.time) * newPxPerSec - anchor.viewportX
                let newContentWidth = viewportWidth * CGFloat(newZoom)
                let maxScroll = max(0, newContentWidth - viewportWidth)
                scrollOffset = max(0, min(maxScroll, newScroll))
            }
            // Pinch-to-zoom. Captures the cursor anchor once on the
            // gesture's first onChanged from `value.startLocation` (in
            // local coords = viewport coords, since the gesture is
            // attached to the viewport). Subsequent ticks only mutate
            // `zoom`; the anchor stays put until onEnded.
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .onChanged { value in
                        if pinchBaseZoom == nil {
                            pinchBaseZoom = zoom
                            zoomAnchor = captureAnchor(
                                atViewportX: value.startLocation.x,
                                viewportWidth: viewportWidth,
                                oldZoom: zoom,
                                duration: duration
                            )
                            // Snapshot the playhead's current viewport x
                            // so the outer "frozen" copy can hold it
                            // there for the whole pinch.
                            let oldPxPerSec = (viewportWidth * CGFloat(zoom)) / CGFloat(duration)
                            pinchFrozenPlayheadX = CGFloat(model.currentTime) * oldPxPerSec - scrollOffset
                        }
                        let base = pinchBaseZoom ?? zoom
                        let target = base * Double(value.magnification)
                        zoom = max(minZoom, min(maxZoom, target))
                    }
                    .onEnded { _ in
                        pinchBaseZoom = nil
                        zoomAnchor = nil
                        pinchFrozenPlayheadX = nil
                    }
            )
        }
        .frame(height: totalHeight)
    }

    /// Build a zoom anchor from a viewport x. Resolves the time at that
    /// x using `oldZoom`'s pxPerSecond, so the anchor reflects the spot
    /// the user is pointing at *before* the zoom shifts the layout.
    private func captureAnchor(atViewportX vx: CGFloat,
                               viewportWidth: CGFloat,
                               oldZoom: Double,
                               duration: Double) -> ZoomAnchor {
        let oldPxPerSec = (viewportWidth * CGFloat(oldZoom)) / CGFloat(duration)
        let pxFromContentOrigin = scrollOffset + vx
        let time = oldPxPerSec > 0
            ? Double(pxFromContentOrigin / oldPxPerSec)
            : 0
        return ZoomAnchor(
            viewportX: max(0, min(viewportWidth, vx)),
            time: max(0, min(duration, time))
        )
    }

    private func waveformRow(width w: CGFloat, duration: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15))

            if let wf = model.waveform {
                StereoWaveformShape(samples: wf.leftSamples, gain: 1.0, flipped: false)
                    .fill(Color.blue.opacity(0.6))
                StereoWaveformShape(samples: wf.rightSamples, gain: 1.0, flipped: true)
                    .fill(Color.orange.opacity(0.6))
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let frac = max(0, min(1, v.location.x / w))
                    let t = model.snap(Double(frac) * duration, mode: snapMode)
                    model.seek(to: t)
                }
        )
    }

    private func rectangleRow(
        width w: CGFloat,
        duration: Double,
        pxPerSecond: CGFloat,
        lanes: [UUID: Int],
        laneCount: Int
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06))

            ForEach(model.doc.segments) { seg in
                let lane = lanes[seg.id] ?? 0
                SegmentRectangle(
                    segment: seg,
                    isSelected: model.selectedSegmentID == seg.id,
                    pxPerSecond: pxPerSecond,
                    y: rectanglesTopPadding + CGFloat(lane) * (laneHeight + laneGap),
                    height: laneHeight,
                    coordSpace: Self.coordSpaceName,
                    retainOrder: retainOrder,
                    snapMode: snapMode,
                    model: model,
                    onSelect: {
                        // Paused rectangle-click changes selection but
                        // leaves the playhead alone; the next play/seek
                        // re-syncs via syncSelectionToPlayhead().
                        model.selectedSegmentID = seg.id
                    }
                )
            }
        }
    }

    /// Greedy lane packing in *array order* so a single in-flight drag — which
    /// mutates a segment's range but never the array order — doesn't re-lane
    /// its neighbors. On `endDrag()` the model sorts; lanes repack naturally.
    private func assignLanes(_ segments: [LyricSegment]) -> [UUID: Int] {
        var lanes: [UUID: Int] = [:]
        var laneEnd: [Double] = []
        for seg in segments {
            if let i = laneEnd.firstIndex(where: { $0 <= seg.start + 0.001 }) {
                laneEnd[i] = seg.end
                lanes[seg.id] = i
            } else {
                lanes[seg.id] = laneEnd.count
                laneEnd.append(seg.end)
            }
        }
        return lanes
    }
}

/// Wraps an `NSScrollView` so the document view's frame size and the
/// scroll position can be updated atomically inside a single
/// `updateNSView` call. SwiftUI's own `ScrollView` doesn't expose its
/// scroll offset for direct setting, and `ScrollViewReader.scrollTo` only
/// dispatches on the next runloop — so a zoom that grew the content was
/// always visible for one frame at the new pxPerSecond *before* the scroll
/// caught up, making the waveform appear to drift during a pinch. With
/// this wrapper, `setFrameSize` and `contentView.scroll(to:)` happen back
/// to back on the main thread, so the visual update is in lockstep.
private struct AtomicHorizontalScrollView<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    @Binding var scrollOffset: CGFloat
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // We do our own zoom; don't let NSScrollView intercept pinches.
        scrollView.allowsMagnification = false

        let host = NSHostingView(rootView: AnyView(content()))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.setFrameSize(NSSize(width: contentWidth, height: contentHeight))
        scrollView.documentView = host

        let coord = context.coordinator
        coord.host = host
        coord.scrollView = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        coord.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coord] _ in
            coord?.handleScrollChanged()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coord = context.coordinator
        // Refresh the closure that pushes scroll changes back into the
        // SwiftUI binding — the parent recreates `scrollOffset`'s setter
        // on every body update, and capturing the original would let
        // updates miss after the first re-render.
        coord.onScrollChanged = { newOffset in
            DispatchQueue.main.async {
                if abs(scrollOffset - newOffset) > 0.1 {
                    scrollOffset = newOffset
                }
            }
        }

        guard let host = coord.host else { return }
        host.rootView = AnyView(content())

        let newSize = NSSize(width: contentWidth, height: contentHeight)
        if host.frame.size != newSize {
            host.setFrameSize(newSize)
        }

        let viewportW = scrollView.contentSize.width
        let maxOffset = max(0, contentWidth - viewportW)
        let targetX = max(0, min(maxOffset, scrollOffset))
        if abs(scrollView.contentView.bounds.origin.x - targetX) > 0.5 {
            // Suppress the boundsDidChange echo we're about to trigger so
            // it doesn't bounce back into the binding (the binding already
            // holds this value).
            coord.suppressNextScrollChange = true
            scrollView.contentView.scroll(to: NSPoint(x: targetX, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        var host: NSHostingView<AnyView>?
        var observer: Any?
        var onScrollChanged: ((CGFloat) -> Void)?
        var suppressNextScrollChange = false

        func handleScrollChanged() {
            if suppressNextScrollChange {
                suppressNextScrollChange = false
                return
            }
            guard let sv = scrollView else { return }
            onScrollChanged?(sv.contentView.bounds.origin.x)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - Segment rectangle

private struct SegmentRectangle: View {
    let segment: LyricSegment
    let isSelected: Bool
    let pxPerSecond: CGFloat
    let y: CGFloat
    let height: CGFloat
    let coordSpace: String
    let retainOrder: Bool
    let snapMode: SnapMode
    @ObservedObject var model: LyricsEditorModel
    let onSelect: () -> Void

    @State private var dragStarted: Bool = false

    private let edgeWidth: CGFloat = 6

    var body: some View {
        let x = CGFloat(segment.start) * pxPerSecond
        let width = max(8, CGFloat(segment.end - segment.start) * pxPerSecond)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.yellow.opacity(0.45) : Color.accentColor.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isSelected ? Color.yellow : Color.accentColor.opacity(0.55),
                                      lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: .leading) {
                    Text(segment.text)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .padding(.horizontal, edgeWidth + 3)
                        .foregroundColor(.primary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
                .gesture(dragGesture(.move))

            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: edgeWidth)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(.leftEdge))
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                Spacer()
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: edgeWidth)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(.rightEdge))
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
            }
            .frame(width: width)
        }
        .frame(width: width, height: height)
        .offset(x: x, y: y)
    }

    private func dragGesture(_ kind: LyricsDragKind) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .onChanged { val in
                if !dragStarted {
                    dragStarted = true
                    onSelect()
                    model.beginDrag(segmentID: segment.id, retainOrder: retainOrder)
                }
                let dt = Double(val.translation.width) / Double(pxPerSecond)
                model.updateDrag(kind: kind, translationSeconds: dt, snapMode: snapMode)
            }
            .onEnded { _ in
                dragStarted = false
                model.endDrag()
            }
    }
}

// MARK: - Editable lyric text

/// Click-to-edit large text display inside the selected-lyric panel.
private struct EditableLyricText: View {
    let text: String
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { revert() }
                    .onChange(of: focused) { _, f in
                        if !f && editing { commit() }
                    }
            } else {
                Text(text.isEmpty ? "(empty — click to edit)" : text)
                    .font(.title3)
                    .foregroundColor(text.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEditing() }
            }
        }
    }

    private func startEditing() {
        draft = text
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        let newValue = draft
        editing = false
        focused = false
        if newValue != text { onCommit(newValue) }
    }

    private func revert() {
        editing = false
        focused = false
    }
}
