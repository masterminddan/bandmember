import AVFoundation
import AppKit
import Combine
import CoreMedia

/// Manages playback using AVAudioEngine for sample-accurate sync of audio files,
/// and AVPlayer for video files.
class PlaybackEngine: ObservableObject {

    // ── Audio engine (shared by all audio cues) ──────────────────────
    private let audioEngine = AVAudioEngine()

    struct AudioCue {
        let playerNode: AVAudioPlayerNode
        let gainUnit: AVAudioUnitEffect
        let gainAU: ChannelGainAU      // raw reference for setting L/R gain
        let mixerNode: AVAudioMixerNode // per-cue master volume
        let file: AVAudioFile
        let startPosition: Double      // file offset (seconds) where scheduled segment begins
    }
    private var audioCues: [UUID: AudioCue] = [:]

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
    }

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
        playSynchronized(items: items,
                         startTime: item.startPosition,
                         endTime: item.endPosition)

        // If the triggered item asks for lyrics, find a doc for the chain and
        // open the presenter on its target display.
        if item.showLyrics, let store = store,
           let hit = LyricsStore.shared.lyricsForChain(triggeredItemID: item.id, store: store) {
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
        }

        // Mark all as playing
        for (item, _) in audioItems { store?.playingItemIDs.insert(item.id) }
        for (item, _) in videoItems { store?.playingItemIDs.insert(item.id) }

        // Start all audio nodes at the exact same sample time
        if !audioItems.isEmpty {
            let outputNode = audioEngine.outputNode
            if let nodeTime = outputNode.lastRenderTime, nodeTime.isSampleTimeValid {
                let offsetSamples = AVAudioFramePosition(nodeTime.sampleRate * 0.1)
                let syncTime = AVAudioTime(sampleTime: nodeTime.sampleTime + offsetSamples,
                                           atRate: nodeTime.sampleRate)
                debugLog("[ENGINE] Sync-starting \(audioItems.count) audio nodes")
                for (_, cue) in audioItems {
                    cue.playerNode.play(at: syncTime)
                }
            } else {
                debugLog("[ENGINE] No render time, starting immediately")
                for (_, cue) in audioItems {
                    cue.playerNode.play()
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

        // Skip if this file is shorter than the start position
        if startFrame >= file.length {
            debugLog("[ENGINE] \(item.name) is shorter than start time \(startTime)s, skipping")
            return nil
        }

        let playerNode = AVAudioPlayerNode()
        let gainUnit   = AVAudioUnitEffect(audioComponentDescription: channelGainComponentDescription)
        let gainAU     = gainUnit.auAudioUnit as! ChannelGainAU
        let mixer      = AVAudioMixerNode()

        gainAU.leftGain  = item.leftVolume
        gainAU.rightGain = item.rightVolume
        mixer.volume     = item.masterVolume

        audioEngine.attach(playerNode)
        audioEngine.attach(gainUnit)
        audioEngine.attach(mixer)

        let fmt = file.processingFormat
        audioEngine.connect(playerNode, to: gainUnit, format: fmt)
        audioEngine.connect(gainUnit,   to: mixer,    format: fmt)
        audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: nil)

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
        } else {
            let remainingFrames = AVAudioFrameCount(file.length - startFrame)
            playerNode.scheduleSegment(file, startingFrame: startFrame,
                                       frameCount: remainingFrames, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.stop(itemID: item.id)
                }
            }
        }

        let cue = AudioCue(playerNode: playerNode, gainUnit: gainUnit,
                           gainAU: gainAU, mixerNode: mixer, file: file,
                           startPosition: startTime)
        audioCues[item.id] = cue
        return cue
    }

    // ══════════════════════════════════════════════════════════════════
    // MARK: - Current playback time (for lyrics sync etc.)
    // ══════════════════════════════════════════════════════════════════

    /// Returns the current playhead position (in seconds, absolute from file start)
    /// for the given item, or nil if it isn't currently playing.
    func currentTime(for itemID: UUID) -> Double? {
        if let cue = audioCues[itemID] {
            guard let nodeTime = cue.playerNode.lastRenderTime,
                  let playerTime = cue.playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
            let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
            return cue.startPosition + max(0, elapsed)
        }
        if let player = videoPlayers[itemID] {
            let t = player.currentTime().seconds
            return t.isFinite ? t : nil
        }
        return nil
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

    private func stopAudio(itemID: UUID) {
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
