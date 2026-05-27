import AVFoundation
import CoreMedia

/// Decodes an audio asset's full PCM stream via `AVAssetReader` into a
/// non-interleaved float32 `AVAudioPCMBuffer` matching `processingFormat`.
///
/// We reach for this instead of `AVAudioFile`-based scheduling for MP3 and
/// AAC, where `AVAudioFile.length` undercounts decoded frames (encoder
/// priming + padding are dropped), clipping ~1s off the tail. `AVAssetReader`
/// emits every PCM frame the asset can produce, matching what
/// `AVAudioPlayer` would render.
///
/// Synchronous on the calling thread. A 100-second stereo file at 48 kHz
/// allocates ~38 MB and takes a few hundred ms to decode. Caller owns the
/// returned buffer.
func decodeFullAssetBuffer(url: URL,
                           processingFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let asset = AVURLAsset(url: url)
    let assetDuration = CMTimeGetSeconds(asset.duration)
    guard assetDuration.isFinite, assetDuration > 0 else {
        debugLog("[ASSET-DECODE] \(url.lastPathComponent): asset duration unknown")
        return nil
    }
    guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
        debugLog("[ASSET-DECODE] \(url.lastPathComponent): no audio track")
        return nil
    }

    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        debugLog("[ASSET-DECODE] AVAssetReader init failed: \(error)")
        return nil
    }

    let chCount = Int(processingFormat.channelCount)
    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: processingFormat.sampleRate,
        AVNumberOfChannelsKey: chCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let trackOutput = AVAssetReaderTrackOutput(track: audioTrack,
                                                outputSettings: outputSettings)
    reader.add(trackOutput)
    guard reader.startReading() else {
        debugLog("[ASSET-DECODE] startReading failed: \(reader.error?.localizedDescription ?? "?")")
        return nil
    }

    // 5 % headroom on the nominal duration covers padding the reader may
    // emit past the metadata-reported end.
    let estCap = AVAudioFrameCount((assetDuration * processingFormat.sampleRate * 1.05).rounded(.up))
    guard estCap > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                        frameCapacity: estCap) else {
        debugLog("[ASSET-DECODE] PCM buffer alloc failed (cap=\(estCap))")
        return nil
    }

    var totalFrames: AVAudioFrameCount = 0
    while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

        if totalFrames + frames > buffer.frameCapacity {
            debugLog("[ASSET-DECODE] capacity exceeded at \(totalFrames + frames) (cap=\(buffer.frameCapacity)); truncating")
            break
        }

        var dataPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: nil,
                                                 totalLengthOut: nil,
                                                 dataPointerOut: &dataPtr)
        guard status == kCMBlockBufferNoErr, let dataPtr = dataPtr else { continue }

        // Interleaved float source → deinterleave into per-channel
        // destinations of the non-interleaved AVAudioPCMBuffer.
        let interleaved = dataPtr.withMemoryRebound(to: Float.self,
                                                    capacity: Int(frames) * chCount) { $0 }
        guard let channelData = buffer.floatChannelData else { continue }
        let dstOffset = Int(totalFrames)
        for c in 0..<chCount {
            let dst = channelData[c].advanced(by: dstOffset)
            for f in 0..<Int(frames) {
                dst[f] = interleaved[f * chCount + c]
            }
        }
        totalFrames += frames
    }

    if reader.status == .failed {
        debugLog("[ASSET-DECODE] read failed: \(reader.error?.localizedDescription ?? "?")")
        return nil
    }
    buffer.frameLength = totalFrames
    return buffer
}

/// Returns a copy of `source` starting at `startFrame`. For `startFrame == 0`
/// returns the source itself (no copy). Returns nil if the start is out of
/// range or allocation fails.
func sliceBufferFromFrame(_ source: AVAudioPCMBuffer,
                          startFrame: Int) -> AVAudioPCMBuffer? {
    let sourceFrames = Int(source.frameLength)
    guard startFrame >= 0, startFrame < sourceFrames else { return nil }
    if startFrame == 0 { return source }

    let outFrames = AVAudioFrameCount(sourceFrames - startFrame)
    guard let dest = AVAudioPCMBuffer(pcmFormat: source.format,
                                      frameCapacity: outFrames) else { return nil }
    let chCount = Int(source.format.channelCount)
    if let srcCh = source.floatChannelData, let dstCh = dest.floatChannelData {
        for c in 0..<chCount {
            memcpy(dstCh[c],
                   srcCh[c].advanced(by: startFrame),
                   Int(outFrames) * MemoryLayout<Float>.size)
        }
    }
    dest.frameLength = outFrames
    return dest
}
