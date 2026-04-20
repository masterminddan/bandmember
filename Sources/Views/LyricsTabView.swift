import SwiftUI
import AppKit

struct LyricsTabView: View {
    let itemIndex: Int
    let itemID: UUID

    @EnvironmentObject var store: PlaylistStore
    @EnvironmentObject var playbackEngine: PlaybackEngine
    @ObservedObject private var lyricsStore = LyricsStore.shared
    @ObservedObject private var transcriber = LyricsTranscriber.shared
    @ObservedObject private var models = ModelManager.shared

    @AppStorage("lyrics.preferredModel") private var preferredModel: String = "openai_whisper-small.en"
    @State private var showingModelSheet = false
    @State private var showingFixLyricsSheet = false
    @State private var fixLyricsDraft: String = ""

    private var item: PlaylistItem? { store.items[safe: itemIndex] }
    private var filePath: String { item?.filePath ?? "" }
    private var doc: LyricsDocument? {
        guard !filePath.isEmpty else { return nil }
        return lyricsStore.lyrics(for: filePath)
    }

    var body: some View {
        // Resolve `doc` once per body evaluation. The computed property calls
        // `lyricsStore.lyrics(for:)`, which stats the sidecar (and on the
        // first access decodes the JSON). Recomputing it from every subview
        // re-stats on every body pass.
        let resolvedDoc = doc
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if item?.mediaType != .audio {
                    unavailableBanner
                } else {
                    modelPickerRow
                    jobStatusRow(doc: resolvedDoc)
                    presenterControls(doc: resolvedDoc)
                    Divider()
                    segmentList(doc: resolvedDoc)
                    Spacer(minLength: 20)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingFixLyricsSheet) {
            FixLyricsSheet(
                pastedText: $fixLyricsDraft,
                isPresented: $showingFixLyricsSheet,
                onSubmit: { text in applyFixLyrics(text) }
            )
        }
    }

    // MARK: - Subviews

