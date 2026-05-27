import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import CoreMedia

/// Single-file player for the lyric editor, backed by `AVAudioEngine` so
/// it honors `AudioOutputManager.shared.currentUID` instead of just
/// hitting the macOS system default output.
///
/// Replaces `AVAudioPlayer` in the editor; surface intentionally mirrors
/// the bits the editor uses: `duration`, `isPlaying`, `currentTime` (get/
/// set), `play`, `pause`, `stop`. Re-acquires the device live when the
/// user changes BandMember's output picker.
///
/// Uses the same `AssetDecoder` full-decode path PlaybackEngine does so
/// MP3 / AAC files play to their full asset duration instead of being
/// clipped by `AVAudioFile.length` underreporting.
final class EditorAudioPlayer {
    // MARK: - Public surface (mirrors what LyricsEditorModel needs)

    let duration: Double

    var isPlaying: Bool {
        startWallDate != nil && pausedAt == nil && !naturalEnded
    }

    /// Current playhead in seconds, [0, duration]. Reading is wall-clock
    /// while playing (the same scheme PlaybackEngine uses for lyric sync —
    /// device sample clock drifts negligibly over editor timescales and
    /// wall-clock is reliable across engine stop/start cycles). Writing
    /// reschedules from the new position if currently playing, otherwise
    /// just stores the position for the next play().
    var currentTime: Double {
        get {
            if naturalEnded { return duration }
            if let paused = pausedAt { return paused }
            if let start = startWallDate {
                let elapsed = max(0, Date().timeIntervalSince(start))
                return min(duration, startOffset + elapsed)
            }
            return startOffset
        }
        set { seek(to: newValue) }
    }

    // MARK: - Internals

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Decoded full-asset buffer for compressed formats. Nil when we're
    /// using `AVAudioFile.scheduleSegment` directly (PCM-native formats).
    private let fullBuffer: AVAudioPCMBuffer?
    private let file: AVAudioFile?
    private let processingFormat: AVAudioFormat

    private var startWallDate: Date?
    /// Audio position (file time, seconds) at the moment `startWallDate`
    /// was captured. Used to convert wall-clock elapsed into file time.
    private var startOffset: Double = 0
    /// Set when `pause()` is called; holds the captured currentTime so
    /// resume can re-start the player node from that position.
    private var pausedAt: Double?
    /// Set by the scheduled buffer's completion handler when playback
    /// reaches the end naturally. Keeps `isPlaying` honest so the editor's
    /// poll loop notices and shuts itself down.
    private var naturalEnded: Bool = false

    private var deviceCancellable: AnyCancellable?

    // MARK: - Init

