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

/// A minimal Audio Unit that applies independent left/right channel gain
/// and optional mono-sum routing. Used inline in an AVAudioEngine graph for
/// per-channel volume control and live "L→IEMs / R→PA" splits.
///
/// Routing modes:
/// - 0 (stereo)     — pass L*leftGain to L, R*rightGain to R (default).
/// - 1 (mono→Left)  — sum L+R, attenuate -3 dB, output to L (R muted). leftGain scales the sum.
/// - 2 (mono→Right) — sum L+R, attenuate -3 dB, output to R (L muted). rightGain scales the sum.
///
/// Values can be changed at any time from the main thread — reads are atomic
/// on ARM64 (Float and Int32 are 4 bytes).
class ChannelGainAU: AUAudioUnit {
    // Gains and routing mode stored as raw pointers so the render block can
    // capture them without retaining `self` (render block runs on audio thread).
    private let leftGainPtr: UnsafeMutablePointer<Float>
    private let rightGainPtr: UnsafeMutablePointer<Float>
    private let routingPtr: UnsafeMutablePointer<Int32>

    var leftGain: Float {
        get { leftGainPtr.pointee }
        set { leftGainPtr.pointee = newValue }
    }
    var rightGain: Float {
        get { rightGainPtr.pointee }
        set { rightGainPtr.pointee = newValue }
    }
    /// 0 = stereo, 1 = mono→Left, 2 = mono→Right. Must match `OutputRouting.auMode`.
    var routing: Int32 {
        get { routingPtr.pointee }
        set { routingPtr.pointee = newValue }
    }

    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        leftGainPtr = .allocate(capacity: 1)
        rightGainPtr = .allocate(capacity: 1)
        routingPtr  = .allocate(capacity: 1)
        leftGainPtr.initialize(to: 1.0)
        rightGainPtr.initialize(to: 1.0)
        routingPtr.initialize(to: 0)  // stereo by default

        try super.init(componentDescription: componentDescription, options: options)

        // Default format — AVAudioEngine will negotiate the actual format on connect.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let inBus  = try AUAudioUnitBus(format: fmt)
        let outBus = try AUAudioUnitBus(format: fmt)
        _inputBusArray  = AUAudioUnitBusArray(audioUnit: self, busType: .input,  busses: [inBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        maximumFramesToRender = 4096
    }

    deinit {
        leftGainPtr.deinitialize(count: 1)
        leftGainPtr.deallocate()
        rightGainPtr.deinitialize(count: 1)
        rightGainPtr.deallocate()
        routingPtr.deinitialize(count: 1)
        routingPtr.deallocate()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Capture only the raw pointers — no `self` reference on the audio thread.
        let leftPtr   = leftGainPtr
        let rightPtr  = rightGainPtr
        let routePtr  = routingPtr

        // Energy-correct -3 dB pad applied to mono-sum so a centered source
        // (L == R) rises ~+3 dB after summing rather than +6 dB clipping risk.
        let monoSumScale: Float = 0.7071068

        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData,
                 renderEvent, pullInputBlock in

            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }

            // Pull audio from the upstream node into outputData.
            let status = pullInputBlock(actionFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let left   = leftPtr.pointee
            let right  = rightPtr.pointee
            let mode   = routePtr.pointee
            let abl    = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)

            if mode == 0 {
                // ── Stereo passthrough with per-channel gain ──────────────
                if left == 1.0 && right == 1.0 { return noErr }
                if abl.count >= 2 {
                    if let buf = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                        if left == 0.0 {
                            memset(abl[0].mData!, 0, Int(abl[0].mDataByteSize))
                        } else {
                            for i in 0..<frames { buf[i] *= left }
                        }
                    }
                    if let buf = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                        if right == 0.0 {
                            memset(abl[1].mData!, 0, Int(abl[1].mDataByteSize))
                        } else {
                            for i in 0..<frames { buf[i] *= right }
                        }
                    }
                } else if abl.count == 1 {
                    if let buf = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                        var i = 0
                        let total = frames * 2
                        while i < total - 1 {
                            buf[i]     *= left
                            buf[i + 1] *= right
                            i += 2
                        }
                    }
                }
                return noErr
            }

            // ── Mono-sum modes: combine L+R into one output channel ──────
            // mode 1 = output to LEFT (right muted), gain = leftGain
            // mode 2 = output to RIGHT (left muted), gain = rightGain
            let outGain = (mode == 1) ? left : right
            let scale   = monoSumScale * outGain

            if abl.count >= 2 {
                // Non-interleaved stereo (standard AVAudioEngine format)
                guard
                    let lBuf = abl[0].mData?.assumingMemoryBound(to: Float.self),
                    let rBuf = abl[1].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }

                if mode == 1 {
                    for i in 0..<frames {
                        lBuf[i] = (lBuf[i] + rBuf[i]) * scale
                    }
                    memset(abl[1].mData!, 0, Int(abl[1].mDataByteSize))
                } else { // mode == 2
                    for i in 0..<frames {
                        rBuf[i] = (lBuf[i] + rBuf[i]) * scale
                    }
                    memset(abl[0].mData!, 0, Int(abl[0].mDataByteSize))
                }
            } else if abl.count == 1 {
                // Interleaved stereo: rewrite in-place.
                guard let buf = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }
                var i = 0
                let total = frames * 2
                if mode == 1 {
                    while i < total - 1 {
                        let mono = (buf[i] + buf[i + 1]) * scale
                        buf[i]     = mono
                        buf[i + 1] = 0
                        i += 2
                    }
                } else { // mode == 2
                    while i < total - 1 {
                        let mono = (buf[i] + buf[i + 1]) * scale
                        buf[i]     = 0
                        buf[i + 1] = mono
                        i += 2
                    }
                }
            }

            return noErr
        }
    }
}
