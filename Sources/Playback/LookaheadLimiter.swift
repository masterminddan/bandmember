import Accelerate
import Foundation

/// Gain computer for a look-ahead brick-wall limiter with a program-dependent
/// release. Feed it the signal's level one sample at a time and it returns the
/// gain to apply to that signal *delayed by `delaySamples`* — the delay is what
/// lets the gain get out of the way before a peak arrives, instead of clipping
/// the first few samples of it.
///
/// The reduction is the larger of two envelopes:
///
///   fast — tracks every peak and lets go within tens of milliseconds, so a
///          stray transient (a click, a snare hit) only ducks itself.
///   slow — charges only while the limiter stays busy, then holds for a
///          moment before letting go, so a sustained loud passage is turned
///          down as a whole instead of having every peak shaved off and the
///          gaps between phrases pumped back up.
///
/// That combination is what lets one unit act as both a transparent safety
/// ceiling and, when driven hard on purpose, a leveler.
///
/// Used per cue inside `ChannelGainAU` and per output channel inside
/// `SafetyLimiterAU`. All storage is allocated in `init`; `process` is
/// real-time safe.
final class LookaheadLimiter {
    static let lookaheadSeconds: Double = 0.005
    private static let maxSampleRate: Double = 192_000

    private static let fastReleaseSeconds: Double = 0.08
    private static let slowChargeSeconds: Double  = 0.12
    static let slowHoldSeconds: Double    = 0.6
    static let slowReleaseSeconds: Double = 0.5

    /// Reductions smaller than this (dB) are treated as none, so a signal
    /// that merely touches the ceiling passes through bit-exact.
    private static let floorDB: Float = 0.001

    /// How far behind the level input the audio path must run.
    private(set) var delaySamples: Int = 0

    /// Reduction applied to the most recent sample, in dB (0 = idle).
    private(set) var reductionDB: Float = 0

    private let capacity: Int
    private var window: Int = 1
    private var fastCoef: Float = 0
    private var chargeCoef: Float = 1
    private var slowCoef: Float = 0
    private var holdSamples = 0

    // Sliding maximum of the required reduction over the look-ahead window,
    // kept as a monotonic deque of (sample index, value) in a ring.
    private let dqIndex: UnsafeMutablePointer<Int>
    private let dqValue: UnsafeMutablePointer<Float>
    private var dqHead = 0
    private var dqCount = 0

    // Moving average over the same window. Averaging the held envelope is
    // what turns an instant gain step into a ramp that completes exactly as
    // the peak leaves the delay line.
    private let box: UnsafeMutablePointer<Float>
    private var boxPos = 0
    private var boxSum: Double = 0
    private var boxActive = 0

    private var fast: Float = 0
    private var slow: Float = 0
    private var holdLeft = 0
    private var clock = 0

    init() {
        capacity = Int(Self.lookaheadSeconds * Self.maxSampleRate) + 2
        dqIndex = .allocate(capacity: capacity)
        dqValue = .allocate(capacity: capacity)
        box     = .allocate(capacity: capacity)
        dqIndex.initialize(repeating: 0, count: capacity)
        dqValue.initialize(repeating: 0, count: capacity)
        box.initialize(repeating: 0, count: capacity)
        configure(sampleRate: 48000)
    }

    deinit {
        dqIndex.deallocate()
        dqValue.deallocate()
        box.deallocate()
    }

    /// Sets the time constants for `sampleRate` and clears all state. Call
    /// before rendering starts, never while `process` may be running.
    func configure(sampleRate: Double) {
        let sr = sampleRate > 0 ? sampleRate : 48000
        delaySamples = min(capacity - 2, max(1, Int((Self.lookaheadSeconds * sr).rounded())))
        window = delaySamples + 1
        fastCoef   = Float(exp(-1.0 / (Self.fastReleaseSeconds * sr)))
        chargeCoef = Float(1.0 - exp(-1.0 / (Self.slowChargeSeconds * sr)))
        slowCoef   = Float(exp(-1.0 / (Self.slowReleaseSeconds * sr)))
        holdSamples = Int(Self.slowHoldSeconds * sr)
        reset()
    }

    func reset() {
        dqHead = 0
        dqCount = 0
        box.update(repeating: 0, count: capacity)
        boxPos = 0
        boxSum = 0
        boxActive = 0
        fast = 0
        slow = 0
        holdLeft = 0
        clock = 0
        reductionDB = 0
    }

