import Foundation

/// How long meeting audio is kept once the transcript exists. Transcripts,
/// summaries and action items are kept until the user deletes them.
public enum AudioRetention: String, Codable, CaseIterable, Sendable, Identifiable {
    case afterTranscript, days7, days30, forever

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .afterTranscript: return "Delete after transcript"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .forever: return "Forever"
        }
    }

    public var keepFor: TimeInterval? {
        switch self {
        case .afterTranscript: return 0
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        case .forever: return nil
        }
    }

    public func audioDue(endedAt: Date, now: Date) -> Bool {
        guard let keepFor else { return false }
        return now.timeIntervalSince(endedAt) >= keepFor
    }
}
