import AVFoundation
import MediaToolbox
import CoreMedia
import AudioToolbox

/// Applies independent left/right channel volume to an AVPlayerItem
/// using MTAudioProcessingTap for real-time audio buffer manipulation.
/// If the tap cannot be created, playback continues without L/R control.
class ChannelVolumeProcessor {
    var leftVolume: Float
    var rightVolume: Float

    init(leftVolume: Float = 1.0, rightVolume: Float = 1.0) {
        self.leftVolume = leftVolume
        self.rightVolume = rightVolume
    }

    /// Attaches an audio processing tap to the player item for L/R volume control.
    /// Returns true if the tap was successfully applied, false otherwise.
    /// Playback works either way — the tap is optional.
    @discardableResult
    func applyToPlayerItem(_ playerItem: AVPlayerItem) -> Bool {
        let asset = playerItem.asset
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            debugLog("BandMember: No audio tracks found in asset")
            return false
        }

        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        let clientInfo = Unmanaged.passRetained(self).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: channelTapInit,
            finalize: channelTapFinalize,
            prepare: channelTapPrepare,
            unprepare: channelTapUnprepare,
            process: channelTapProcess
        )

        // The out-param's Swift type depends on the SDK: older SDKs import
        // it as `Unmanaged<MTAudioProcessingTap>?`, the Xcode 26.6 SDK as a
        // managed `MTAudioProcessingTap?`. `createTap` infers whichever one
        // this SDK uses and `ownedTap` normalizes it, so the same source
        // builds on both.
        let (status, rawTap) = createTap {
            MTAudioProcessingTapCreate(
                kCFAllocatorDefault,
                &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects,
                $0
            )
        }

        guard status == noErr, let unwrappedTap = ownedTap(rawTap) else {
            debugLog("BandMember: MTAudioProcessingTapCreate failed with status \(status)")
            Unmanaged<ChannelVolumeProcessor>.fromOpaque(clientInfo).release()
            return false
        }

        inputParams.audioTapProcessor = unwrappedTap

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [inputParams]
        playerItem.audioMix = audioMix
        return true
    }
}

// MARK: - SDK-agnostic tap creation

/// Calls `create` with an out-pointer whose pointee type is inferred from
/// the callee, and returns the status plus whatever was written.
private func createTap<T>(_ create: (UnsafeMutablePointer<T?>) -> OSStatus) -> (OSStatus, T?) {
    var out: T? = nil
    let status = create(&out)
    return (status, out)
}

/// Older SDKs: the tap comes back +1 as `Unmanaged`; take ownership.
private func ownedTap(_ tap: Unmanaged<MTAudioProcessingTap>?) -> MTAudioProcessingTap? {
    tap?.takeRetainedValue()
}

/// Newer SDKs: the tap is already imported as a managed reference.
private func ownedTap(_ tap: MTAudioProcessingTap?) -> MTAudioProcessingTap? {
    tap
}

// MARK: - MTAudioProcessingTap C Callbacks

private let channelTapInit: MTAudioProcessingTapInitCallback = { tap, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let channelTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<ChannelVolumeProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let channelTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, processingFormat in
}

private let channelTapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
}

private let channelTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
    // Pull source audio — this MUST succeed for audio to play
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
    )
    // If source audio fails, buffer already has whatever the system put there.
    // Do NOT return early — that would produce silence.
    guard status == noErr else { return }

    let processor = Unmanaged<ChannelVolumeProcessor>.fromOpaque(
        MTAudioProcessingTapGetStorage(tap)
    ).takeUnretainedValue()

    let leftGain = processor.leftVolume
    let rightGain = processor.rightVolume

    // Fast path: skip processing if both at unity
    if leftGain == 1.0 && rightGain == 1.0 { return }

    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)

    if abl.count >= 2 {
        // Non-interleaved: each buffer is one channel
        for channelIndex in 0..<min(abl.count, 2) {
            let gain = channelIndex == 0 ? leftGain : rightGain
            if gain == 1.0 { continue }

            let buffer = abl[channelIndex]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

            if gain == 0.0 {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            } else {
                for i in 0..<sampleCount {
                    data[i] *= gain
                }
            }
        }
    } else if abl.count == 1 {
        // Interleaved: L R L R ...
        let buffer = abl[0]
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

        var i = 0
        while i < sampleCount - 1 {
            data[i] *= leftGain
            data[i + 1] *= rightGain
            i += 2
        }
    }
}
