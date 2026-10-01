import Accelerate
import AudioToolbox
import AVFoundation

/// AudioComponentDescription used to register and instantiate SafetyLimiterAU.
let safetyLimiterComponentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: 0x73666C6D,       // 'sflm'
    componentManufacturer: 0x41564C50,  // 'AVLP'
    componentFlags: 0,
    componentFlagsMask: 0
)

/// Last-resort limiter on the final N-channel output bus. Each cue already
/// limits itself (see `ChannelGainAU`), so this only has work to do when
/// several cues stack up past full scale on the same physical output.
///
/// Every output channel gets its own independent limiter. A linked limiter
/// turns all channels down together whenever any one of them peaks, which on
/// a multi-out rig means a hot click in the IEMs audibly pumps the FOH mix on
/// completely different outputs. Unlinked, an overload stays on the output
/// where it happened.
class SafetyLimiterAU: AUAudioUnit {
    /// Per-channel limiter state. Built on the main thread in `configure`
    /// before the unit is connected, then only read by the render block.
    private final class Channels {
        let count: Int
        let limiters: [LookaheadLimiter]
        let delays: [LimiterDelayLine]
        let gains: UnsafeMutablePointer<Float>
        let maxFrames: Int

        init(count: Int, sampleRate: Double, maxFrames: Int) {
            self.count = count
            self.maxFrames = maxFrames
            limiters = (0..<count).map { _ in
                let limiter = LookaheadLimiter()
                limiter.configure(sampleRate: sampleRate)
                return limiter
            }
            delays = limiters.map {
                let delay = LimiterDelayLine()
                delay.configure(delaySamples: $0.delaySamples)
                return delay
            }
            gains = .allocate(capacity: maxFrames)
            gains.initialize(repeating: 1, count: maxFrames)
        }

        deinit { gains.deallocate() }
    }

    /// Box the render block captures once; `configure` swaps its contents.
    private final class ChannelsBox {
        var channels: Channels?
    }
    private let box = ChannelsBox()
    private var sampleRate: Double = 48000

    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override var latency: TimeInterval {
        Double(box.channels?.limiters.first?.delaySamples ?? 0) / sampleRate
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let inBus  = try AUAudioUnitBus(format: fmt)
        let outBus = try AUAudioUnitBus(format: fmt)
        _inputBusArray  = AUAudioUnitBusArray(audioUnit: self, busType: .input,  busses: [inBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        maximumFramesToRender = 4096
        try configure(channelCount: 2, sampleRate: 48000)
    }

    /// Sets both buses to `channelCount` channels at `sampleRate` and builds
    /// one limiter per channel. Must be called BEFORE connecting the AU into
    /// an AVAudioEngine graph.
    func configure(channelCount: Int, sampleRate: Double) throws {
        let safeN = max(1, channelCount)
        let rate = sampleRate > 0 ? sampleRate : 48000
        guard let fmt = discreteAudioFormat(sampleRate: rate, channels: safeN) else {
            return
        }
        try _inputBusArray[0].setFormat(fmt)
        try _outputBusArray[0].setFormat(fmt)
        self.sampleRate = rate
        box.channels = Channels(count: safeN, sampleRate: rate,
                                maxFrames: Int(maximumFramesToRender))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let box = self.box

        return { actionFlags, timestamp, frameCount, _, outputData,
                 _, pullInputBlock in

            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }
            guard let channels = box.channels else {
                return kAudioUnitErr_Uninitialized
            }
            let frames = Int(frameCount)
            guard frames <= channels.maxFrames else {
                return kAudioUnitErr_TooManyFramesToProcess
            }

            // Same channel count in and out, so pull the input straight
            // into the output buffers and limit it there.
            let status = pullInputBlock(actionFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            // A silent input doesn't mean a silent output: the last few
            // milliseconds are still inside the delay lines.
            actionFlags.pointee.remove(.unitRenderAction_OutputIsSilence)

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let n = vDSP_Length(frames)
            let gains = channels.gains
            var ceiling: Float = 1
            var floor: Float = -1

            for c in 0..<min(abl.count, channels.count) {
                guard let data = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                vDSP_vabs(data, 1, gains, 1, n)
                let unity = channels.limiters[c].process(levels: gains, gains: gains,
                                                         count: frames, ceiling: ceiling)
                channels.delays[c].process(data, count: frames)
                if !unity {
                    vDSP_vmul(data, 1, gains, 1, data, 1, n)
                    // The gain math is good to a rounding error; pin the
                    // result so "at or under full scale" holds exactly.
                    vDSP_vclip(data, 1, &floor, &ceiling, data, 1, n)
                }
            }

            return noErr
        }
    }
}
