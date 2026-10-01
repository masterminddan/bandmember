import Accelerate
import AudioToolbox
import AVFoundation

/// AudioComponentDescription used to register and instantiate ChannelGainAU.
let channelGainComponentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: fourCharCode("chgn"),
    componentManufacturer: fourCharCode("AVLP"),
    componentFlags: 0,
    componentFlagsMask: 0
)

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) | FourCharCode(char)
    }
    return result
}

/// Float32, non-interleaved format with `channels` discrete channels.
/// AVAudioFormat's plain channel-count initializer returns nil above stereo
/// (it has no layout to assume), so wider formats — a 4-out interface, say —
/// are built with an explicit "discrete channels, in order" layout.
func discreteAudioFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
    if channels <= 2 {
        return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                             sampleRate: sampleRate,
                             channels: AVAudioChannelCount(max(1, channels)),
                             interleaved: false)
    }
    guard let layout = AVAudioChannelLayout(
        layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
    ) else { return nil }
    return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                         sampleRate: sampleRate,
                         interleaved: false,
                         channelLayout: layout)
}

/// A minimal Audio Unit that takes a 2-channel input, applies the cue's
/// master and L/R gain, optionally mono-sums L+R (-3 dB) into one channel,
/// runs the result through the cue's own limiter, and writes it into one or
/// two slots of an N-channel output bus — zero-filling every other channel.
/// This is what gives BandMember per-cue routing onto arbitrary physical
/// outputs of a multi-out interface (e.g. Focusrite 4i4):
///
///   stereo cue   → output channels [start, start+1]
///   mono-sum cue → output channel  [start]            (others silent)
///
/// All other output channels are zeroed every render so cues that share an
/// AVAudioMixer output bus never bleed into each other's destinations.
///
/// The limiter keeps this one cue at or under full scale, so a cue pushed
/// past 100 % only ever squashes itself — it never drags down the other cues
/// playing alongside it. With `limiterEnabled`, the cue is additionally
/// raised by `limiterBoost` and held to the file's own full-scale level
/// before the volume controls, which brings its quiet passages up toward its
/// loud ones. Every cue is delayed by the same look-ahead whether or not its
/// limiter is doing anything, so cues stay sample-aligned with each other.
///
/// All parameters can be changed from the main thread; reads on the audio
/// thread are atomic on ARM64 (Float / Int32 are 4 bytes).
class ChannelGainAU: AUAudioUnit {
    // Per-channel gain on the stereo input.
    private let leftGainPtr: UnsafeMutablePointer<Float>
    private let rightGainPtr: UnsafeMutablePointer<Float>
    // Cue master volume, applied on top of the per-channel gains.
    private let masterGainPtr: UnsafeMutablePointer<Float>

    // Limiter controls. `limiterBoost` is a linear gain (1 = none).
    private let limiterEnabledPtr: UnsafeMutablePointer<Int32>
    private let limiterBoostPtr: UnsafeMutablePointer<Float>

    // Channel-placement controls. `startChannel` is 0-based.
    private let isMonoSumPtr: UnsafeMutablePointer<Int32>
    private let startChannelPtr: UnsafeMutablePointer<Int32>
    private let outputChannelCountPtr: UnsafeMutablePointer<Int32>
    /// When set, the render block emits silence on every output channel
    /// regardless of the input. Used when a cue's bus has no assignment
    /// on the active device — the rest of the chain (mixer, lyrics sync,
    /// autoFollow) keeps running but no audio reaches the device.
    private let isMutedPtr: UnsafeMutablePointer<Int32>

    /// Legacy "mode" parameter: 0 = stereo, 1 = mono-sum (single channel).
    /// Kept as `routing` so existing call sites keep compiling; new code
    /// should use `isMonoSum` + `startChannel` directly.
    private let routingPtr: UnsafeMutablePointer<Int32>