    private var unavailableBanner: some View {
        HStack {
            Image(systemName: "info.circle")
            Text("Lyrics are only available for audio tracks.")
                .font(.callout)
            Spacer()
        }
        .foregroundColor(.secondary)
        .padding()
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private var modelPickerRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model").font(.caption).foregroundColor(.secondary)
                Text(modelDisplayName(for: preferredModel))
                    .font(.callout)
                if models.isInstalled(preferredModel) {
                    Text("Installed").font(.caption2).foregroundColor(.green)
                } else {
                    Text("Not installed").font(.caption2).foregroundColor(.orange)
                }
            }
            Spacer()
            // Label reflects the primary action available: "Download…" when no
            // Whisper model is yet on disk (the only useful thing the popover
            // offers in that state); "Change…" once at least one model is
            // installed and the user can pick between them. The popover
            // itself still offers download for any model, so there's no
            // functionality lost either way.
            Button(models.installed.isEmpty ? "Download…" : "Change…") {
                showingModelSheet = true
            }
            .popover(isPresented: $showingModelSheet, arrowEdge: .top) {
                ModelPickerPopover(preferredModel: $preferredModel, isPresented: $showingModelSheet)
            }
        }
    }

    private func modelDisplayName(for id: String) -> String {
        ModelManager.catalog.first(where: { $0.id == id })?.displayName ?? id
    }

    @ViewBuilder
    private func jobStatusRow(doc: LyricsDocument?) -> some View {
        let state = transcriber.status(for: filePath)
        switch state {
        case .idle, .done:
            // Transcribe on top; Fix Lyrics beneath (only when lyrics exist).
            // Both stretch full-width so long labels like "Re-transcribe" fit
            // comfortably and the stack reads as a small primary/secondary
            // action group.
            VStack(spacing: 6) {
                Button(action: startTranscription) {
                    Label(doc == nil ? "Transcribe" : "Re-transcribe",
                          systemImage: "text.bubble.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(filePath.isEmpty || !FileManager.default.fileExists(atPath: filePath))

                if doc != nil {
                    Button(action: openFixLyricsSheet) {
                        Label("Fix Lyrics", systemImage: "pencil.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Paste corrected lyrics and re-apply the existing timestamps to them.")
                }
            }
        case .loadingModel:
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                Text("Loading model…").font(.callout).foregroundColor(.secondary)
                Spacer()
            }
        case .transcribing(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction).frame(maxWidth: 180)
                Text(String(format: "Transcribing… %.0f%%", fraction * 100))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        case .failed(let msg):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Failed: \(msg)").font(.caption).lineLimit(2)
                Button("Retry", action: startTranscription)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func presenterControls(doc: LyricsDocument?) -> some View {
        // Use `hasLyrics(for:)` — a pure `fileExists` probe — instead of
        // `lyrics(for:)`, which decodes the sidecar JSON. On first access
        // after launch the decode version synchronously reads every item's
        // sidecar on the main thread and hangs the UI.
        if doc != nil || store.items.contains(where: { $0.id != itemID && lyricsStore.hasLyrics(for: $0.filePath) }) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Toggle(isOn: Binding(
                    get: { item?.showLyrics ?? false },
                    set: { new in
                        guard itemIndex < store.items.count else { return }
                        store.pushUndo()
                        store.items[itemIndex].showLyrics = new
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text("Display lyrics when triggered")
                        Text("Opens a fullscreen lyric window on the target display when this item is played.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text("Target Display").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Picker("Display", selection: Binding(
                        get: { item?.targetDisplayIndex ?? 0 },
                        set: { newValue in
                            guard itemIndex < store.items.count else { return }
                            store.pushUndo()
                            store.items[itemIndex].targetDisplayIndex = newValue
                        }
                    )) {
                        Text("Main Display").tag(0)
                        Text("2nd Display").tag(1)
                    }
                    .labelsHidden()
                }
                if (item?.targetDisplayIndex ?? 0) == 1 && NSScreen.screens.count < 2 {
                    Text("2nd display not connected — lyrics will not be shown")
                        .font(.caption2).foregroundColor(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func segmentList(doc: LyricsDocument?) -> some View {
        if let doc = doc {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Lyrics").font(.headline)
                    // Created timestamp sits next to the section header now,
                    // keeping the Transcribe/Fix Lyrics button column clean.
                    Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        lyricsStore.delete(for: filePath)
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                ForEach(Array(doc.segments.enumerated()), id: \.element.id) { i, seg in
                    LyricSegmentRow(
                        segment: seg,
                        onChange: { newText in
                            var d = doc
                            d.segments[i].text = newText
                            lyricsStore.save(d, for: filePath)
                        },
                        onNudge: { delta in
                            var d = doc
                            guard i < d.segments.count else { return }

                            // Shift the current lyric's whole range by `delta`,
                            // preserving its duration.
                            d.segments[i].start = max(0, d.segments[i].start + delta)
                            d.segments[i].end = max(d.segments[i].start + 0.1,
                                                    d.segments[i].end + delta)

                            // Carry the adjacent boundary along so the gap (or
                            // lack of gap) with the neighbor is preserved. When
                            // nudging earlier, pull the previous lyric's end
                            // back; when nudging later, push the next lyric's
                            // start forward — clamping so neither neighbor
                            // collapses through its own start/end.
                            if delta < 0, i > 0 {
                                let minEnd = d.segments[i-1].start + 0.1
                                d.segments[i-1].end = max(minEnd,
                                                          d.segments[i-1].end + delta)
                            } else if delta > 0, i + 1 < d.segments.count {
                                let maxStart = d.segments[i+1].end - 0.1
                                d.segments[i+1].start = min(maxStart,
                                                            d.segments[i+1].start + delta)
                            }

                            lyricsStore.save(d, for: filePath)
                        },
                        onEditStart: { newStart in
                            var d = doc
                            guard i < d.segments.count else { return }
                            // Clamp into a valid range: non-negative and
                            // strictly before this lyric's end.
                            let clamped = max(0, min(newStart, d.segments[i].end - 0.1))
                            let delta = clamped - d.segments[i].start
                            d.segments[i].start = clamped
                            // Carry the previous lyric's end along by the same
                            // delta, like the ← nudge — preserves whatever
                            // gap/overlap existed before the edit.
                            if i > 0 {
                                let minEnd = d.segments[i-1].start + 0.1
                                d.segments[i-1].end = max(minEnd,
                                                          d.segments[i-1].end + delta)
                            }
                            lyricsStore.save(d, for: filePath)
                        },
                        onEditEnd: { newEnd in
                            var d = doc
                            guard i < d.segments.count else { return }
                            // Clamp: end must stay strictly after start.
                            let clamped = max(d.segments[i].start + 0.1, newEnd)
                            let delta = clamped - d.segments[i].end
                            d.segments[i].end = clamped
                            // Carry the next lyric's start along by the same
                            // delta, like the → nudge.
                            if i + 1 < d.segments.count {
                                let maxStart = d.segments[i+1].end - 0.1
                                d.segments[i+1].start = min(maxStart,
                                                            d.segments[i+1].start + delta)
                            }
                            lyricsStore.save(d, for: filePath)
                        },
                        onDelete: {
                            var d = doc
                            guard i < d.segments.count else { return }
                            d.segments.remove(at: i)
                            lyricsStore.save(d, for: filePath)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func startTranscription() {
        guard !filePath.isEmpty else { return }
        guard models.isInstalled(preferredModel) else {
            showingModelSheet = true
            return
        }
        transcriber.transcribe(audioPath: filePath, variant: preferredModel)
    }

    private func openFixLyricsSheet() {
        // Prefill the editor with the current lyrics so the user only has to
        // correct the lines that are wrong instead of retyping from scratch.
        if let doc = doc {
            fixLyricsDraft = doc.segments.map(\.text).joined(separator: "\n")
        }
        showingFixLyricsSheet = true
    }

    private func applyFixLyrics(_ pastedText: String) {
        guard let doc = doc else { return }
        let newSegments = LyricsMatcher.reconcile(
            pastedText: pastedText,
            existing: doc.segments
        )
        guard !newSegments.isEmpty else { return }
        var newDoc = doc
        newDoc.segments = newSegments
        lyricsStore.save(newDoc, for: filePath)
    }
}

// MARK: - Fix Lyrics sheet

private struct FixLyricsSheet: View {
    @Binding var pastedText: String
    @Binding var isPresented: Bool
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix Lyrics").font(.headline)
            Text("Paste the corrected lyrics below — one line per lyric. Existing timestamps are re-applied to your lines using word-overlap alignment, so line breaks don't have to match exactly.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $pastedText)
                .font(.body)
                .frame(minHeight: 260)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Submit") {
                    onSubmit(pastedText)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 420)
    }
}

// MARK: - Segment row

private struct LyricSegmentRow: View {
    let segment: LyricSegment
    let onChange: (String) -> Void
    /// `delta` is applied to both start and end of this lyric (±0.1 s) so the
    /// whole range shifts while keeping its duration. The parent handler is
    /// also responsible for carrying the adjacent boundary: nudging earlier
    /// pulls the previous lyric's end back by the same amount, nudging later
    /// pushes the next lyric's start forward.
    let onNudge: (Double) -> Void
    /// Direct edit of this lyric's start time. The parent clamps so start
    /// stays >= 0 and < end, then carries the previous lyric's end along
    /// by the same delta — same neighbor semantic as the ← nudge, so the
    /// gap (or lack of one) with the previous lyric is preserved.
    let onEditStart: (Double) -> Void
    /// Direct edit of this lyric's end time. The parent clamps so end stays
    /// > start, then carries the next lyric's start along by the same
    /// delta — same neighbor semantic as the → nudge.
    let onEditEnd: (Double) -> Void
    let onDelete: () -> Void

    @State private var editing = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                EditableTimestamp(value: segment.start, onCommit: onEditStart)
                Text("→")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                EditableTimestamp(value: segment.end, onCommit: onEditEnd)
                Spacer()
                Button(action: { onNudge(-0.1) }) {
                    Image(systemName: "arrow.left")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
                .help("Nudge 100 ms earlier (also pulls previous lyric's end back)")
                Button(action: { onNudge(0.1) }) {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
                .help("Nudge 100 ms later (also pushes next lyric's start forward)")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
                .help("Delete this lyric")
            }
            if editing {
                // `.axis(.vertical)` lets the field grow for long lyrics so
                // the text isn't truncated mid-edit the way a single-line
                // field would. Enter still commits (via `.onSubmit`); users
                // don't need literal newlines inside a lyric line.
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { revert() }
                    .onChange(of: focused) { _, isFocused in
                        // Losing focus (clicked outside, tab, etc.) reverts.
                        if !isFocused && editing { revert() }
                    }
            } else {
                Text(segment.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEditing() }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
    }

    private func startEditing() {
        draft = segment.text
        editing = true
        // Request focus on the next runloop tick so the TextField exists.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        let newValue = draft
        editing = false
        focused = false
        if newValue != segment.text { onChange(newValue) }
    }

    private func revert() {
        draft = segment.text
        editing = false
        focused = false
    }
}

// MARK: - Editable timestamp

/// Double-click to edit a `M:SS.hh` timestamp in place. Accepts either the
/// `M:SS.hh` format on commit or a plain decimal number of seconds. Enter
/// commits, Escape or focus-loss reverts. Invalid input reverts silently.
private struct EditableTimestamp: View {
    let value: Double
    let onCommit: (Double) -> Void

    @State private var editing = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: 54)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { revert() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused && editing { revert() }
                    }
            } else {
                Text(Self.format(value))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEditing() }
                    .help("Double-click to edit")
            }
        }
    }

    private func startEditing() {
        draft = Self.format(value)
        editing = true
        // Ask for focus on the next tick so the TextField exists to receive it.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        editing = false
        focused = false
        if let parsed = Self.parse(draft), abs(parsed - value) > 0.0001 {
            onCommit(parsed)
        }
    }

    private func revert() {
        editing = false
        focused = false
    }

    static func format(_ t: Double) -> String {
        let mins = Int(t) / 60
        let secs = t - Double(mins * 60)
        return String(format: "%d:%05.2f", mins, secs)
    }

    /// Accepts `M:SS.hh` (e.g. `2:01.96`) or a plain decimal in seconds
    /// (e.g. `121.96`). Returns nil if the input can't be parsed.
    static func parse(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            guard parts.count == 2,
                  let mins = Int(parts[0]),
                  let secs = Double(parts[1]),
                  mins >= 0, secs >= 0 else { return nil }
            return Double(mins) * 60 + secs
        }
        return Double(trimmed).flatMap { $0 >= 0 ? $0 : nil }
    }
}

// MARK: - Model picker popover

private struct ModelPickerPopover: View {
    @Binding var preferredModel: String
    @Binding var isPresented: Bool
    @ObservedObject private var models = ModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Whisper Models").font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            Divider()
            Text("Models run locally. Downloads are one-time, cached in ~/Library/Application Support/BandMember/.")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(ModelManager.catalog) { info in
                modelRow(info)
            }
            if let err = models.lastError {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func modelRow(_ info: WhisperModelInfo) -> some View {
        let installed = models.isInstalled(info.id)
        let downloading = models.downloading[info.id]
        let isPreferred = preferredModel == info.id

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.displayName).font(.callout).bold()
                    if isPreferred {
                        Text("default").font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.2)))
                            .foregroundColor(.accentColor)
                    }
                }
                Text("\(info.approxSizeMB) MB · \(info.qualityNote)")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if let progress = downloading {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.caption).foregroundColor(.secondary)
            } else if installed {
                Button("Use") { preferredModel = info.id }
                    .disabled(isPreferred)
                Button(role: .destructive) {
                    models.delete(info.id)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
            } else {
                Button("Download") {
                    Task { @MainActor in
                        try? await models.download(info.id)
                        if models.isInstalled(info.id) { preferredModel = info.id }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
