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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if item?.mediaType != .audio {
                    unavailableBanner
                } else {
                    modelPickerRow
                    jobStatusRow
                    presenterControls
                    Divider()
                    segmentList
                    Spacer(minLength: 20)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingModelSheet) {
            ModelPickerSheet(preferredModel: $preferredModel, isPresented: $showingModelSheet)
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
        }
    }

    private func modelDisplayName(for id: String) -> String {
        ModelManager.catalog.first(where: { $0.id == id })?.displayName ?? id
    }

    @ViewBuilder
    private var jobStatusRow: some View {
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
    private var presenterControls: some View {
        if doc != nil || store.items.contains(where: { $0.id != itemID && lyricsStore.lyrics(for: $0.filePath) != nil }) {
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
                        ForEach(0..<max(NSScreen.screens.count, 1), id: \.self) { idx in
                            Text(displayName(for: idx)).tag(idx)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
        }
    }

    private func displayName(for index: Int) -> String {
        let screens = NSScreen.screens
        if index < screens.count {
            let frame = screens[index].frame
            return "Display \(index + 1) (\(Int(frame.width))×\(Int(frame.height)))"
        }
        return "Display \(index + 1) (not connected)"
    }

    @ViewBuilder
    private var segmentList: some View {
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
                        onNudge: { startDelta, endDelta in
                            var d = doc
                            d.segments[i].start = max(0, d.segments[i].start + startDelta)
                            d.segments[i].end = max(d.segments[i].start + 0.1, d.segments[i].end + endDelta)
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
    let onNudge: (Double, Double) -> Void

    @State private var editing = false
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(timestamp(segment.start)) → \(timestamp(segment.end))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { onNudge(-0.1, -0.1) }) { Image(systemName: "arrow.left") }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .help("Nudge earlier 100 ms")
                Button(action: { onNudge(0.1, 0.1) }) { Image(systemName: "arrow.right") }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .help("Nudge later 100 ms")
            }
            if editing {
                TextField("Lyric text", text: $draft, onCommit: {
                    onChange(draft); editing = false
                })
                .textFieldStyle(.roundedBorder)
                .onAppear { draft = segment.text }
            } else {
                Text(segment.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { draft = segment.text; editing = true }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06)))
    }

    private func timestamp(_ t: Double) -> String {
        let mins = Int(t) / 60
        let secs = t - Double(mins * 60)
        return String(format: "%d:%05.2f", mins, secs)
    }
}

// MARK: - Model picker sheet

private struct ModelPickerSheet: View {
    @Binding var preferredModel: String
    @Binding var isPresented: Bool
    @ObservedObject private var models = ModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Whisper Models").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
            }
            Divider()
            Text("Models run locally. Downloads are one-time, cached in ~/Documents/huggingface.")
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
