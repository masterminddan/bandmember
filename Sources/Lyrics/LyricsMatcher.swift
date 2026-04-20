import Foundation

/// Reconciles user-pasted corrected lyrics against an existing timestamped
/// transcription. Text in the output comes from the paste; timestamps come
/// from the original segments via line-level alignment.
///
/// Alignment strategy:
/// - **Fast path**: if the pasted text has exactly the same line count as the
///   existing segments, substitute text 1-to-1 and keep every timestamp. This
///   handles the common case where the user re-writes the lyrics but doesn't
///   change the line structure.
/// - **Otherwise**: run a line-level Needleman–Wunsch between pasted lines
///   and existing segments, using word-set (Jaccard) similarity as the match
///   score. Each pasted line either matches one existing segment (and
///   inherits its time range) or has no match (and interpolates a range
///   from its neighbors). Existing segments without a match have their time
///   range absorbed into the nearest output segment so no time is lost.
///
/// This isn't a perfect forced-alignment — it can't recover word-level timing
/// — but it lets a user paste corrected lyrics and keep the Whisper-generated
/// segment timing intact, which is the whole point of the workflow.
enum LyricsMatcher {
    /// Returns a new segment list derived from `existing` but with text
    /// replaced by `pastedText`. Returns `existing` unchanged if either side
    /// is empty.
    static func reconcile(pastedText: String,
                          existing: [LyricSegment]) -> [LyricSegment] {
        let pastedLines = parseLines(pastedText)
        guard !pastedLines.isEmpty, !existing.isEmpty else { return existing }

        // Fast path — the common case.
        if pastedLines.count == existing.count {
            return zip(pastedLines, existing).map { (text, old) in
                LyricSegment(id: old.id, text: text, start: old.start, end: old.end)
            }
        }

        return alignLines(pasted: pastedLines, existing: existing)
    }

    // MARK: - Parsing

    private static func parseLines(_ text: String) -> [String] {
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lowercased alphanumeric tokens; punctuation and whitespace are delimiters.
    private static func tokenize(_ text: String) -> [String] {
        var buf = ""
        var out: [String] = []
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                buf.unicodeScalars.append(scalar)
            } else if !buf.isEmpty {
                out.append(buf); buf = ""
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    // MARK: - Similarity

    /// Word-set Jaccard similarity — robust to small typos on a per-line basis
    /// while being cheap enough to run in an O(m·n) DP. Returns 0 when either
    /// side is empty.
    static func similarity(_ a: String, _ b: String) -> Double {
        let aw = Set(tokenize(a))
        let bw = Set(tokenize(b))
        if aw.isEmpty && bw.isEmpty { return 1.0 }
        if aw.isEmpty || bw.isEmpty { return 0.0 }
        let inter = aw.intersection(bw).count
        let union = aw.union(bw).count
        return Double(inter) / Double(union)
    }

    // MARK: - Alignment

    /// Line-level Needleman–Wunsch. Maximizes the sum of match similarities
    /// minus a small `skipPenalty` per skipped line on either side.
    private static func alignLines(pasted: [String],
                                   existing: [LyricSegment]) -> [LyricSegment] {
        let m = pasted.count
        let n = existing.count

        /// Tuned so that any match with similarity > 0.3 beats skipping on
        /// either side — low but non-zero overlap is still preferred over
        /// leaving a line unmatched.
        let skipPenalty: Double = 0.3

        // score[i][j] = best score aligning pasted[0..<i] with existing[0..<j]
        // parent[i][j] in {0: diagonal match, 1: skip pasted, 2: skip existing}
        var score = Array(repeating: Array(repeating: 0.0, count: n + 1), count: m + 1)
        var parent = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        if m > 0 {
            for i in 1...m { score[i][0] = score[i-1][0] - skipPenalty; parent[i][0] = 1 }
        }
        if n > 0 {
            for j in 1...n { score[0][j] = score[0][j-1] - skipPenalty; parent[0][j] = 2 }
        }

        if m > 0 && n > 0 {
            for i in 1...m {
                for j in 1...n {
                    let sim = similarity(pasted[i-1], existing[j-1].text)
                    let diag = score[i-1][j-1] + sim
                    let up = score[i-1][j] - skipPenalty   // skip pasted[i-1]
                    let left = score[i][j-1] - skipPenalty // skip existing[j-1]
                    if diag >= up && diag >= left {
                        score[i][j] = diag; parent[i][j] = 0
                    } else if up >= left {
                        score[i][j] = up; parent[i][j] = 1
                    } else {
                        score[i][j] = left; parent[i][j] = 2
                    }
                }
            }
        }

        // Traceback.
        var matchedOld = Array<Int?>(repeating: nil, count: m)
        var unmatchedOld: [Int] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            let p: Int
            if i == 0 { p = 2 }
            else if j == 0 { p = 1 }
            else { p = parent[i][j] }
            switch p {
            case 0:
                matchedOld[i-1] = j-1
                i -= 1; j -= 1
            case 1:
                i -= 1
            case 2:
                unmatchedOld.append(j-1)
                j -= 1
            default:
                i = 0; j = 0
            }
        }

        // Build an initial output using the matched ranges, interpolating
        // between neighbors for any pasted line without a direct match.
        var out: [LyricSegment] = []
        out.reserveCapacity(m)
        for idx in 0..<m {
            let text = pasted[idx]
            if let oldIdx = matchedOld[idx] {
                out.append(LyricSegment(text: text,
                                        start: existing[oldIdx].start,
                                        end: existing[oldIdx].end))
            } else {
                let prevEnd = out.last?.end
                // First following pasted line that has a match, so we can
                // bracket the current (unmatched) line between neighbors.
                let nextMatchedOld: Int? = {
                    for k in (idx+1)..<m {
                        if let o = matchedOld[k] { return o }
                    }
                    return nil
                }()
                let nextStart = nextMatchedOld.map { existing[$0].start }
                let start = prevEnd ?? nextStart.map { max(0, $0 - 1.5) } ?? 0
                let end = nextStart ?? (prevEnd.map { $0 + 1.5 }) ?? (start + 1.0)
                out.append(LyricSegment(text: text,
                                        start: start,
                                        end: max(start + 0.3, end)))
            }
        }

        // Absorb unmatched old segments into the nearest output segment so
        // their time isn't lost — extend its [start, end] to cover them.
        for oldIdx in unmatchedOld {
            guard !out.isEmpty else { break }
            let oldSeg = existing[oldIdx]
            var bestIdx = 0
            var bestDist = Double.infinity
            for (k, s) in out.enumerated() {
                // Gap-distance between intervals; 0 if they already overlap.
                let gap: Double
                if oldSeg.end < s.start { gap = s.start - oldSeg.end }
                else if oldSeg.start > s.end { gap = oldSeg.start - s.end }
                else { gap = 0 }
                if gap < bestDist { bestDist = gap; bestIdx = k }
            }
            out[bestIdx].start = min(out[bestIdx].start, oldSeg.start)
            out[bestIdx].end = max(out[bestIdx].end, oldSeg.end)
        }

        // Final safety net: sort by start and clamp to monotonic non-overlap.
        out.sort { $0.start < $1.start }
        for k in 1..<out.count {
            if out[k].start < out[k-1].end {
                out[k].start = out[k-1].end
            }
            if out[k].end <= out[k].start {
                out[k].end = out[k].start + 0.3
            }
        }
        return out
    }
}
