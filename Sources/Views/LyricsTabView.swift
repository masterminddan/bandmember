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
    private var beats: [Double] {
        guard let item = item else { return [] }
        return TempoCoordinator.shared.tempoData(forItemID: item.id, store: store)?.beats ?? []
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
                    lyricsDisplay(doc: resolvedDoc)
                    Spacer(minLength: 20)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingFixLyricsSheet) {
            FixLyricsSheet(
                pastedText: $fixLyricsDraft,
                onCancel: { showingFixLyricsSheet = false },
                onSubmit: { text in
                    applyFixLyrics(text)
                    showingFixLyricsSheet = false
                }
            )
        }
    }

    /// Snapshot handed to the editor on open. If lyrics don't exist yet we
    /// hand over an empty doc so the user can build lyrics from scratch —
    /// the editor persists via `LyricsStore.save` on the first commit, which
    /// creates the sidecar.
    private var docForEditor: LyricsDocument {
        if let doc = doc { return doc }
        return LyricsDocument(
            audioFilePath: filePath,
            segments: [],
            modelUsed: "manual",
            language: nil,
            createdAt: Date()
        )
    }

    private func openEditor() {
        guard !filePath.isEmpty, FileManager.default.fileExists(atPath: filePath) else { return }
        LyricsEditorWindow.show(
            filePath: filePath,
            doc: docForEditor,
            beats: beats,
            title: item?.name ?? ""
        )
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

    /// Read-only view of the lyrics text. All editing (including nudge /
    /// duration / timestamp tweaks) lives in the Lyrics Editor sheet — the
    /// tab just shows what's there and offers the buttons to open that sheet,
    /// re-transcribe, import corrected text, or clear.
    ///
    /// The header row (including the Edit button) is always visible for audio
    /// items, even before lyrics exist, so the user can open the editor and
    /// build lyrics from scratch on a blank doc.
    @ViewBuilder
    private func lyricsDisplay(doc: LyricsDocument?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Edit button on its own row. The inspector column is narrow
            // (~280 px); sharing a row with the "Lyrics" title + date + Clear
            // was squeezing the button out entirely.
            Button {
                openEditor()
            } label: {
                Label("Edit Lyrics", systemImage: "slider.horizontal.below.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(filePath.isEmpty || !FileManager.default.fileExists(atPath: filePath))
            .help(doc == nil
                  ? "Open the lyrics editor and build lyrics from scratch"
                  : "Open the lyrics editor to adjust timing and text")

            HStack(alignment: .firstTextBaseline) {
                Text("Lyrics").font(.headline)
                Spacer()
                if let doc = doc {
                    Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button(role: .destructive) {
                        lyricsStore.delete(for: filePath)
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }
            ScrollView {
                if let doc = doc, !doc.segments.isEmpty {
                    Text(doc.segments.map(\.text).joined(separator: "\n"))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    Text("No lyrics yet. Transcribe above, or click Edit Lyrics to start a blank timeline.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .frame(minHeight: 140, maxHeight: 420)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.2))
            )
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
    let onCancel: () -> Void
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
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Submit") { onSubmit(pastedText) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 420)
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
