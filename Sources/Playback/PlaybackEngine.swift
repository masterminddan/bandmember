import AVFoundation
import AppKit
import AudioToolbox
import Combine
import CoreAudio
import CoreMedia

/// Manages playback using AVAudioEngine for sample-accurate sync of audio files,
/// and AVPlayer for video files.
class PlaybackEngine: ObservableObject {

    // ── Audio engine (shared by all audio cues) ──────────────────────
    private let audioEngine = AVAudioEngine()
    /// Brick-wall safety limiter inserted between mainMixerNode and outputNode.
    /// Catches inter-sample peaks introduced by mono-summing or by users pushing
    /// per-cue volume above unity, so FOH never sees a clipped signal.
    private var outputLimiter: AVAudioUnitEffect?

    struct AudioCue {
        let playerNode: AVAudioPlayerNode
        let gainUnit: AVAudioUnitEffect
        let gainAU: ChannelGainAU      // raw reference for setting L/R gain
        let mixerNode: AVAudioMixerNode // per-cue master volume
        let file: AVAudioFile
        let startPosition: Double      // file offset (seconds) where scheduled segment begins
        let loopEndPosition: Double?   // if set & > startPosition, audio loops in [start, end]
    }
    private var audioCues: [UUID: AudioCue] = [:]
    /// Wall-clock moment each cue's audio is expected to start playing. Used
    /// by `currentTime(for:)` to compute elapsed time for lyric sync,
    /// independent of AVAudioEngine's sample-time accounting which is
    /// unreliable across engine stop/restart cycles.
    private var audioPlayStartDates: [UUID: Date] = [:]

    /// Number of output channels currently being driven (matches the
    /// CoreAudio device chosen via `AudioOutputManager`). Used to format
    /// the multi-channel mainMixer ↔ limiter ↔ outputNode connection chain
    /// and to size each cue's `ChannelGainAU` output.
    private var currentChannelCount: Int = 2

    /// Subscription that watches the user's chosen output device and swaps
    /// it on the engine when it changes.
    private var deviceCancellable: AnyCancellable?

    /// Last wall-clock second the limiter tap logged its RMS reading. Used
    /// to bucket the 30-100 tap callbacks/sec down to one log line per
    /// second — enough resolution to spot drops while keeping the log tidy.
    private var lastTapLogSecond: Int = -1

    // ── Video (still uses AVPlayer per-cue) ──────────────────────────
    private var videoPlayers: [UUID: AVPlayer] = [:]
    private var videoWindows: [UUID: NSWindow] = [:]
    private var videoEndObservers: [UUID: Any] = [:]
    private var videoLoopObservers: [UUID: Any] = [:]  // boundary-time tokens

    weak var store: PlaylistStore?

