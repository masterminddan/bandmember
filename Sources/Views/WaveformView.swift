import SwiftUI
import AVFoundation
import AppKit

// MARK: - Waveform Cache

class WaveformCache {
    static let shared = WaveformCache()
    private var cache: [String: WaveformData] = [:]

    func get(for path: String) -> WaveformData? { cache[path] }
    func set(_ data: WaveformData, for path: String) { cache[path] = data }
}

struct WaveformData {
    let leftSamples: [Float]
    let rightSamples: [Float]
    /// Per-chunk peak of |(L + R) * 0.7071|, matching what ChannelGainAU
    /// actually renders in mono-sum routing modes.
    let monoSumSamples: [Float]
    let duration: Double
}

// MARK: - Waveform Generator

enum WaveformGenerator {
    static func generate(from url: URL, sampleCount: Int = 300) -> WaveformData? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }

        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(totalFrames) / sampleRate
        let channels = Int(file.processingFormat.channelCount)
        let framesPerSample = max(1, totalFrames / sampleCount)
        let chunkSize = AVAudioFrameCount(framesPerSample)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: chunkSize
        ) else { return nil }

        var leftSamples: [Float] = []
        var rightSamples: [Float] = []
        var monoSumSamples: [Float] = []
        leftSamples.reserveCapacity(sampleCount)
        rightSamples.reserveCapacity(sampleCount)
        monoSumSamples.reserveCapacity(sampleCount)

        let monoSumScale: Float = 0.7071068

        for _ in 0..<sampleCount {
            do {
                try file.read(into: buffer, frameCount: chunkSize)
            } catch { break }
            guard buffer.frameLength > 0 else { break }

            let frames = Int(buffer.frameLength)
            let lData = buffer.floatChannelData?[0]
            let rData = (channels >= 2) ? buffer.floatChannelData?[1] : nil

            var leftPeak: Float = 0
            var rightPeak: Float = 0
            var sumPeak: Float = 0

            if let l = lData, let r = rData {
                for j in 0..<frames {
                    let lv = l[j], rv = r[j]
                    leftPeak  = max(leftPeak,  abs(lv))
                    rightPeak = max(rightPeak, abs(rv))
                    sumPeak   = max(sumPeak,   abs((lv + rv) * monoSumScale))
                }
            } else if let l = lData {
                // Mono source: L mirrors to R, sum = L * sqrt(2) * 0.7071 = L
                for j in 0..<frames {
                    let lv = l[j]
                    leftPeak = max(leftPeak, abs(lv))
                }
                rightPeak = leftPeak
                sumPeak   = leftPeak
            }

            leftSamples.append(leftPeak)
            rightSamples.append(rightPeak)
            monoSumSamples.append(sumPeak)
        }

        return leftSamples.isEmpty ? nil : WaveformData(
            leftSamples: leftSamples,
            rightSamples: rightSamples,
            monoSumSamples: monoSumSamples,
            duration: duration
        )
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let filePath: String
    let itemID: UUID
    @Binding var startPosition: Double
    @Binding var endPosition: Double?
    let masterVolume: Float
    let leftVolume: Float
    let rightVolume: Float
    let beats: [Double]
    let snapMode: SnapMode

    @EnvironmentObject var playbackEngine: PlaybackEngine
    @EnvironmentObject var store: PlaylistStore

    @State private var waveform: WaveformData?
    @State private var isLoading = true
    /// Latest playhead time for this item. Updated by `pollTimer` at 20 Hz
    /// while the item is playing so the monospaced display under the
    /// waveform reads smoothly.
    @State private var currentTime: Double = 0
    @State private var pollTimer: Timer?

    private var duration: Double { waveform?.duration ?? 0 }
    private var isPlaying: Bool { store.playingItemIDs.contains(itemID) }
    private var routing: OutputRouting {
        store.items.first(where: { $0.id == itemID })?.outputRouting ?? .stereo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Waveform").font(.caption).foregroundColor(.secondary)

            HStack(spacing: 2) {
                // Channel labels — dimmed when that side is muted by routing.
                VStack(spacing: 0) {
                    Text("L")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(routing == .monoRight ? .secondary.opacity(0.4) : .blue)
                        .frame(maxHeight: .infinity)
                    Text("R")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(routing == .monoLeft ? .secondary.opacity(0.4) : .orange)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 12)

                // Waveform
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.15))

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let wf = waveform {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                if duration > 0 {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.08))
                                        .frame(width: playheadX(in: geo.size.width))
                                }

                                // Top half = LEFT output channel, bottom half = RIGHT output channel.
                                // In mono modes, the active side draws the pre-summed L+R waveform
                                // and the muted side draws nothing — matching what the AU sends.
                                let topSamples: [Float] = {
                                    switch routing {
                                    case .stereo:    return wf.leftSamples
                                    case .monoLeft:  return wf.monoSumSamples
                                    case .monoRight: return []
                                    }
                                }()
                                let topGain: Float = {
                                    switch routing {
                                    case .stereo, .monoLeft: return masterVolume * leftVolume
                                    case .monoRight:         return 0
                                    }
                                }()
                                let bottomSamples: [Float] = {
                                    switch routing {
                                    case .stereo:    return wf.rightSamples
                                    case .monoLeft:  return []
                                    case .monoRight: return wf.monoSumSamples
                                    }
                                }()
                                let bottomGain: Float = {
                                    switch routing {
                                    case .stereo, .monoRight: return masterVolume * rightVolume
                                    case .monoLeft:           return 0
                                    }
                                }()
                                let topColor: Color  = (routing == .monoLeft)  ? .green : .blue
                                let botColor: Color  = (routing == .monoRight) ? .green : .orange

                                StereoWaveformShape(samples: topSamples,    gain: topGain,    flipped: false)
                                    .fill(topColor.opacity(0.6))
                                StereoWaveformShape(samples: bottomSamples, gain: bottomGain, flipped: true)
                                    .fill(botColor.opacity(0.6))

                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 0.5)
                                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                                if duration > 0 {
                                    Rectangle()
                                        .fill(Color.red)
                                        .frame(width: 1.5)
                                        .offset(x: playheadX(in: geo.size.width))
                                }

                                if duration > 0, let end = endPosition {
                                    Rectangle()
                                        .fill(Color.green)
                                        .frame(width: 1.5)
                                        .offset(x: positionX(end, in: geo.size.width))
                                }

                                // Live playhead — only visible while the item
                                // is actually playing. Rendered last so it
                                // sits on top of the start / end markers.
                                if duration > 0 && isPlaying {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.7))
                                        .frame(width: 1)
                                        .offset(x: positionX(currentTime, in: geo.size.width))
                                }
                            }
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard duration > 0 else { return }
                                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                                        let rawTime = fraction * duration
                                        let time = snapToNearestBeat(rawTime)
                                        if NSEvent.modifierFlags.contains(.shift) {
                                            endPosition = time
                                        } else {
                                            startPosition = time
                                        }
                                    }
                            )
                        }
                    } else {
                        Text("No waveform")
                            .font(.caption2).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(height: 60)

            // Time display
            if duration > 0 {
                HStack {
                    Text(formatTime(startPosition)).foregroundColor(.red)
                    Spacer()
                    if let end = endPosition {
                        HStack(spacing: 4) {
                            Text("⟲ \(formatTime(end))").foregroundColor(.green)
                            Button(action: { endPosition = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear loop end point")
                        }
                        Spacer()
                    }
                    // Live playhead time — only shown while this item is
                    // actually playing. Placed next to the total duration so
                    // the reader can see "now / total" at a glance.
                    if isPlaying {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text(formatTime(currentTime))
                        }
                        .foregroundColor(.white)
                    }
                    Text(formatTime(duration)).foregroundColor(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))
            }
        }
        .onAppear {
            loadWaveform()
            syncPlayheadTimer()
        }
        .onChange(of: filePath) { loadWaveform() }
        .onChange(of: isPlaying) { _, _ in syncPlayheadTimer() }
        .onChange(of: itemID) { _, _ in syncPlayheadTimer() }
        .onDisappear { stopPlayheadTimer() }
    }

    /// Start a 20 Hz poll of `playbackEngine.currentTime(for:)` while the
    /// item is playing; stop it otherwise. 20 Hz is smooth enough that the
    /// hundredths digit in the monospaced display doesn't look janky, and
    /// the light playhead line slides continuously instead of stepping.
    private func syncPlayheadTimer() {
        stopPlayheadTimer()
        guard isPlaying else {
            currentTime = 0
            return
        }
        currentTime = playbackEngine.currentTime(for: itemID) ?? 0
        // Capture the current `itemID` / `playbackEngine` in the closure so
        // the timer isn't at risk of polling a stale id if the view is
        // re-used for another item — the `.onChange(of: itemID)` above
        // recreates us in that case, but belt-and-braces.
        let capturedID = itemID
        let capturedEngine = playbackEngine
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            currentTime = capturedEngine.currentTime(for: capturedID) ?? 0
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPlayheadTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func playheadX(in width: CGFloat) -> CGFloat {
        positionX(startPosition, in: width)
    }

    private func snapToNearestBeat(_ time: Double) -> Double {
        let anchors: [Double]
        switch snapMode {
        case .off:
            return time
        case .beat:
            anchors = beats
        case .measure:
            // Assume 4/4: every 4th detected beat is a downbeat, starting at beats[0].
            anchors = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        }
        guard !anchors.isEmpty else { return time }
        var lo = 0
        var hi = anchors.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if anchors[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        let after = anchors[lo]
        let before = lo > 0 ? anchors[lo - 1] : after
        return (time - before) <= (after - time) ? before : after
    }

    private func positionX(_ time: Double, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(max(0, min(time, duration)) / duration) * width
    }

    private func loadWaveform() {
        let path = filePath
        guard !path.isEmpty else {
            waveform = nil; isLoading = false; return
        }
        if let cached = WaveformCache.shared.get(for: path) {
            waveform = cached; isLoading = false; return
        }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WaveformGenerator.generate(from: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                if let result = result {
                    WaveformCache.shared.set(result, for: path)
                }
                waveform = result
                isLoading = false
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = seconds - Double(mins * 60)
        return String(format: "%d:%05.2f", mins, secs)
    }
}

// MARK: - Stereo Waveform Shape

/// Draws one channel of a waveform. When flipped=false, bars grow upward from center.
/// When flipped=true, bars grow downward from center.
struct StereoWaveformShape: Shape {
    let samples: [Float]
    let gain: Float
    let flipped: Bool

    func path(in rect: CGRect) -> Path {
        guard !samples.isEmpty else { return Path() }

        var path = Path()
        let barWidth = rect.width / CGFloat(samples.count)
        let midY = rect.midY
        let maxHeight = rect.height / 2

        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * barWidth
            let h = CGFloat(min(sample * gain, 1.0)) * maxHeight
            if h < 0.5 { continue }

            let barRect: CGRect
            if flipped {
                barRect = CGRect(x: x, y: midY, width: max(1, barWidth - 0.5), height: h)
            } else {
                barRect = CGRect(x: x, y: midY - h, width: max(1, barWidth - 0.5), height: h)
            }
            path.addRect(barRect)
        }

        return path
    }
}
