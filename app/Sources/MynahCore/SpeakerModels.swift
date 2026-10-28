import Foundation
import GRDB

/// Someone the user has named. Their voice is every `MeetingSpeaker` linked to them.
public struct Person: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var name: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// One voice found in a meeting's "Others" track. Segments point at it by `label`.
/// Named speakers double as voiceprints for recognizing the person in later calls.
public struct MeetingSpeaker: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public var meetingID: String
    /// Stable within the meeting ("S1", "S2", …).
    public var label: String
    /// Shown as "Speaker N" until named; numbered by first time speaking.
    public var number: Int
    public var speechS: Double
    /// Float32 voiceprint; empty once the user forgets all voices.
    public var embedding: Data
    public var personID: String?
    /// Cosine similarity of an automatic match; nil when the user named it or nobody matched.
    public var matchScore: Double?
    /// Set when the user names (or un-names) the speaker.
    public var namedAt: Date?

    public init(meetingID: String, label: String, number: Int, speechS: Double, embedding: Data,
                personID: String? = nil, matchScore: Double? = nil, namedAt: Date? = nil) {
        self.meetingID = meetingID
        self.label = label
        self.number = number
        self.speechS = speechS
        self.embedding = embedding
        self.personID = personID
        self.matchScore = matchScore
        self.namedAt = namedAt
    }

    public var id: String { "\(meetingID)/\(label)" }
    public var placeholderName: String { "Speaker \(number)" }
}

public enum Voiceprint {
    public static func encode(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Cosine similarity (inputs need not be normalized). 0 for mismatched or empty vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}

/// Pure logic for turning a diarization into labelled segments and named speakers.
/// The threshold comes from the AMI POC in bench/speakers: the same person across
/// meetings scored 0.77+ (5th percentile, even after switching mics), different people
/// at most 0.47. 0.6 sits in the middle of that gap.
public enum SpeakerMatching {
    public static let threshold: Float = 0.6
    /// Voices with less speech than this are neither matched nor used as voiceprints.
    public static let minSpeechS = 5.0

    public struct Turn: Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var label: String

        public init(start: Double, end: Double, label: String) {
            self.start = start
            self.end = end
            self.label = label
        }
    }

    /// The speaker of each segment: the label overlapping it most, else the nearest
    /// turn within 1 s, else nil.
    public static func labels(for segments: [(start: Double, end: Double)], turns: [Turn]) -> [String?] {
        segments.map { seg in
            var overlap: [String: Double] = [:]
            for t in turns {
                let o = min(seg.end, t.end) - max(seg.start, t.start)
                if o > 0 { overlap[t.label, default: 0] += o }
            }
            if let best = overlap.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { return best.key }
            let near = turns.map { t in (t.label, max(t.start - seg.end, seg.start - t.end)) }
                .filter { $0.1 <= 1.0 }
                .min { $0.1 < $1.1 }
            return near?.0
        }
    }

    /// 1, 2, 3… by when each label first speaks.
    public static func numbers(_ turns: [Turn]) -> [String: Int] {
        var out: [String: Int] = [:]
        for t in turns.sorted(by: { $0.start < $1.start }) where out[t.label] == nil {
            out[t.label] = out.count + 1
        }
        return out
    }

    public struct Match: Sendable, Hashable {
        public var personID: String
        public var score: Float
    }

    /// Names voices after known people: each voice's score for a person is its best
    /// cosine against any of their voiceprints. Pairs are taken best-first, one person
    /// per voice and one voice per person, above `threshold`. A wrong name is worse than
    /// "Speaker 2", so ties and near-misses stay unnamed.
    public static func match(voices: [String: [Float]], gallery: [(personID: String, voiceprint: [Float])],
                             threshold: Float = threshold) -> [String: Match] {
        var pairs: [(label: String, personID: String, score: Float)] = []
        for (label, v) in voices {
            var best: [String: Float] = [:]
            for g in gallery {
                let s = Voiceprint.cosine(v, g.voiceprint)
                if s > best[g.personID, default: -1] { best[g.personID] = s }
            }
            pairs += best.filter { $0.value >= threshold }.map { (label, $0.key, $0.value) }
        }
        var out: [String: Match] = [:]
        var taken = Set<String>()
        for p in pairs.sorted(by: { ($0.score, $1.label, $1.personID) > ($1.score, $0.label, $0.personID) })
        where out[p.label] == nil && !taken.contains(p.personID) {
            out[p.label] = Match(personID: p.personID, score: p.score)
            taken.insert(p.personID)
        }
        return out
    }
}