    /// Reads `count` linear levels (≥ 0) from `levels` and writes the linear
    /// gain that keeps the delayed signal at or under `ceiling` to `gains`.
    /// The two pointers may be the same buffer. Returns true when every gain
    /// written is exactly 1, so the caller can skip applying them.
    @discardableResult
    func process(levels: UnsafePointer<Float>,
                 gains: UnsafeMutablePointer<Float>,
                 count: Int,
                 ceiling: Float) -> Bool {
        guard count > 0 else { return true }

        // Idle and the whole block is under the ceiling — by far the common
        // case for a cue that isn't being pushed. Skip the per-sample loop.
        if dqCount == 0 && fast == 0 && slow == 0 && boxActive == 0 {
            var blockPeak: Float = 0
            vDSP_maxv(levels, 1, &blockPeak, vDSP_Length(count))
            if blockPeak <= ceiling {
                var one: Float = 1
                vDSP_vfill(&one, gains, 1, vDSP_Length(count))
                clock += count
                boxPos = (boxPos + count) % window
                reductionDB = 0
                return true
            }
        }

        // Work on locals so the per-sample loop doesn't go through the
        // object for every read and write.
        let window = self.window, capacity = self.capacity
        let fastCoef = self.fastCoef, chargeCoef = self.chargeCoef, slowCoef = self.slowCoef
        let holdSamples = self.holdSamples
        let dqIndex = self.dqIndex, dqValue = self.dqValue, box = self.box
        let floorDB = Self.floorDB
        var dqHead = self.dqHead, dqCount = self.dqCount
        var boxPos = self.boxPos, boxSum = self.boxSum, boxActive = self.boxActive
        var fast = self.fast, slow = self.slow, holdLeft = self.holdLeft, clock = self.clock
        var reduction: Float = self.reductionDB
        var unity = true

        let invCeiling = 1 / ceiling
        let dbToNeper: Float = -0.1151292546  // -ln(10) / 20
        let invWindow = 1.0 / Double(window)

        for i in 0..<count {
            let level = levels[i]
            var need: Float = 0
            if level > ceiling {
                need = 20 * log10f(level * invCeiling)
                if need < floorDB { need = 0 }
            }

            // Nothing over the ceiling now, and nothing still releasing:
            // unity gain, no bookkeeping needed.
            if need == 0 && dqCount == 0 && fast == 0 && slow == 0 && boxActive == 0 {
                gains[i] = 1
                clock += 1
                boxPos += 1
                if boxPos == window { boxPos = 0 }
                reduction = 0
                continue
            }

            // Sliding max over the last `window` samples.
            if need > 0 {
                while dqCount > 0 {
                    var back = dqHead + dqCount - 1
                    if back >= capacity { back -= capacity }
                    if dqValue[back] <= need { dqCount -= 1 } else { break }
                }
                var slot = dqHead + dqCount
                if slot >= capacity { slot -= capacity }
                dqIndex[slot] = clock
                dqValue[slot] = need
                dqCount += 1
            }
            if dqCount > 0 && dqIndex[dqHead] <= clock - window {
                dqHead += 1
                if dqHead == capacity { dqHead = 0 }
                dqCount -= 1
            }
            let held: Float = dqCount > 0 ? dqValue[dqHead] : 0

            fast = max(held, fast * fastCoef)
            if fast < floorDB { fast = 0 }
            if fast > slow {
                slow += (fast - slow) * chargeCoef
                holdLeft = holdSamples
            } else if holdLeft > 0 {
                holdLeft -= 1
            } else {
                slow *= slowCoef
                if slow < floorDB { slow = 0 }
            }
            let target = max(fast, slow)

            let old = box[boxPos]
            box[boxPos] = target
            boxPos += 1
            if boxPos == window { boxPos = 0 }
            if old > 0 { boxActive -= 1 }
            if target > 0 { boxActive += 1 }
            if boxActive == 0 {
                boxSum = 0
            } else {
                boxSum += Double(target) - Double(old)
            }

            reduction = Float(boxSum * invWindow)
            if reduction > 0 {
                gains[i] = expf(reduction * dbToNeper)
                unity = false
            } else {
                gains[i] = 1
            }
            clock += 1
        }

        self.dqHead = dqHead
        self.dqCount = dqCount
        self.boxPos = boxPos
        self.boxSum = boxSum
        self.boxActive = boxActive
        self.fast = fast
        self.slow = slow
        self.holdLeft = holdLeft
        self.clock = clock
        self.reductionDB = reduction
        return unity
    }
}

/// Fixed-length delay for one audio channel, paired with `LookaheadLimiter`
/// to hold the signal back by the limiter's look-ahead.
final class LimiterDelayLine {
    private let capacity: Int
    private let ring: UnsafeMutablePointer<Float>
    private var pos = 0
    private var length = 1

    init() {
        capacity = Int(LookaheadLimiter.lookaheadSeconds * 192_000) + 2
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
    }

    deinit { ring.deallocate() }

    /// Sets the delay in samples and clears the line. Not for use while
    /// `process` may be running.
    func configure(delaySamples: Int) {
        length = min(capacity, max(1, delaySamples))
        ring.update(repeating: 0, count: capacity)
        pos = 0
    }

    /// Replaces each sample in `buffer` with the one from `delaySamples` ago.
    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        // Each ring slot is read then overwritten by the sample that takes
        // its place, so a run of slots can simply be swapped with the buffer.
        var done = 0
        while done < count {
            let run = min(count - done, length - pos)
            vDSP_vswap(buffer + done, 1, ring + pos, 1, vDSP_Length(run))
            done += run
            pos += run
            if pos == length { pos = 0 }
        }
    }
}
