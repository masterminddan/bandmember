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
            Button("Change / Download…") { showingModelSheet = true }
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
        HStack(spacing: 10) {
            switch state {
            case .idle, .done:
                Button(action: startTranscription) {
                    Label(doc == nil ? "Transcribe" : "Re-transcribe",
                          systemImage: "text.bubble.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(filePath.isEmpty || !FileManager.default.fileExists(atPath: filePath))

                if let doc = doc {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(doc.segments.count) segments · model: \(modelDisplayName(for: doc.modelUsed))")
                            .font(.caption).foregroundColor(.secondary)
                        Text("Created \(doc.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            case .loadingModel:
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                Text("Loading model…").font(.callout).foregroundColor(.secondary)
            case .transcribing(let fraction):
                ProgressView(value: fraction).frame(maxWidth: 180)
                Text(String(format: "Transcribing… %.0f%%", fraction * 100))
                    .font(.caption).foregroundColor(.secondary)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Failed: \(msg)").font(.caption).lineLimit(2)
                Button("Retry", action: startTranscription)
            }
            Spacer()
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
                HStack {
                    Text("Segments").font(.headline)
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
}

// MARK: - Segment row

private struct LyricSegmentRow: View {
    let segment: LyricSegment
    let onChange: (String) -> Void
    let onDelete: () -> Void

    @State private var editing = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(timestamp(segment.start)) → \(timestamp(segment.end))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundColor(.secondary)
                .help("Delete this segment")
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

    private func timestamp(_ t: Double) -> String {
        let mins = Int(t) / 60
        let secs = t - Double(mins * 60)
        return String(format: "%d:%05.2f", mins, secs)
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
