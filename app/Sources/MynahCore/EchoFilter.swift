import Foundation

/// On speakers, the mic also hears the other participants. A "You" segment is
/// treated as echo when most of its words also appear in "Others" segments
/// spoken at about the same time.
public enum EchoFilter {
    public static let minWords = 3
    public static let overlapRatio = 0.6
    public static let slack: Double = 1.5  // seconds either side

    public static func echoIDs(you: [Segment], others: [Segment]) -> [Int64] {
        let sortedOthers = others.sorted { $0.startS < $1.startS }
        let otherWords = sortedOthers.map { Set(words($0.text)) }
        var ids: [Int64] = []
        for seg in you {
            guard let id = seg.id else { continue }
            let mine = words(seg.text)
            guard mine.count >= minWords else { continue }
            var pool = Set<String>()
            for (i, other) in sortedOthers.enumerated() {
                if other.startS > seg.endS + slack { break }
                if other.endS >= seg.startS - slack { pool.formUnion(otherWords[i]) }
            }
            guard !pool.isEmpty else { continue }
            let shared = mine.filter(pool.contains).count
            if Double(shared) / Double(mine.count) >= overlapRatio { ids.append(id) }
        }
        return ids
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
