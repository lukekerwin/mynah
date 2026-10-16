import Foundation
import GRDB

public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case recording, transcribing, queued, summarizing, done, failed
    case noSpeech = "no_speech"
}

public enum Track: String, Codable, Sendable {
    case you, others
}

/// One recorded call. Audio lives in `Meetings/<id>/` next to the database.
public struct Meeting: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var title: String
    public var titleEdited = false
    public var appBundleID: String
    public var appName: String
    public var source: String  // "auto" | "manual"
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus = .recording
    public var error: String?
    /// How far each track has been transcribed, in seconds from the start.
    public var youCursorS: Double = 0
    public var othersCursorS: Double = 0
    public var hasSpeech = false
    public var audioDeletedAt: Date?

    public init(id: String = UUID().uuidString, title: String, appBundleID: String, appName: String,
                source: String, startedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.appBundleID = appBundleID
        self.appName = appName
        self.source = source
        self.startedAt = startedAt
    }

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    public func cursor(_ track: Track) -> Double { track == .you ? youCursorS : othersCursorS }
}

/// A timed piece of transcript from one track.
public struct Segment: Codable, Sendable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var meetingID: String
    public var track: Track
    public var startS: Double
    public var endS: Double
    public var text: String
    /// Non-nil hides the segment from transcripts and summaries ("echo").
    public var hiddenReason: String?

    public init(id: Int64? = nil, meetingID: String, track: Track, startS: Double, endS: Double, text: String,
                hiddenReason: String? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.track = track
        self.startS = startS
        self.endS = endS
        self.text = text
        self.hiddenReason = hiddenReason
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct MeetingSummary: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var meetingID: String
    public var model: String
    public var createdAt: Date
    public var tldr: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var openQuestions: [String]

    public init(meetingID: String, model: String, createdAt: Date = Date(), tldr: String, keyPoints: [String],
                decisions: [String], openQuestions: [String]) {
        self.meetingID = meetingID
        self.model = model
        self.createdAt = createdAt
        self.tldr = tldr
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.openQuestions = openQuestions
    }
}

public enum OwnerKind: String, Codable, Sendable {
    case me, person, unassigned
}

public enum ItemStatus: String, Codable, Sendable {
    case open, done
}

/// A to-do: extracted from a meeting summary, or added by hand.
public struct ActionItem: Codable, Sendable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var meetingID: String?
    public var source: String  // "meeting" | "manual"
    public var text: String
    public var ownerKind: OwnerKind
    public var ownerName: String?
    public var dueDate: String?  // YYYY-MM-DD
    public var timeS: Double?  // where in the meeting it came from
    public var status: ItemStatus = .open
    public var completedAt: Date?
    /// Set when the user edits text/owner/due date; re-running a summary never replaces these.
    public var userEdited = false
    /// Tombstone: hidden, and stops a re-run from bringing the item back.
    public var deleted = false
    public var extractionKey: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, meetingID: String?, source: String, text: String, ownerKind: OwnerKind,
                ownerName: String? = nil, dueDate: String? = nil, timeS: Double? = nil, now: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.source = source
        self.text = text
        self.ownerKind = ownerKind
        self.ownerName = ownerName
        self.dueDate = dueDate
        self.timeS = timeS
        self.createdAt = now
        self.updatedAt = now
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var ownerLabel: String {
        switch ownerKind {
        case .me: return "Me"
        case .person: return ownerName ?? "Someone"
        case .unassigned: return "Unassigned"
        }
    }
}

/// An action item as returned by the engine's /summarize.
public struct ExtractedItem: Codable, Sendable, Hashable {
    public var text: String
    public var owner: String  // "me" | "unassigned" | a name
    public var due: String?
    public var timeS: Double?

    public init(text: String, owner: String, due: String? = nil, timeS: Double? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
        self.timeS = timeS
    }

    enum CodingKeys: String, CodingKey {
        case text, owner, due
        case timeS = "time_s"
    }
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case transcript, summary, actionItem }
    public var meetingID: String?
    public var kind: Kind
    public var snippet: String
    public var timeS: Double?
    public var actionItemID: Int64?

    public var id: String { "\(kind.rawValue)-\(meetingID ?? "")-\(timeS ?? -1)-\(actionItemID ?? -1)-\(snippet.hashValue)" }
}
