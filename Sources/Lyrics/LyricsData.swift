import Foundation

struct LyricSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var end: Double

    enum CodingKeys: String, CodingKey {
        case id, text, start, end
    }

    init(id: UUID = UUID(), text: String, start: Double, end: Double) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }

    /// Custom decoder so pre-existing sidecars that lack an `id` (or that
    /// contain a now-unused `words` array) still load. Codable silently
    /// ignores extra keys, so legacy `"words": [...]` payloads just get
    /// dropped — on the next save the sidecar is rewritten without them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
    }
}

struct LyricsDocument: Codable, Hashable {
    var audioFilePath: String
    var segments: [LyricSegment]
    var modelUsed: String
    var language: String?
    var createdAt: Date
    var version: Int = 1

    /// Returns the segment that contains `time`, if any.
    func segment(at time: Double) -> LyricSegment? {
        // Linear scan is fine — a song rarely has more than a few hundred segments.
        for seg in segments where time >= seg.start && time < seg.end {
            return seg
        }
        return nil
    }

    /// Returns index of the segment active at `time`, or the next upcoming one,
    /// or nil if we're past the end.
    func currentOrUpcomingSegmentIndex(at time: Double) -> Int? {
        for (i, seg) in segments.enumerated() {
            if time < seg.end { return i }
        }
        return nil
    }
}