    // ── Init ─────────────────────────────────────────────────────────
    init() {
        // Register the custom channel-gain audio unit once.
        AUAudioUnit.registerSubclass(
            ChannelGainAU.self,
            as: channelGainComponentDescription,
            name: "BandMember Channel Gain",
            version: 1
        )
        applySelectedOutputDevice()
        installOutputLimiter()
        warmUpEngine()

        // Watch the user's device choice. Switching devices requires fully
        // tearing down the engine — we stop everything, swap, and let the
        // next play() rebuild cue graphs at the new channel count.
        deviceCancellable = AudioOutputManager.shared.$currentUID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleDeviceChange() }
    }

    private func handleDeviceChange() {
        stopAll()
        applySelectedOutputDevice()
        installOutputLimiter()
        warmUpEngine()
    }

    /// Starts the audio engine idle so the first cue doesn't pay device-
    /// acquisition latency (CoreAudio sample-rate / format / clock
    /// negotiation, ~1-2 s on the first cold start with a new device).
    /// Called from init and after device swaps. AVAudioEngine running with
    /// no active sources just pulls silence at the device rate — no
    /// measurable CPU or power impact until a cue actually plays.
    private func warmUpEngine() {
        guard !audioEngine.isRunning else { return }
        do {
            try audioEngine.start()
            debugLog("[ENGINE] warmed up (idle, device acquired)")
        } catch {
            debugLog("[ENGINE] warmup start failed: \(error)")
        }
    }

    /// Pushes the user's currently selected device down to the engine's
    /// output AudioUnit. Safe to call repeatedly; defers to system default
    /// when no choice is set or the chosen device is missing.
    private func applySelectedOutputDevice() {
        let mgr = AudioOutputManager.shared
        let device = mgr.currentDevice
        currentChannelCount = max(1, device?.channelCount ?? 2)

        // If we don't have an explicit device or its CoreAudio ID isn't
        // currently visible, fall back to system default — AVAudioEngine
        // already does this on its own; just make sure we reflect channels.
        guard let dev = device,
              let outputAU = audioEngine.outputNode.audioUnit else { return }

        var deviceID: AudioDeviceID = dev.id
        let status = AudioUnitSetProperty(
            outputAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            debugLog("[ENGINE] Failed to set output device \(dev.name) (status=\(status))")
        } else {
            debugLog("[ENGINE] Output device set to \(dev.name) (\(dev.channelCount) ch)")
        }
    }

    /// Inserts an Apple PeakLimiter between mainMixerNode and outputNode so
    /// the final bus is brick-walled at ~0 dBFS, regardless of how many
    /// physical channels the chosen device exposes. AVAudioEngine implicitly
    /// connects mainMixerNode → outputNode the first time mainMixerNode is
    /// referenced; we tear that down and splice in the limiter, using a
    /// format that matches the device's channel count.
    private func installOutputLimiter() {
        // Detach the previous limiter (device swap may have changed channels).
        if let prev = outputLimiter {
            prev.removeTap(onBus: 0)
            audioEngine.disconnectNodeOutput(audioEngine.mainMixerNode)
            audioEngine.detach(prev)
            outputLimiter = nil
        }

        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let limiter = AVAudioUnitEffect(audioComponentDescription: desc)
        let mainMixer = audioEngine.mainMixerNode  // forces implicit attach + connection
        let output    = audioEngine.outputNode

        // Format we want to drive the device with. Float32, non-interleaved,
        // N channels matching the device, at the device's nominal sample
        // rate. Reading the rate from CoreAudio directly avoids a slow /
        // low-pitched playback bug on devices whose rate differs from the
        // stale value AVAudioEngine reports immediately after a device swap.
        var sampleRate = AudioOutputManager.shared.currentSampleRate
        if sampleRate <= 0 {
            let nodeRate = output.outputFormat(forBus: 0).sampleRate
            sampleRate = nodeRate > 0 ? nodeRate : 48000
        }
        let multiFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate,
                                     channels: AVAudioChannelCount(currentChannelCount),
                                     interleaved: false)

        audioEngine.disconnectNodeOutput(mainMixer)
        audioEngine.attach(limiter)
        audioEngine.connect(mainMixer, to: limiter, format: multiFmt)
        audioEngine.connect(limiter,   to: output,  format: multiFmt)

        // Tighten attack/decay for transient-heavy backing tracks. Pre-gain
        // stays at 0 dB — loudness is the user's job via per-cue volume.
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime,
                              kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime,
                              kAudioUnitScope_Global, 0, 0.030, 0)
        outputLimiter = limiter

        // RMS tap is a developer-only diagnostic — it's the noisiest line in
        // the log (one row/sec during playback) and only earns its keep when
        // chasing a silent-playback regression. Excluded from release builds.
        #if DEBUG
        if let fmt = multiFmt { installLimiterTap(on: limiter, format: fmt) }
        #endif
    }

    #if DEBUG
    /// Once-per-second RMS log on the limiter output. This is what we'd
    /// actually be sending to the device — if a "silent playback" report
    /// coincides with non-trivial RMS here, the audio left the app fine
    /// and the problem is OS/device-side (volume sync, hardware mute).
    /// If RMS is at the noise floor while cues are active, the audio graph
    /// itself is dropping signal somewhere and we need to look upstream.
    private func installLimiterTap(on limiter: AVAudioUnitEffect, format: AVAudioFormat) {
        limiter.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let chData = buffer.floatChannelData else { return }
            let chCount = Int(buffer.format.channelCount)
            var sumSq: Float = 0
            for c in 0..<chCount {
                let ptr = chData[c]
                for i in 0..<frames { sumSq += ptr[i] * ptr[i] }
            }
            let mean = sumSq / Float(frames * chCount)
            let rms  = sqrtf(mean)
            let dbfs: Float = rms > 1e-9 ? 20 * log10f(rms) : -120

            // Hop to main only to decide whether to log + read cue state.
            // Real-time-thread work here is just the RMS math above.
            DispatchQueue.main.async {
                guard !self.audioCues.isEmpty else { return }
                let nowSec = Int(Date().timeIntervalSince1970)
                if nowSec != self.lastTapLogSecond {
                    self.lastTapLogSecond = nowSec
                    debugLog(String(format: "[ENGINE] tap RMS=%.1f dBFS (cues=%d)",
                                    dbfs, self.audioCues.count))
                }
            }
        }
    }
    #endif

    deinit { stopAll() }

    // ══════════════════════════════════════════════════════════════════
    // MARK: - Public API
    // ══════════════════════════════════════════════════════════════════

    func play(item: PlaylistItem) {
        // Collect this item + any chained via auto-follow.
        var items: [PlaylistItem] = [item]
        if item.autoFollow, let store = store {
            var idx = store.items.firstIndex(where: { $0.id == item.id })
            while let cur = idx {
                let current = store.items[cur]
                guard current.autoFollow, cur + 1 < store.items.count else { break }
                items.append(store.items[cur + 1])
                idx = cur + 1
            }
        }
        let endStr = item.endPosition.map { String(format: "%.2f", $0) } ?? "nil"
        debugLog(String(format: "[ENGINE] play(%@) startPosition=%.2fs endPosition=%@",
                        item.name, item.startPosition, endStr))
        playSynchronized(items: items,
                         startTime: item.startPosition,
                         endTime: item.endPosition)

        // If the triggered item asks for lyrics, find a doc for the chain and
        // open the presenter on its target display.
        if item.showLyrics, let store = store,
           let hit = LyricsStore.shared.lyricsForChain(triggeredItemID: item.id, store: store) {
            debugLog("Lyrics: presenting for \(item.name) (start=\(item.startPosition)s) from \((hit.item.filePath as NSString).lastPathComponent) — \(hit.doc.segments.count) segments, model=\(hit.doc.modelUsed), created=\(hit.doc.createdAt)")
            LyricsPresenter.show(
                item: item,
                lyrics: hit.doc,
                screenIndex: item.targetDisplayIndex,
                engine: self
            )
        }
    }

    func stop(itemID: UUID) {
        stopAudio(itemID: itemID)
        stopVideo(itemID: itemID)
        LyricsPresenter.hide(itemID: itemID)
        store?.playingItemIDs.remove(itemID)
    }

    func stopAll() {
        for id in Array(audioCues.keys) + Array(videoPlayers.keys) {
            stop(itemID: id)
        }
        LyricsPresenter.hideAll()
        audioEngine.stop()
    }

    /// Fades out all playing audio and video over `duration` seconds, then stops.
    func fadeOutAndStopAll(duration: TimeInterval = 1.0) {
        let allAudioIDs = Array(audioCues.keys)
        let allVideoIDs = Array(videoPlayers.keys)
        guard !allAudioIDs.isEmpty || !allVideoIDs.isEmpty else { return }

        // Snapshot current volumes so we can ramp from them
        var audioStartVolumes: [UUID: Float] = [:]
        for id in allAudioIDs {
            audioStartVolumes[id] = audioCues[id]?.mixerNode.volume ?? 1.0
        }
        var videoStartVolumes: [UUID: Float] = [:]
        for id in allVideoIDs {
            videoStartVolumes[id] = videoPlayers[id]?.volume ?? 1.0
        }

        // Fade video window opacity
        for id in allVideoIDs {
            guard let window = videoWindows[id] else { continue }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                window.animator().alphaValue = 0.0
            }
        }

        // Animate volume down in steps over the duration
        let steps = 20
        let stepInterval = duration / Double(steps)
        for step in 1...steps {
            let fraction = Float(step) / Float(steps)
            let multiplier = 1.0 - fraction  // 1 → 0

            DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval * Double(step)) { [weak self] in
                guard let self = self else { return }
                for id in allAudioIDs {
                    if let cue = self.audioCues[id] {
                        cue.mixerNode.volume = (audioStartVolumes[id] ?? 1.0) * multiplier
                    }
                }
                for id in allVideoIDs {
                    if let player = self.videoPlayers[id] {
                        player.volume = (videoStartVolumes[id] ?? 1.0) * multiplier
                    }
                }

                // Final step: actually stop everything
                if step == steps {
                    self.stopAll()
                }
            }
        }
    }

    func togglePlay(item: PlaylistItem) {
        let isPlaying = audioCues[item.id] != nil || videoPlayers[item.id] != nil
        if isPlaying {
            // Stop this item and all chained items
            var ids: [UUID] = [item.id]
            if item.autoFollow, let store = store {
                var idx = store.items.firstIndex(where: { $0.id == item.id })
                while let cur = idx {
                    let current = store.items[cur]
                    guard current.autoFollow, cur + 1 < store.items.count else { break }
                    let next = store.items[cur + 1]
                    if audioCues[next.id] != nil || videoPlayers[next.id] != nil {
                        ids.append(next.id)
                    }
                    idx = cur + 1
                }
            }
            for id in ids { stop(itemID: id) }
        } else {
            play(item: item)
        }
    }

    func updateVolume(for item: PlaylistItem) {
        if let cue = audioCues[item.id] {
            cue.mixerNode.volume = item.masterVolume
            cue.gainAU.leftGain  = item.leftVolume
            cue.gainAU.rightGain = item.rightVolume

            // Bus → channel may have changed under the cue (user picked a
            // different bus, or remapped the bus on this device). Update
            // placement live; output channel count is fixed at allocation.
            let busStore = OutputBusStore.shared
            let deviceUID = AudioOutputManager.shared.currentDevice?.uid
            let asn: BusAssignment? = deviceUID.flatMap {
                busStore.assignment(busID: item.outputRouting.busID, deviceUID: $0)
            }
            let placement = asn ?? .stereo(startChannel: 1)
            cue.gainAU.isMonoSum    = placement.isMonoSum
            cue.gainAU.startChannel = Int32(max(0, placement.startChannel - 1))
            cue.gainAU.isMuted      = (asn == nil)
        }
        if let player = videoPlayers[item.id] {
            player.volume = item.masterVolume
        }
    }

    func isPlaying(itemID: UUID) -> Bool {
        return audioCues[itemID] != nil || videoPlayers[itemID] != nil
    }

    // ══════════════════════════════════════════════════════════════════
    // MARK: - Synchronized playback
    // ══════════════════════════════════════════════════════════════════

    private func playSynchronized(items: [PlaylistItem], startTime: Double = 0, endTime: Double? = nil) {
        let endStr = endTime.map { "\($0)" } ?? "nil"
        debugLog("[ENGINE] playSynchronized: \(items.map { $0.name }) startTime=\(startTime)s endTime=\(endStr)")
        logPreplaySnapshot(items: items)

        var audioItems: [(item: PlaylistItem, cue: AudioCue)] = []
        var videoItems: [(item: PlaylistItem, player: AVPlayer)]  = []

        for item in items {
            if item.isDivider { continue }

            if audioCues[item.id] != nil || videoPlayers[item.id] != nil {
                stop(itemID: item.id)
            }
            guard item.fileExists else {
                debugLog("[ENGINE] File not found: \(item.filePath)")
                continue
            }

            if item.mediaType == .audio {
                if let cue = prepareAudioCue(for: item, startTime: startTime, endTime: endTime) {
                    audioItems.append((item: item, cue: cue))
                }
            } else {
                if let player = prepareVideoPlayer(for: item, startTime: startTime, endTime: endTime) {
                    videoItems.append((item: item, player: player))
                }
            }
        }

        // Start audio engine if needed
        if !audioItems.isEmpty && !audioEngine.isRunning {
            do {
                try audioEngine.start()
                debugLog("[ENGINE] Audio engine started")
            } catch {
                debugLog("[ENGINE] Failed to start audio engine: \(error)")
            }
        } else if !audioItems.isEmpty {
            debugLog("[ENGINE] Audio engine already running (isRunning=true), reusing")
        }

        // Mark all as playing
        for (item, _) in audioItems { store?.playingItemIDs.insert(item.id) }
        for (item, _) in videoItems { store?.playingItemIDs.insert(item.id) }

        // Start all audio nodes at the exact same sample time
        let preRoll: TimeInterval = 0.1
        if !audioItems.isEmpty {
            let outputNode = audioEngine.outputNode
            let wallStart = Date().addingTimeInterval(preRoll)
            if let nodeTime = outputNode.lastRenderTime, nodeTime.isSampleTimeValid {
                let offsetSamples = AVAudioFramePosition(nodeTime.sampleRate * preRoll)
                let syncTime = AVAudioTime(sampleTime: nodeTime.sampleTime + offsetSamples,
                                           atRate: nodeTime.sampleRate)
                debugLog("[ENGINE] Sync-starting \(audioItems.count) audio nodes")
                for (item, cue) in audioItems {
                    cue.playerNode.play(at: syncTime)
                    audioPlayStartDates[item.id] = wallStart
                }
            } else {
                debugLog("[ENGINE] No render time, starting immediately")
                for (item, cue) in audioItems {
                    cue.playerNode.play()
                    audioPlayStartDates[item.id] = Date()  // no pre-roll in this path
                }
            }
        }

        // Start video players
        for (_, player) in videoItems {
            player.play()
        }

        debugLog("[ENGINE] All players started")
    }

    // ══════════════════════════════════════════════════════════════════
    // MARK: - Audio cue setup
    // ══════════════════════════════════════════════════════════════════

    /// Builds the audio graph:  PlayerNode → ChannelGainAU → MixerNode → MainMixer
    /// If startTime > 0, schedules from that offset. Skips if file is shorter than startTime.
    private func prepareAudioCue(for item: PlaylistItem, startTime: Double = 0, endTime: Double? = nil) -> AudioCue? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: item.fileURL)
        } catch {
            debugLog("[ENGINE] Can't open audio file \(item.name): \(error)")
            return nil
        }

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(startTime * sampleRate)

        // AVAudioFile.length underreports for MP3 / AAC (decoder priming +
        // padding ignored), losing up to ~1s at the tail. AVURLAsset.duration
        // reads the format-level metadata and matches what AVAudioPlayer
        // would play. We use it as the authoritative end-of-cue marker.
        let asset = AVURLAsset(url: item.fileURL)
        let assetDuration = CMTimeGetSeconds(asset.duration)
        let fileLengthSeconds = Double(file.length) / sampleRate
        let needsFullDecode = assetDuration.isFinite
            && assetDuration > fileLengthSeconds + 0.02

        // For skip-check, use whichever length is larger so we don't reject a
        // legitimate start time that's within the asset but past file.length.
        let effectiveLengthSeconds = max(assetDuration.isFinite ? assetDuration : 0,
                                         fileLengthSeconds)
        if startTime >= effectiveLengthSeconds {
            debugLog("[ENGINE] \(item.name) is shorter than start time \(startTime)s, skipping")
            return nil
        }

        let playerNode = AVAudioPlayerNode()
        let gainUnit   = AVAudioUnitEffect(audioComponentDescription: channelGainComponentDescription)
        let gainAU     = gainUnit.auAudioUnit as! ChannelGainAU
        let mixer      = AVAudioMixerNode()

        // Resolve the cue's bus → physical channel(s) on the active device.
        // No assignment on this device == intentionally silent: the chain
        // still runs (autoFollow / lyrics / timer all proceed) but no
        // audio reaches the output. This lets users mute, say, a click
        // bus on the rehearsal rig without changing per-cue routing.
        let busStore = OutputBusStore.shared
        let deviceUID = AudioOutputManager.shared.currentDevice?.uid
        let asn: BusAssignment? = deviceUID.flatMap {
            busStore.assignment(busID: item.outputRouting.busID, deviceUID: $0)
        }
        let placement = asn ?? .stereo(startChannel: 1)

        gainAU.leftGain   = item.leftVolume
        gainAU.rightGain  = item.rightVolume
        gainAU.isMonoSum  = placement.isMonoSum
        gainAU.startChannel = Int32(max(0, placement.startChannel - 1))
        gainAU.isMuted    = (asn == nil)
        try? gainAU.setOutputChannelCount(currentChannelCount,
                                          sampleRate: file.processingFormat.sampleRate)
        mixer.volume     = item.masterVolume

        audioEngine.attach(playerNode)
        audioEngine.attach(gainUnit)
        audioEngine.attach(mixer)

        let inFmt  = file.processingFormat
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: inFmt.sampleRate,
                                   channels: AVAudioChannelCount(currentChannelCount),
                                   interleaved: false)
        audioEngine.connect(playerNode, to: gainUnit, format: inFmt)
        audioEngine.connect(gainUnit,   to: mixer,    format: outFmt)
        audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: outFmt)

        // If a loop end point is set after the start, schedule the segment as a
        // looping buffer (start → end → start → end …). Otherwise play to EOF once.
        // The end point comes from the triggered item and applies to all chained items.
        if let endPos = endTime,
           endPos > startTime,
           let loopBuffer = readBuffer(from: file,
                                       startFrame: startFrame,
                                       endTime: endPos,
                                       sampleRate: sampleRate) {
            playerNode.scheduleBuffer(loopBuffer, at: nil, options: .loops, completionHandler: nil)
        } else if needsFullDecode,
                  let segmentBuffer = decodeAssetSlice(url: item.fileURL,
                                                       processingFormat: inFmt,
                                                       startTime: startTime,
                                                       assetDuration: assetDuration) {
            // MP3 / AAC path: AVAssetReader sees the full asset, so we
            // schedule a buffer holding every decoded frame. AVAudioFile-only
            // scheduling would truncate the tail by encoder priming + padding.
            debugLog(String(format: "[ENGINE] \(item.name) full-decode buffer: %d frames (%.2fs at %.0f Hz); fileLen=%.2fs assetDur=%.2fs",
                            segmentBuffer.frameLength,
                            Double(segmentBuffer.frameLength) / sampleRate,
                            sampleRate, fileLengthSeconds, assetDuration))
            playerNode.scheduleBuffer(segmentBuffer, at: nil, options: [], completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    self?.audioDidFinishNaturally(itemID: item.id)
                }
            })
        } else {
            // PCM / WAV / AIFF path (and fallback if full decode failed):
            // AVAudioFile.length matches the asset exactly.
            let remainingFrames = AVAudioFrameCount(file.length - startFrame)
            playerNode.scheduleSegment(file, startingFrame: startFrame,
                                       frameCount: remainingFrames, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.audioDidFinishNaturally(itemID: item.id)
                }
            }
        }

        let loopEnd: Double? = {
            guard let endPos = endTime, endPos > startTime else { return nil }
            return endPos
        }()
        let cue = AudioCue(playerNode: playerNode, gainUnit: gainUnit,
                           gainAU: gainAU, mixerNode: mixer, file: file,
                           startPosition: startTime,
                           loopEndPosition: loopEnd)
        audioCues[item.id] = cue

        let busName = OutputBusStore.shared.bus(id: item.outputRouting.busID)?.name ?? "?"
        let placementStr: String = {
            switch placement {
            case .stereo(let c):  return "stereo@\(c)"
            case .monoSum(let c): return "monoSum@\(c)"
            }
        }()
        let mutedStr = (asn == nil) ? " MUTED(no asn for device)" : ""
        debugLog("[ENGINE] cue \(item.name): bus=\(busName) placement=\(placementStr) startCh0b=\(gainAU.startChannel) isMonoSum=\(gainAU.isMonoSum) isMuted=\(gainAU.isMuted) masterVol=\(item.masterVolume) L=\(item.leftVolume) R=\(item.rightVolume) outChans=\(currentChannelCount)\(mutedStr)")
        return cue
    }

    // ══════════════════════════════════════════════════════════════════
    // MARK: - Diagnostics
    // ══════════════════════════════════════════════════════════════════

    /// Logs a full snapshot of engine + device state right before a play.
    /// Tuning aid for the intermittent silent-playback bug: comparing a
    /// silent attempt's snapshot against a working one lets us narrow down
    /// what actually differs (which device, which sample rate, whether the
    /// output AU is pointing where we think it is).
    private func logPreplaySnapshot(items: [PlaylistItem]) {
        let mgr = AudioOutputManager.shared
        let dev = mgr.currentDevice
        let devStr = dev.map { "\($0.name) (id=\($0.id), uid=\($0.uid), \($0.channelCount) ch)" } ?? "nil"
        debugLog("[ENGINE] snapshot: currentDevice=\(devStr) persistedUID=\(mgr.currentUID ?? "nil")")

        // What the output AU is actually targeting (not necessarily what
        // currentDevice says it *should* be — that's the whole question).
        if let outputAU = audioEngine.outputNode.audioUnit {
            var auDeviceID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                outputAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &auDeviceID, &size
            )
            if status == noErr {
                let match = (dev?.id == auDeviceID) ? " (matches currentDevice)" : " (MISMATCH with currentDevice)"
                debugLog("[ENGINE] snapshot: output AU device id=\(auDeviceID)\(match)")
            } else {
                debugLog("[ENGINE] snapshot: output AU device query failed (status=\(status))")
            }
        } else {
            debugLog("[ENGINE] snapshot: output AU is nil")
        }

        let outFmt = audioEngine.outputNode.outputFormat(forBus: 0)
        debugLog("[ENGINE] snapshot: outputNode format sr=\(outFmt.sampleRate) ch=\(outFmt.channelCount); currentChannelCount=\(currentChannelCount); engineRunning=\(audioEngine.isRunning)")

        if let nodeTime = audioEngine.outputNode.lastRenderTime {
            debugLog("[ENGINE] snapshot: lastRenderTime sampleTimeValid=\(nodeTime.isSampleTimeValid) sampleTime=\(nodeTime.sampleTime) sampleRate=\(nodeTime.sampleRate) hostTimeValid=\(nodeTime.isHostTimeValid)")
        } else {
            debugLog("[ENGINE] snapshot: lastRenderTime=nil")
        }
    }

    // ══════════════════════════════════════════════════════════════════
    // MARK: - Current playback time (for lyrics sync etc.)
    // ══════════════════════════════════════════════════════════════════

    /// Returns the current playhead position (in seconds, absolute from file start)
    /// for the given item, or nil if it isn't currently playing.
    func currentTime(for itemID: UUID) -> Double? {
        if let cue = audioCues[itemID] {
            // Derive elapsed from wall-clock rather than playerNode's sample
            // time. sampleTime is not reset cleanly across audioEngine
            // stop/restart, which caused subsequent plays to report the wrong
            // offset. Wall-clock is plenty accurate for a 30 Hz lyric timer.
            guard let startDate = audioPlayStartDates[itemID] else {
                return cue.startPosition
            }
            let elapsed = max(0, Date().timeIntervalSince(startDate))
            if let loopEnd = cue.loopEndPosition {
                let loopLen = loopEnd - cue.startPosition
                guard loopLen > 0 else { return cue.startPosition + elapsed }
                let inLoop = elapsed.truncatingRemainder(dividingBy: loopLen)
                return cue.startPosition + inLoop
            }
            return cue.startPosition + elapsed
        }
        if let player = videoPlayers[itemID] {
            let t = player.currentTime().seconds
            return t.isFinite ? t : nil
        }
        return nil
    }

    /// Wrapper around `decodeFullAssetBuffer` + `sliceBufferFromFrame` that
    /// returns the [startTime, end] slice ready to schedule on a player node.
    private func decodeAssetSlice(url: URL,
                                  processingFormat: AVAudioFormat,
                                  startTime: Double,
                                  assetDuration: Double) -> AVAudioPCMBuffer? {
        guard let full = decodeFullAssetBuffer(url: url,
                                               processingFormat: processingFormat) else {
            return nil
        }
        let startFrame = Int(startTime * processingFormat.sampleRate)
        return sliceBufferFromFrame(full, startFrame: startFrame)
    }

    /// Reads a [startFrame, endTime] segment from `file` into a PCM buffer for loop scheduling.
    private func readBuffer(from file: AVAudioFile,
                            startFrame: AVAudioFramePosition,
                            endTime: Double,
                            sampleRate: Double) -> AVAudioPCMBuffer? {
        let endFrame = min(AVAudioFramePosition(endTime * sampleRate), file.length)
        guard endFrame > startFrame else { return nil }
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frameCount) else { return nil }
        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            debugLog("[ENGINE] Loop buffer read failed: \(error)")
            return nil
        }
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// Called when an audio cue's scheduled segment finishes rendering on
    /// its own (vs. an explicit user stop). Drops the cue from the engine
    /// but intentionally leaves any open lyric presenter running — see the
    /// scheduleSegment call-site comment for why.
    private func audioDidFinishNaturally(itemID: UUID) {
        stopAudio(itemID: itemID)
        store?.playingItemIDs.remove(itemID)
    }

    private func stopAudio(itemID: UUID) {
        audioPlayStartDates.removeValue(forKey: itemID)
        guard let cue = audioCues.removeValue(forKey: itemID) else { return }
        cue.playerNode.stop()
        audioEngine.disconnectNodeOutput(cue.playerNode)
        audioEngine.disconnectNodeOutput(cue.gainUnit)
        audioEngine.disconnectNodeOutput(cue.mixerNode)
        audioEngine.detach(cue.playerNode)
        audioEngine.detach(cue.gainUnit)
        audioEngine.detach(cue.mixerNode)
    }

    // ══════════════════════════════════════════════════════════════════
    // MARK: - Video player setup
    // ══════════════════════════════════════════════════════════════════

    private func prepareVideoPlayer(for item: PlaylistItem, startTime: Double = 0, endTime: Double? = nil) -> AVPlayer? {
        let player = AVPlayer(url: item.fileURL)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = item.masterVolume

        // Seek to start position if needed
        if startTime > 0 {
            let cmTime = CMTime(seconds: startTime, preferredTimescale: 600)
            // Check duration — skip if video is shorter than start time
            let duration = player.currentItem?.asset.duration ?? .zero
            if duration != .zero && CMTimeCompare(cmTime, duration) >= 0 {
                debugLog("[ENGINE] \(item.name) video shorter than start time, skipping")
                return nil
            }
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        videoPlayers[item.id] = player
        setupVideoWindow(for: item, player: player)

        // If looping, install a boundary observer that seeks back to startTime
        // when the playhead reaches endTime. Otherwise stop on natural EOF.
        if let endPos = endTime, endPos > startTime {
            let endCM = CMTime(seconds: endPos, preferredTimescale: 600)
            let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time: endCM)],
                                                       queue: .main) { [weak player] in
                let backTo = CMTime(seconds: startTime, preferredTimescale: 600)
                player?.seek(to: backTo, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            videoLoopObservers[item.id] = token
        } else {
            let observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.stop(itemID: item.id)
            }
            videoEndObservers[item.id] = observer
        }

        return player
    }

    private func stopVideo(itemID: UUID) {
        let player = videoPlayers[itemID]
        if let token = videoLoopObservers.removeValue(forKey: itemID) {
            player?.removeTimeObserver(token)
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        videoPlayers.removeValue(forKey: itemID)

        if let window = videoWindows.removeValue(forKey: itemID) {
            window.orderOut(nil)
            window.close()
        }
        if let obs = videoEndObservers.removeValue(forKey: itemID) {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Tracks the next window level to assign so newer videos stack on top.
    private static var nextVideoLevel: Int = NSWindow.Level.screenSaver.rawValue

    private func setupVideoWindow(for item: PlaylistItem, player: AVPlayer) {
        let screens = NSScreen.screens
        guard item.targetDisplayIndex < screens.count else {
            debugLog("[ENGINE] Display \(item.targetDisplayIndex) not available for \(item.name), skipping video")
            return
        }
        let screen = screens[item.targetDisplayIndex]

        // Each new video window gets a higher level so it stacks on top of existing ones.
        PlaybackEngine.nextVideoLevel += 1
        let level = NSWindow.Level(rawValue: PlaybackEngine.nextVideoLevel)

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = level
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hasShadow = false

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor.black

        let contentView = VideoLayerView(frame: CGRect(origin: .zero, size: screen.frame.size))
        contentView.playerLayer = playerLayer
        contentView.wantsLayer = true
        contentView.layer = CALayer()
        contentView.layer?.addSublayer(playerLayer)
        playerLayer.frame = contentView.bounds

        window.contentView = contentView
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        videoWindows[item.id] = window
    }
}

// MARK: - Video Layer View

private class VideoLayerView: NSView {
    var playerLayer: AVPlayerLayer?
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}
