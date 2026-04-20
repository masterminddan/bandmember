import Foundation
import AVFoundation

struct TempoData {
    let beats: [Double]
    let bpm: Double
    let sourceFilePath: String
}

/// Persisted via @AppStorage with raw value.
enum SnapMode: String, CaseIterable {
    case measure
    case beat
    case off

    var label: String {
        switch self {
        case .measure: return "measure snap"
        case .beat:    return "beat snap"
        case .off:     return "snap off"
        }
    }

    func next() -> SnapMode {
        switch self {
        case .measure: return .beat
        case .beat:    return .off
        case .off:     return .measure
        }
    }
}

enum TempoAnalyzer {
    /// Envelope-based onset detector. Produces a list of beat timestamps and
    /// a median-interval BPM estimate. Works well for click tracks and
    /// reasonably for music with clear percussive content. Variable tempo is
    /// handled implicitly because the threshold is local.
    static func analyze(url: URL) -> TempoData? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }

        let envelopeRate: Double = 1000.0
        let windowSize = max(1, Int(sampleRate / envelopeRate))
        let envLength = Int(totalFrames) / windowSize
        guard envLength > 50 else { return nil }

        var envelope = [Float](repeating: 0, count: envLength)

        // Read in reasonably sized chunks to keep memory bounded even for
        // multi-minute files. Each chunk fills an integral number of envelope
        // samples so boundaries stay aligned.
        let chunkEnvSamples = 4096
        let chunkFrames = AVAudioFrameCount(chunkEnvSamples * windowSize)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: chunkFrames
        ) else { return nil }

        let channels = Int(file.processingFormat.channelCount)
        var envIdx = 0

        while envIdx < envLength {
            do { try file.read(into: buffer, frameCount: chunkFrames) } catch { break }
            let read = Int(buffer.frameLength)
            guard read > 0, let channelData = buffer.floatChannelData else { break }

            let samplesThisChunk = read / windowSize
            for s in 0..<samplesThisChunk {
                guard envIdx < envLength else { break }
                let start = s * windowSize
                let end = start + windowSize
                var peak: Float = 0
                for f in start..<end {
                    var sum: Float = 0
                    for c in 0..<channels { sum += abs(channelData[c][f]) }
                    let avg = sum / Float(channels)
                    if avg > peak { peak = avg }
                }
                envelope[envIdx] = peak
                envIdx += 1
            }

            if read < Int(chunkFrames) { break }
        }

        guard envIdx > 10 else { return nil }
        if envIdx < envLength { envelope.removeLast(envLength - envIdx) }

        // Half-wave-rectified first difference: an onset function that lights
        // up on energy increases and ignores decays.
        let n = envelope.count
        var onset = [Float](repeating: 0, count: n)
        for i in 1..<n {
            let d = envelope[i] - envelope[i - 1]
            onset[i] = d > 0 ? d : 0
        }

        // Light smoothing to bridge sample-to-sample jitter.
        var smoothed = [Float](repeating: 0, count: n)
        let sm = 2
        for i in 0..<n {
            let lo = max(0, i - sm)
            let hi = min(n - 1, i + sm)
            var sum: Float = 0
            for j in lo...hi { sum += onset[j] }
            smoothed[i] = sum / Float(hi - lo + 1)
        }

        // Adaptive peak picking against a rolling local mean. The mean window
        // (~500 ms) is long enough to smooth over one beat but short enough to
        // follow tempo/dynamics changes.
        let envRate = envelopeRate
        let minBeatGap = Int(0.22 * envRate)   // cap at ~270 BPM
        let statsHalf = Int(0.25 * envRate)
        let k: Float = 2.0
        let floorRatio: Float = 0.05

        // Global reference floor so silent stretches don't generate ghost peaks.
        var globalMax: Float = 0
        for v in smoothed where v > globalMax { globalMax = v }
        let absFloor = globalMax * floorRatio

        var peaks: [Int] = []
        var lastAccepted = -minBeatGap

        for i in 1..<(n - 1) {
            let v = smoothed[i]
            guard v >= absFloor else { continue }
            guard v > smoothed[i - 1], v >= smoothed[i + 1] else { continue }

            let lo = max(0, i - statsHalf)
            let hi = min(n - 1, i + statsHalf)
            var sum: Float = 0
            for j in lo...hi { sum += smoothed[j] }
            let mean = sum / Float(hi - lo + 1)
            guard v > mean * k else { continue }

            if i - lastAccepted >= minBeatGap {
                peaks.append(i)
                lastAccepted = i
            } else if let last = peaks.last, v > smoothed[last] {
                peaks.removeLast()
                peaks.append(i)
                lastAccepted = i
            }
        }

        guard peaks.count >= 4 else { return nil }

        let beats = peaks.map { Double($0) / envRate }

        var intervals: [Double] = []
        intervals.reserveCapacity(beats.count - 1)
        for i in 1..<beats.count { intervals.append(beats[i] - beats[i - 1]) }
        intervals.sort()
        let median = intervals[intervals.count / 2]
        guard median > 0 else { return nil }
        let bpm = 60.0 / median

        return TempoData(beats: beats, bpm: bpm, sourceFilePath: url.path)
    }
}