    init?(url: URL) {
        guard let aFile = try? AVAudioFile(forReading: url) else {
            debugLog("[EDITOR] AVAudioFile open failed for \(url.lastPathComponent)")
            return nil
        }
        self.processingFormat = aFile.processingFormat

        // Authoritative duration: max of asset-level (MP3 header) and decoded
        // frame count. AVAudioFile.length matches the asset for WAV / AIFF;
        // for MP3 / AAC it undercounts and we want the larger value.
        let fileLenSec = Double(aFile.length) / processingFormat.sampleRate
        let asset = AVURLAsset(url: url)
        let assetDur = CMTimeGetSeconds(asset.duration)
        let needsFullDecode = assetDur.isFinite && assetDur > fileLenSec + 0.02
        self.duration = max(assetDur.isFinite ? assetDur : 0, fileLenSec)

        if needsFullDecode {
            self.fullBuffer = decodeFullAssetBuffer(url: url,
                                                    processingFormat: processingFormat)
            // Fall back to file-based scheduling if the full decode failed.
            self.file = self.fullBuffer == nil ? aFile : nil
        } else {
            self.fullBuffer = nil
            self.file = aFile
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: processingFormat)
        applySelectedOutputDevice()
        warmUpEngine()

        // Re-route live when the user picks a different output in BandMember's
        // device menu — same model PlaybackEngine uses for its main graph.
        deviceCancellable = AudioOutputManager.shared.$currentUID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleDeviceChange() }
    }

    /// Mirrors `PlaybackEngine.warmUpEngine`: kicks the engine into running
    /// state so the first play / device-swap doesn't pay device-acquisition
    /// latency. Idle running has no audible or measurable cost.
    private func warmUpEngine() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            debugLog("[EDITOR] engine warmed up")
        } catch {
            debugLog("[EDITOR] warmup start failed: \(error)")
        }
    }

    deinit {
        playerNode.stop()
        if engine.isRunning { engine.stop() }
    }

    // MARK: - Transport

    func play() {
        // Resuming from a pause uses the captured pause position; otherwise
        // we continue from currentTime (which is startOffset when stopped).
        let resumeFrom: Double
        if let paused = pausedAt {
            resumeFrom = paused
        } else if naturalEnded {
            // User hit play after the song ended — restart from current
            // position (the editor sets currentTime=0 in this case before
            // calling play, so we'll typically resume at 0).
            resumeFrom = currentTime
        } else {
            resumeFrom = currentTime
        }
        pausedAt = nil
        naturalEnded = false
        scheduleAndStart(from: resumeFrom)
    }

    func pause() {
        guard isPlaying else { return }
        let now = currentTime
        playerNode.pause()
        pausedAt = now
        startWallDate = nil
    }

    func stop() {
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        startWallDate = nil
        pausedAt = nil
        naturalEnded = false
        startOffset = 0
    }

    private func seek(to time: Double) {
        let target = max(0, min(time, duration))
        naturalEnded = false
        if isPlaying {
            // Reschedule from target. playerNode.stop clears any pending
            // schedule and lets us cleanly schedule a new segment.
            playerNode.stop()
            scheduleAndStart(from: target)
        } else if pausedAt != nil {
            pausedAt = target
            startOffset = target
        } else {
            startOffset = target
        }
    }

    // MARK: - Scheduling

    private func scheduleAndStart(from time: Double) {
        playerNode.stop()
        let target = max(0, min(time, duration))

        if let buf = fullBuffer {
            let sr = processingFormat.sampleRate
            let startFrame = Int(target * sr)
            guard startFrame < Int(buf.frameLength),
                  let slice = sliceBufferFromFrame(buf, startFrame: startFrame) else {
                return
            }
            playerNode.scheduleBuffer(slice, at: nil, options: [], completionHandler: { [weak self] in
                DispatchQueue.main.async { self?.naturalEnded = true }
            })
        } else if let file = file {
            let sr = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(target * sr)
            guard startFrame < file.length else { return }
            let remaining = AVAudioFrameCount(file.length - startFrame)
            playerNode.scheduleSegment(file, startingFrame: startFrame,
                                        frameCount: remaining, at: nil,
                                        completionHandler: { [weak self] in
                DispatchQueue.main.async { self?.naturalEnded = true }
            })
        } else {
            debugLog("[EDITOR] no source to schedule")
            return
        }

        if !engine.isRunning {
            do { try engine.start() } catch {
                debugLog("[EDITOR] engine start failed: \(error)")
                return
            }
        }
        playerNode.play()
        startOffset = target
        startWallDate = Date()
    }

    // MARK: - Device routing

    /// Pushes BandMember's currently selected device down to the engine's
    /// output AudioUnit. Same pattern PlaybackEngine uses — keeps the editor
    /// and the main playback graph hitting the same physical output.
    private func applySelectedOutputDevice() {
        let mgr = AudioOutputManager.shared
        guard let dev = mgr.currentDevice,
              let outputAU = engine.outputNode.audioUnit else { return }
        var deviceID: AudioDeviceID = dev.id
        let status = AudioUnitSetProperty(
            outputAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            debugLog("[EDITOR] device set failed: \(dev.name) status=\(status)")
        } else {
            debugLog("[EDITOR] device set to \(dev.name) (\(dev.channelCount) ch)")
        }
    }

    private func handleDeviceChange() {
        let wasPlaying = isPlaying
        let resumeAt = currentTime
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        startWallDate = nil
        applySelectedOutputDevice()
        if wasPlaying {
            scheduleAndStart(from: resumeAt)
        } else {
            startOffset = resumeAt
            // Warm the engine so the next play is instant — same reason
            // PlaybackEngine.handleDeviceChange does this.
            warmUpEngine()
        }
    }
}
