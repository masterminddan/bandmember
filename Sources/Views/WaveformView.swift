import SwiftUI
import AVFoundation

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
        leftSamples.reserveCapacity(sampleCount)
        rightSamples.reserveCapacity(sampleCount)

        for _ in 0..<sampleCount {
            do {
                try file.read(into: buffer, frameCount: chunkSize)
            } catch { break }
            guard buffer.frameLength > 0 else { break }

            let frames = Int(buffer.frameLength)

            // Left channel (always channel 0)
            var leftPeak: Float = 0
            if let data = buffer.floatChannelData?[0] {
                for j in 0..<frames { leftPeak = max(leftPeak, abs(data[j])) }
            }
            leftSamples.append(leftPeak)

            // Right channel (channel 1 if stereo, otherwise mirror left)
            var rightPeak: Float = 0
            if channels >= 2, let data = buffer.floatChannelData?[1] {
                for j in 0..<frames { rightPeak = max(rightPeak, abs(data[j])) }
            } else {
                rightPeak = leftPeak
            }
            rightSamples.append(rightPeak)
        }

        return leftSamples.isEmpty ? nil : WaveformData(
            leftSamples: leftSamples,
            rightSamples: rightSamples,
            duration: duration
        )
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let filePath: String
    @Binding var startPosition: Double
    let masterVolume: Float
    let leftVolume: Float
    let rightVolume: Float

    @State private var waveform: WaveformData?
    @State private var isLoading = true

    private var duration: Double { waveform?.duration ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Waveform").font(.caption).foregroundColor(.secondary)

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
                            // Played region tint
                            if duration > 0 {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.08))
                                    .frame(width: playheadX(in: geo.size.width))
                            }

                            // Left channel (top half) — blue
                            StereoWaveformShape(
                                samples: wf.leftSamples,
                                gain: masterVolume * leftVolume,
                                flipped: false
                            )
                            .fill(Color.blue.opacity(0.6))

                            // Right channel (bottom half) — orange
                            StereoWaveformShape(
                                samples: wf.rightSamples,
                                gain: masterVolume * rightVolume,
                                flipped: true
                            )
                            .fill(Color.orange.opacity(0.6))

                            // Center line
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 0.5)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                            // Playhead
                            if duration > 0 {
                                Rectangle()
                                    .fill(Color.red)
                                    .frame(width: 1.5)
                                    .offset(x: playheadX(in: geo.size.width))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard duration > 0 else { return }
                                    let fraction = max(0, min(1, value.location.x / geo.size.width))
                                    startPosition = fraction * duration
                                }
                        )
                    }
                } else {
                    Text("No waveform")
                        .font(.caption2).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 60)

            // Time display
            if duration > 0 {
                HStack {
                    Text(formatTime(startPosition)).foregroundColor(.red)
                    Spacer()
                    HStack(spacing: 8) {
                        Circle().fill(Color.blue).frame(width: 6, height: 6)
                        Text("L")
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("R")
                    }
                    .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(duration)).foregroundColor(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))
            }
        }
        .onAppear { loadWaveform() }
        .onChange(of: filePath) { loadWaveform() }
    }

    private func playheadX(in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(startPosition / duration) * width
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