    var leftGain: Float {
        get { leftGainPtr.pointee }
        set { leftGainPtr.pointee = newValue }
    }
    var rightGain: Float {
        get { rightGainPtr.pointee }
        set { rightGainPtr.pointee = newValue }
    }
    var masterGain: Float {
        get { masterGainPtr.pointee }
        set { masterGainPtr.pointee = newValue }
    }
    /// When true, the cue is boosted by `limiterBoost` and limited back to
    /// the file's full-scale level ahead of the volume controls.
    var limiterEnabled: Bool {
        get { limiterEnabledPtr.pointee != 0 }
        set { limiterEnabledPtr.pointee = newValue ? 1 : 0 }
    }
    var limiterBoost: Float {
        get { limiterBoostPtr.pointee }
        set { limiterBoostPtr.pointee = newValue }
    }
    var isMonoSum: Bool {
        get { isMonoSumPtr.pointee != 0 }
        set { isMonoSumPtr.pointee = newValue ? 1 : 0 }
    }
    /// 0-based first physical output channel for this cue's signal.
    var startChannel: Int32 {
        get { startChannelPtr.pointee }
        set { startChannelPtr.pointee = newValue }
    }
    /// Total number of output channels this AU produces. Must match the
    /// output bus format set via `setOutputChannelCount(_:)`.
    var outputChannelCount: Int32 {
        get { outputChannelCountPtr.pointee }
        set { outputChannelCountPtr.pointee = newValue }
    }
    /// When true, the AU outputs silence regardless of input.
    var isMuted: Bool {
        get { isMutedPtr.pointee != 0 }
        set { isMutedPtr.pointee = newValue ? 1 : 0 }
    }
    /// Legacy: 0 = stereo, 1 = mono-sum. Kept for backward compatibility.
    var routing: Int32 {
        get { routingPtr.pointee }
        set {
            routingPtr.pointee = newValue
            isMonoSumPtr.pointee = (newValue == 0) ? 0 : 1
        }
    }

    private let limiter = LookaheadLimiter()
    private let delayL = LimiterDelayLine()
    private let delayR = LimiterDelayLine()
    /// Boost actually in effect, gliding toward `limiterBoost` so dragging
    /// the slider during playback doesn't step the gain.
    private let boostStatePtr: UnsafeMutablePointer<Float>
    private var limiterSampleRate: Double = 48000

    /// Limiter look-ahead, reported so the engine's "finished playing"
    /// callbacks wait for the tail still inside the delay line.
    override var latency: TimeInterval {
        Double(limiter.delaySamples) / limiterSampleRate
    }

    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        leftGainPtr = .allocate(capacity: 1)
        rightGainPtr = .allocate(capacity: 1)
        masterGainPtr = .allocate(capacity: 1)
        limiterEnabledPtr = .allocate(capacity: 1)
        limiterBoostPtr = .allocate(capacity: 1)
        boostStatePtr = .allocate(capacity: 1)
        isMonoSumPtr = .allocate(capacity: 1)
        startChannelPtr = .allocate(capacity: 1)
        outputChannelCountPtr = .allocate(capacity: 1)
        isMutedPtr = .allocate(capacity: 1)
        routingPtr = .allocate(capacity: 1)
        leftGainPtr.initialize(to: 1.0)
        rightGainPtr.initialize(to: 1.0)
        masterGainPtr.initialize(to: 1.0)
        limiterEnabledPtr.initialize(to: 0)
        limiterBoostPtr.initialize(to: 1.0)
        boostStatePtr.initialize(to: -1)
        isMonoSumPtr.initialize(to: 0)
        startChannelPtr.initialize(to: 0)
        outputChannelCountPtr.initialize(to: 2)
        isMutedPtr.initialize(to: 0)
        routingPtr.initialize(to: 0)

        try super.init(componentDescription: componentDescription, options: options)

