import Foundation

struct LyricWord: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

struct LyricSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var start: Double
    var end: Double
    var words: [LyricWord] = []

    enum CodingKeys: String, CodingKey {
        case id, text, start, end, words
    }

    init(id: UUID = UUID(), text: String, start: Double, end: Double, words: [LyricWord] = []) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        words = try c.decodeIfPresent([LyricWord].self, forKey: .words) ?? []
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

    /// Returns the word inside the active segment at `time`, if any.
    func word(at time: Double) -> LyricWord? {
        guard let seg = segment(at: time) else { return nil }
        for w in seg.words where time >= w.start && time < w.end {
            return w
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
