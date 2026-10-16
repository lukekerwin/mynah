import Foundation

public struct TranscriptLine: Sendable, Hashable, Identifiable {
    public var startS: Double
    public var endS: Double
    public var track: Track
    public var text: String
    public var segmentIDs: [Int64]

    public var id: String { "\(track.rawValue)-\(startS)" }
}

public enum TranscriptFormatter {
    /// A pause this long starts a new paragraph: everyone else shares the "Others"
    /// track, so a pause is the best sign that another person took over.
    public static let paragraphGap: Double = 1.5
    /// Paragraphs longer than this are split at the next segment.
    public static let paragraphMax: Double = 30

    /// Visible segments in time order. Consecutive segments from the same track are
    /// merged into a paragraph unless there's a pause or the paragraph is long.
    public static func lines(_ segments: [Segment]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        for seg in segments.sorted(by: { ($0.startS, $0.id ?? 0) < ($1.startS, $1.id ?? 0) })
        where seg.hiddenReason == nil && !seg.text.isEmpty {
            if var last = out.last, last.track == seg.track,
               seg.startS - last.endS < paragraphGap, seg.endS - last.startS <= paragraphMax {
                last.text += " " + seg.text
                last.endS = max(last.endS, seg.endS)
                if let id = seg.id { last.segmentIDs.append(id) }
                out[out.count - 1] = last
            } else {
                out.append(TranscriptLine(startS: seg.startS, endS: seg.endS, track: seg.track, text: seg.text,
                                          segmentIDs: seg.id.map { [$0] } ?? []))
            }
        }
        return out
    }

    /// Visible segments as the engine's /summarize expects them.
    public static func engineSegments(_ segments: [Segment]) -> [[String: Any]] {
        segments.filter { $0.hiddenReason == nil }.sorted { $0.startS < $1.startS }.map {
            ["track": $0.track.rawValue, "start": $0.startS, "end": $0.endS, "text": $0.text]
        }
    }

    /// "mm:ss" or "h:mm:ss".
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