        // Default formats; reconfigured at engine setup once the chosen
        // CoreAudio device's channel count is known.
        let inFmt  = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let inBus  = try AUAudioUnitBus(format: inFmt)
        let outBus = try AUAudioUnitBus(format: outFmt)
        _inputBusArray  = AUAudioUnitBusArray(audioUnit: self, busType: .input,  busses: [inBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        maximumFramesToRender = 4096

        // Pre-allocate the 2-channel pull buffer now (rather than in
        // `allocateRenderResources`) so it's available before the host
        // reads `internalRenderBlock`. The render closure captures these
        // pointers by value, and if they were still nil at capture time
        // every render call would short-circuit to silence.
        allocatePullBuffer()
        configureLimiter(sampleRate: 48000)
    }

    /// Sizes the limiter's look-ahead for `sampleRate`. The look-ahead is a
    /// fixed time, so cues at different file sample rates stay aligned.
    private func configureLimiter(sampleRate: Double) {
        limiterSampleRate = sampleRate > 0 ? sampleRate : 48000
        limiter.configure(sampleRate: limiterSampleRate)
        delayL.configure(delaySamples: limiter.delaySamples)
        delayR.configure(delaySamples: limiter.delaySamples)
        // Negative = "not started": the first render adopts the requested
        // boost outright rather than gliding up to it from unity.
        boostStatePtr.pointee = -1
    }

    deinit {
        leftGainPtr.deinitialize(count: 1); leftGainPtr.deallocate()
        rightGainPtr.deinitialize(count: 1); rightGainPtr.deallocate()
        masterGainPtr.deinitialize(count: 1); masterGainPtr.deallocate()
        limiterEnabledPtr.deinitialize(count: 1); limiterEnabledPtr.deallocate()
        limiterBoostPtr.deinitialize(count: 1); limiterBoostPtr.deallocate()
        boostStatePtr.deinitialize(count: 1); boostStatePtr.deallocate()
        isMonoSumPtr.deinitialize(count: 1); isMonoSumPtr.deallocate()
        startChannelPtr.deinitialize(count: 1); startChannelPtr.deallocate()
        outputChannelCountPtr.deinitialize(count: 1); outputChannelCountPtr.deallocate()
        isMutedPtr.deinitialize(count: 1); isMutedPtr.deallocate()
        routingPtr.deinitialize(count: 1); routingPtr.deallocate()
        deallocatePullBuffer()
    }

    // MARK: - Output bus reconfiguration

    /// Reconfigures the output bus to produce `n` channels, matching the
    /// CoreAudio device's output channel count. Must be called BEFORE
    /// connecting the AU into an AVAudioEngine graph.
    func setOutputChannelCount(_ n: Int, sampleRate: Double = 48000) throws {
        let safeN = max(1, n)
        guard let fmt = discreteAudioFormat(sampleRate: sampleRate, channels: safeN) else {
            return
        }
        try _outputBusArray[0].setFormat(fmt)
        outputChannelCountPtr.pointee = Int32(safeN)
        configureLimiter(sampleRate: sampleRate)
    }

    // MARK: - Realtime resources

    /// Pre-allocated buffer for pulling 2-channel input. Allocated when the
    /// engine starts the AU and freed on tear-down. Audio-thread-safe to
    /// dereference because it lives until deallocateRenderResources.
    private var pullBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var pullBufferL: UnsafeMutablePointer<Float>?
    private var pullBufferR: UnsafeMutablePointer<Float>?
    /// Scratch for the limiter: signal level going in, gain coming out.
    private var limiterGains: UnsafeMutablePointer<Float>?

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        // Pull buffer is allocated once in init() and lives until deinit,
        // so the render closure can safely capture its pointers without
        // a chicken-and-egg ordering problem between this method and the
        // host's read of `internalRenderBlock`.
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    private func allocatePullBuffer() {
        let frames = Int(maximumFramesToRender)
        let bytes  = frames * MemoryLayout<Float>.size

        let lPtr = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let rPtr = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let gPtr = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        lPtr.initialize(repeating: 0, count: frames)
        rPtr.initialize(repeating: 0, count: frames)
        gPtr.initialize(repeating: 1, count: frames)

        // Allocate an AudioBufferList with 2 buffers (non-interleaved).
        let ablBytes = MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.size  // one extra buffer slot
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablBytes,
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        let abl = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
        ablPtr.unsafeMutablePointer.pointee.mNumberBuffers = 2
        ablPtr[0] = AudioBuffer(mNumberChannels: 1,
                                mDataByteSize: UInt32(bytes),
                                mData: UnsafeMutableRawPointer(lPtr))
        ablPtr[1] = AudioBuffer(mNumberChannels: 1,
                                mDataByteSize: UInt32(bytes),
                                mData: UnsafeMutableRawPointer(rPtr))

        self.pullBufferList = abl
        self.pullBufferL = lPtr
        self.pullBufferR = rPtr
        self.limiterGains = gPtr
    }

    private func deallocatePullBuffer() {
        if let ptr = pullBufferList {
            UnsafeMutableRawPointer(ptr).deallocate()
            pullBufferList = nil
        }
        if let l = pullBufferL { l.deallocate(); pullBufferL = nil }
        if let r = pullBufferR { r.deallocate(); pullBufferR = nil }
        if let g = limiterGains { g.deallocate(); limiterGains = nil }
    }

    // MARK: - Render

    override var internalRenderBlock: AUInternalRenderBlock {
        let leftPtr   = leftGainPtr
        let rightPtr  = rightGainPtr
        let masterPtr = masterGainPtr
        let limiterOnPtr = limiterEnabledPtr
        let boostPtr  = limiterBoostPtr
        let boostState = boostStatePtr
        let monoPtr   = isMonoSumPtr
        let startPtr  = startChannelPtr
        let mutePtr   = isMutedPtr
        let pullABL   = pullBufferList
        let pullL     = pullBufferL
        let pullR     = pullBufferR
        let gains     = limiterGains
        let limiter   = self.limiter
        let delayL    = self.delayL
        let delayR    = self.delayR
        let maxFrames = Int(maximumFramesToRender)
        let pullBytesPerFrame = UInt32(MemoryLayout<Float>.size)

        let monoSumScale: Float = 0.7071068  // -3 dB

        return { actionFlags, timestamp, frameCount, _, outputData,
                 _, pullInputBlock in

            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }
            guard let pullABL = pullABL,
                  let pullL = pullL,
                  let pullR = pullR,
                  let gains = gains else {
                return kAudioUnitErr_Uninitialized
            }
            guard Int(frameCount) <= maxFrames else {
                return kAudioUnitErr_TooManyFramesToProcess
            }

            // Reset our 2-channel pull buffer's byte sizes for this render
            // (they may have been mutated by the upstream node).
            let abl = UnsafeMutableAudioBufferListPointer(pullABL)
            abl[0].mDataByteSize = frameCount * pullBytesPerFrame
            abl[1].mDataByteSize = frameCount * pullBytesPerFrame
            abl[0].mData = UnsafeMutableRawPointer(pullL)
            abl[1].mData = UnsafeMutableRawPointer(pullR)

            // Pull stereo input into our own buffer (separate from the
            // N-channel output buffer).
            let status = pullInputBlock(actionFlags, timestamp, frameCount, 0, pullABL)
            guard status == noErr else { return status }

            let leftGain  = leftPtr.pointee
            let rightGain = rightPtr.pointee
            let monoSum   = monoPtr.pointee != 0
            let start     = Int(startPtr.pointee)
            let frames    = Int(frameCount)
            let n         = vDSP_Length(frames)

            // Everything below works in place on our own pull buffers. If
            // upstream handed back its own memory instead of filling ours
            // (it may point straight into a scheduled, possibly looping,
            // buffer), copy it out rather than scribbling on it.
            let frameBytes = frames * MemoryLayout<Float>.size
            if let src = abl[0].mData, src != UnsafeMutableRawPointer(pullL) {
                memcpy(pullL, src, frameBytes)
            }
            if let src = abl[1].mData, src != UnsafeMutableRawPointer(pullR) {
                memcpy(pullR, src, frameBytes)
            }
            let inL = pullL, inR = pullR

            let outABL    = UnsafeMutableAudioBufferListPointer(outputData)
            let outChannelCount = outABL.count

            // Zero every output channel first — cues sharing a mixer must
            // not bleed signal into each other's destinations.
            for c in 0..<outChannelCount {
                if let data = outABL[c].mData {
                    memset(data, 0, Int(outABL[c].mDataByteSize))
                }
            }

            // Muted: outputs stay zeroed, but the upstream pull above has
            // already advanced the player node, so the cue's scheduled
            // segment still completes on time (autoFollow and lyrics sync
            // depend on that).
            if mutePtr.pointee != 0 {
                return noErr
            }

            // Once the player runs out it flags its output as silence, and
            // the mixer downstream drops any buffer carrying that flag. Our
            // output isn't silent yet — the end of the cue is still inside
            // the delay line — so take the flag back off.
            actionFlags.pointee.remove(.unitRenderAction_OutputIsSilence)

            // Split the volume controls into a balance (the louder side at
            // unity) and a single fader on top. The limiter's boost stage
            // works on the balanced signal, ahead of the fader, so a side
            // that's turned off can't trigger gain reduction and turning the
            // cue down doesn't change how hard it's being leveled.
            let widest = max(leftGain, rightGain)
            let balanceL: Float = widest > 0 ? leftGain / widest : 0
            let balanceR: Float = widest > 0 ? rightGain / widest : 0
            let fader = widest * masterPtr.pointee

            // Boost + balance, in place. The boost glides toward its target
            // (~10 ms) so slider moves and the on/off toggle don't click.
            let limiterOn = limiterOnPtr.pointee != 0
            let boostTarget: Float = limiterOn ? boostPtr.pointee : 1
            var boost = boostState.pointee
            if boost < 0 { boost = boostTarget }  // first render: no glide
            if boost != boostTarget {
                for i in 0..<frames {
                    boost += (boostTarget - boost) * 0.002
                    inL[i] *= boost * balanceL
                    inR[i] *= boost * balanceR
                }
                if abs(boost - boostTarget) < 1e-4 * boostTarget { boost = boostTarget }
            } else {
                var scaleL = boost * balanceL
                var scaleR = boost * balanceR
                if scaleL != 1 { vDSP_vsmul(inL, 1, &scaleL, inL, 1, n) }
                if scaleR != 1 { vDSP_vsmul(inR, 1, &scaleR, inR, 1, n) }
            }
            boostState.pointee = boost

            // Fold to mono ahead of the limiter when that's what this cue
            // sends out, so the limiter sees the signal it has to contain.
            if monoSum {
                var scale = monoSumScale
                vDSP_vadd(inL, 1, inR, 1, inL, 1, n)
                vDSP_vsmul(inL, 1, &scale, inL, 1, n)
                vDSP_vabs(inL, 1, gains, 1, n)
            } else {
                vDSP_vmaxmg(inL, 1, inR, 1, gains, 1, n)
            }

            // One limiter covers both jobs. Scaling the level it sees by the
            // fader holds the *output* at full scale; with the boost stage
            // on, never scaling it below 1 also holds the pre-fader signal at
            // the file's own full scale. Whichever is stricter wins.
            var levelScale: Float = limiterOn ? max(1, fader) : fader
            if levelScale != 1 { vDSP_vsmul(gains, 1, &levelScale, gains, 1, n) }
            let unity = limiter.process(levels: gains, gains: gains, count: frames, ceiling: 1)

            delayL.process(inL, count: frames)
            if !monoSum { delayR.process(inR, count: frames) }

            var faderGain = fader

            // Compute placement. Clamp so an out-of-range startChannel
            // (e.g. saved for a 4-out device but loaded on a 2-out device)
            // still produces audible signal at channel 0 instead of silence.
            let needed = monoSum ? 1 : 2
            var s = start
            if s < 0 { s = 0 }
            if s + needed > outChannelCount { s = max(0, outChannelCount - needed) }

            if monoSum {
                // Summed L+R → start channel.
                guard s < outChannelCount,
                      let dst = outABL[s].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                if unity {
                    vDSP_vsmul(inL, 1, &faderGain, dst, 1, n)
                } else {
                    vDSP_vmul(inL, 1, gains, 1, dst, 1, n)
                    if faderGain != 1 { vDSP_vsmul(dst, 1, &faderGain, dst, 1, n) }
                }
            } else {
                // Stereo placement: L → start, R → start+1.
                guard s + 1 < outChannelCount,
                      let dstL = outABL[s].mData?.assumingMemoryBound(to: Float.self),
                      let dstR = outABL[s + 1].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                if unity && faderGain == 1 {
                    memcpy(dstL, inL, frameBytes)
                    memcpy(dstR, inR, frameBytes)
                } else if unity {
                    vDSP_vsmul(inL, 1, &faderGain, dstL, 1, n)
                    vDSP_vsmul(inR, 1, &faderGain, dstR, 1, n)
                } else {
                    vDSP_vmul(inL, 1, gains, 1, dstL, 1, n)
                    vDSP_vmul(inR, 1, gains, 1, dstR, 1, n)
                    if faderGain != 1 {
                        vDSP_vsmul(dstL, 1, &faderGain, dstL, 1, n)
                        vDSP_vsmul(dstR, 1, &faderGain, dstR, 1, n)
                    }
                }
            }

            return noErr
        }
    }
}
