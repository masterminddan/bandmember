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

/// A minimal Audio Unit that takes a 2-channel input, applies independent
/// L/R gain, optionally mono-sums L+R (-3 dB) into one channel, and writes
/// the result into one or two slots of an N-channel output bus — zero-filling
/// every other channel. This is what gives BandMember per-cue routing onto
/// arbitrary physical outputs of a multi-out interface (e.g. Focusrite 4i4):
///
///   stereo cue   → output channels [start, start+1]
///   mono-sum cue → output channel  [start]            (others silent)
///
/// All other output channels are zeroed every render so cues that share an
/// AVAudioMixer output bus never bleed into each other's destinations.
///
/// All parameters can be changed from the main thread; reads on the audio
/// thread are atomic on ARM64 (Float / Int32 are 4 bytes).
class ChannelGainAU: AUAudioUnit {
    // Per-channel gain on the stereo input.
    private let leftGainPtr: UnsafeMutablePointer<Float>
    private let rightGainPtr: UnsafeMutablePointer<Float>

    // Channel-placement controls. `startChannel` is 0-based.
    private let isMonoSumPtr: UnsafeMutablePointer<Int32>
    private let startChannelPtr: UnsafeMutablePointer<Int32>
    private let outputChannelCountPtr: UnsafeMutablePointer<Int32>

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
    /// Legacy: 0 = stereo, 1 = mono-sum. Kept for backward compatibility.
    var routing: Int32 {
        get { routingPtr.pointee }
        set {
            routingPtr.pointee = newValue
            isMonoSumPtr.pointee = (newValue == 0) ? 0 : 1
        }
    }

    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        leftGainPtr = .allocate(capacity: 1)
        rightGainPtr = .allocate(capacity: 1)
        isMonoSumPtr = .allocate(capacity: 1)
        startChannelPtr = .allocate(capacity: 1)
        outputChannelCountPtr = .allocate(capacity: 1)
        routingPtr = .allocate(capacity: 1)
        leftGainPtr.initialize(to: 1.0)
        rightGainPtr.initialize(to: 1.0)
        isMonoSumPtr.initialize(to: 0)
        startChannelPtr.initialize(to: 0)
        outputChannelCountPtr.initialize(to: 2)
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
    }

    deinit {
        leftGainPtr.deinitialize(count: 1); leftGainPtr.deallocate()
        rightGainPtr.deinitialize(count: 1); rightGainPtr.deallocate()
        isMonoSumPtr.deinitialize(count: 1); isMonoSumPtr.deallocate()
        startChannelPtr.deinitialize(count: 1); startChannelPtr.deallocate()
        outputChannelCountPtr.deinitialize(count: 1); outputChannelCountPtr.deallocate()
        routingPtr.deinitialize(count: 1); routingPtr.deallocate()
        deallocatePullBuffer()
    }

    // MARK: - Output bus reconfiguration

    /// Reconfigures the output bus to produce `n` channels, matching the
    /// CoreAudio device's output channel count. Must be called BEFORE
    /// connecting the AU into an AVAudioEngine graph.
    func setOutputChannelCount(_ n: Int, sampleRate: Double = 48000) throws {
        let safeN = max(1, n)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(safeN),
                                      interleaved: false) else {
            return
        }
        try _outputBusArray[0].setFormat(fmt)
        outputChannelCountPtr.pointee = Int32(safeN)
    }

    // MARK: - Realtime resources

    /// Pre-allocated buffer for pulling 2-channel input. Allocated when the
    /// engine starts the AU and freed on tear-down. Audio-thread-safe to
    /// dereference because it lives until deallocateRenderResources.
    private var pullBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var pullBufferL: UnsafeMutablePointer<Float>?
    private var pullBufferR: UnsafeMutablePointer<Float>?

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
        lPtr.initialize(repeating: 0, count: frames)
        rPtr.initialize(repeating: 0, count: frames)

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
    }

    private func deallocatePullBuffer() {
        if let ptr = pullBufferList {
            UnsafeMutableRawPointer(ptr).deallocate()
            pullBufferList = nil
        }
        if let l = pullBufferL { l.deallocate(); pullBufferL = nil }
        if let r = pullBufferR { r.deallocate(); pullBufferR = nil }
    }

    // MARK: - Render

    override var internalRenderBlock: AUInternalRenderBlock {
        let leftPtr   = leftGainPtr
        let rightPtr  = rightGainPtr
        let monoPtr   = isMonoSumPtr
        let startPtr  = startChannelPtr
        let pullABL   = pullBufferList
        let pullL     = pullBufferL
        let pullR     = pullBufferR
        let pullBytesPerFrame = UInt32(MemoryLayout<Float>.size)

        let monoSumScale: Float = 0.7071068  // -3 dB

        return { actionFlags, timestamp, frameCount, _, outputData,
                 _, pullInputBlock in

            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }
            guard let pullABL = pullABL,
                  let pullL = pullL,
                  let pullR = pullR else {
                return kAudioUnitErr_Uninitialized
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

            let outABL    = UnsafeMutableAudioBufferListPointer(outputData)
            let outChannelCount = outABL.count

            // Zero every output channel first — cues sharing a mixer must
            // not bleed signal into each other's destinations.
            for c in 0..<outChannelCount {
                if let data = outABL[c].mData {
                    memset(data, 0, Int(outABL[c].mDataByteSize))
                }
            }

            // Compute placement. Clamp so an out-of-range startChannel
            // (e.g. saved for a 4-out device but loaded on a 2-out device)
            // still produces audible signal at channel 0 instead of silence.
            let needed = monoSum ? 1 : 2
            var s = start
            if s < 0 { s = 0 }
            if s + needed > outChannelCount { s = max(0, outChannelCount - needed) }

            if monoSum {
                // Sum L+R → start channel.
                guard s < outChannelCount,
                      let dst = outABL[s].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                let scale = monoSumScale
                for i in 0..<frames {
                    let l = pullL[i] * leftGain
                    let r = pullR[i] * rightGain
                    dst[i] = (l + r) * scale
                }
            } else {
                // Stereo placement: L → start, R → start+1.
                guard s + 1 < outChannelCount,
                      let dstL = outABL[s].mData?.assumingMemoryBound(to: Float.self),
                      let dstR = outABL[s + 1].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                if leftGain == 1.0 {
                    memcpy(dstL, pullL, frames * MemoryLayout<Float>.size)
                } else {
                    for i in 0..<frames { dstL[i] = pullL[i] * leftGain }
                }
                if rightGain == 1.0 {
                    memcpy(dstR, pullR, frames * MemoryLayout<Float>.size)
                } else {
                    for i in 0..<frames { dstR[i] = pullR[i] * rightGain }
                }
            }

            return noErr
        }
    }
}
