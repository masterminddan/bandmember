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

/// A minimal Audio Unit that applies independent left/right channel gain.
/// Used inline in an AVAudioEngine graph for per-channel volume control.
/// Gain values can be changed at any time from the main thread — reads are
/// atomic on ARM64 (Float is 4 bytes).
class ChannelGainAU: AUAudioUnit {
    // Gains stored as raw pointers so the render block can capture them
    // without retaining `self` (render block runs on the audio thread).
    private let leftGainPtr: UnsafeMutablePointer<Float>
    private let rightGainPtr: UnsafeMutablePointer<Float>

    var leftGain: Float {
        get { leftGainPtr.pointee }
        set { leftGainPtr.pointee = newValue }
    }
    var rightGain: Float {
        get { rightGainPtr.pointee }
        set { rightGainPtr.pointee = newValue }
    }

    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        leftGainPtr = .allocate(capacity: 1)
        rightGainPtr = .allocate(capacity: 1)
        leftGainPtr.initialize(to: 1.0)
        rightGainPtr.initialize(to: 1.0)

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
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Capture only the raw pointers — no `self` reference on the audio thread.
        let leftPtr  = leftGainPtr
        let rightPtr = rightGainPtr

        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData,
                 renderEvent, pullInputBlock in

            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }

            // Pull audio from the upstream node into outputData.
            let status = pullInputBlock(actionFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let left  = leftPtr.pointee
            let right = rightPtr.pointee

            // Fast path: unity gain, nothing to do.
            if left == 1.0 && right == 1.0 { return noErr }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)

            if abl.count >= 2 {
                // Non-interleaved stereo (standard AVAudioEngine format)
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
                // Interleaved stereo
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
    }
}
