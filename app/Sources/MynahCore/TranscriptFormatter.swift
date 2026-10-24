import Foundation

public struct TranscriptLine: Sendable, Hashable, Identifiable {
    public var startS: Double
    public var endS: Double
    public var track: Track
    public var text: String
    public var segmentIDs: [Int64]
    /// The "Others" speaker's label and display name ("Bob", "Speaker 2"); nil = "Others".
    public var speakerLabel: String?
    public var speakerName: String?

    public var id: String { "\(track.rawValue)-\(startS)" }

    /// "You", the speaker's name, or "Others".
    public var who: String { track == .you ? "You" : speakerName ?? "Others" }
}

public enum TranscriptFormatter {
    /// A pause this long starts a new paragraph: when everyone else shares the
    /// "Others" track, a pause is the best sign that another person took over.
    public static let paragraphGap: Double = 1.5
    /// Paragraphs longer than this are split at the next segment.
    public static let paragraphMax: Double = 30

    /// Display name per speaker label: the person's name once known, else "Speaker N".
    public static func speakerNames(_ speakers: [MeetingSpeaker], people: [Person]) -> [String: String] {
        let byID = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return Dictionary(speakers.map { s in (s.label, s.personID.flatMap { byID[$0] } ?? s.placeholderName) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Visible segments in time order. Consecutive segments from the same speaker are
    /// merged into a paragraph unless there's a pause or the paragraph is long.
    public static func lines(_ segments: [Segment], names: [String: String] = [:]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        for seg in segments.sorted(by: { ($0.startS, $0.id ?? 0) < ($1.startS, $1.id ?? 0) })
        where seg.hiddenReason == nil && !seg.text.isEmpty {
            let name = seg.track == .others ? seg.speaker.flatMap { names[$0] } : nil
            if var last = out.last, last.track == seg.track, last.speakerName == name,
               seg.startS - last.endS < paragraphGap, seg.endS - last.startS <= paragraphMax {
                last.text += " " + seg.text
                last.endS = max(last.endS, seg.endS)
                if let id = seg.id { last.segmentIDs.append(id) }
                out[out.count - 1] = last
            } else {
                out.append(TranscriptLine(startS: seg.startS, endS: seg.endS, track: seg.track, text: seg.text,
                                          segmentIDs: seg.id.map { [$0] } ?? [],
                                          speakerLabel: name == nil ? nil : seg.speaker, speakerName: name))
            }
        }
        return out
    }

    /// Visible segments as the engine's /summarize expects them.
    public static func engineSegments(_ segments: [Segment], names: [String: String] = [:]) -> [[String: Any]] {
        segments.filter { $0.hiddenReason == nil }.sorted { $0.startS < $1.startS }.map {
            var seg: [String: Any] = ["track": $0.track.rawValue, "start": $0.startS, "end": $0.endS, "text": $0.text]
            if $0.track == .others, let name = $0.speaker.flatMap({ names[$0] }) { seg["speaker"] = name }
            return seg
        }
    }

    /// "mm:ss" or "h:mm:ss".
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
