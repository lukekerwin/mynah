import Foundation
import GRDB

/// The local database meetings (and later the rest of the assistant) live in:
/// ~/Library/Application Support/Mynah/mynah.sqlite. All methods are synchronous
/// and thread-safe; call them off the main thread for anything non-trivial.
public final class MeetingStore: Sendable {
    public let db: any DatabaseWriter

    /// On-disk store (WAL mode, concurrent reads).
    public init(path: String) throws {
        db = try DatabasePool(path: path)
        try Self.migrator.migrate(db)
    }

    /// In-memory store, for tests.
    public init() throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1-meetings") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("titleEdited", .boolean).notNull().defaults(to: false)
                t.column("appBundleID", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("source", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("error", .text)
                t.column("youCursorS", .double).notNull().defaults(to: 0)
                t.column("othersCursorS", .double).notNull().defaults(to: 0)
                t.column("hasSpeech", .boolean).notNull().defaults(to: false)
                t.column("audioDeletedAt", .datetime)
            }
            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingID", .text).notNull().references("meeting", onDelete: .cascade)
                t.column("track", .text).notNull()
                t.column("startS", .double).notNull()
                t.column("endS", .double).notNull()
                t.column("text", .text).notNull()
                t.column("hiddenReason", .text)
            }
            try db.create(index: "segment_on_meeting_start", on: "segment", columns: ["meetingID", "startS"])
            try db.create(table: "meetingSummary") { t in
                t.primaryKey("meetingID", .text).references("meeting", onDelete: .cascade)
                t.column("model", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("tldr", .text).notNull()
                t.column("keyPoints", .text).notNull()  // JSON arrays
                t.column("decisions", .text).notNull()
                t.column("openQuestions", .text).notNull()
            }
            try db.create(table: "actionItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingID", .text).indexed().references("meeting", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("text", .text).notNull()
                t.column("ownerKind", .text).notNull()
                t.column("ownerName", .text)
                t.column("dueDate", .text)
                t.column("timeS", .double)
                t.column("status", .text).notNull()
                t.column("completedAt", .datetime)
                t.column("userEdited", .boolean).notNull().defaults(to: false)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("extractionKey", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(virtualTable: "segmentFTS", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = .porter()
                t.column("text")
            }
            try db.create(virtualTable: "meetingSummaryFTS", using: FTS5()) { t in
                t.synchronize(withTable: "meetingSummary")
                t.tokenizer = .porter()
                t.column("tldr")
                t.column("keyPoints")
                t.column("decisions")
                t.column("openQuestions")
            }
            try db.create(virtualTable: "actionItemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "actionItem")
                t.tokenizer = .porter()
                t.column("text")
            }
        }
        m.registerMigration("v2-speakers") { db in
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "meetingSpeaker") { t in
                t.column("meetingID", .text).notNull().references("meeting", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.primaryKey(["meetingID", "label"])
                t.column("number", .integer).notNull()
                t.column("speechS", .double).notNull()
                t.column("embedding", .blob).notNull()
                t.column("personID", .text).indexed().references("person", onDelete: .setNull)
                t.column("matchScore", .double)
                t.column("namedAt", .datetime)
            }
            try db.alter(table: "segment") { t in t.add(column: "speaker", .text) }
        }
        return m
    }

    // MARK: meetings

    public func createMeeting(_ meeting: Meeting) throws {
        try db.write { try meeting.insert($0) }
    }

    public func meeting(id: String) throws -> Meeting? {
        try db.read { try Meeting.fetchOne($0, key: id) }
    }

    public func update(_ meeting: Meeting) throws {
        try db.write { try meeting.update($0) }
    }

    /// Apply a change to the latest stored copy of a meeting.
    @discardableResult
    public func modifyMeeting(id: String, _ change: (inout Meeting) -> Void) throws -> Meeting? {
        try db.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { return nil }
            change(&m)
            try m.update(db)
            return m
        }
    }

    public func setStatus(_ id: String, _ status: MeetingStatus, error: String? = nil) throws {
        try modifyMeeting(id: id) {
            $0.status = status
            $0.error = error
        }
    }

    public func meetings(status: [MeetingStatus]) throws -> [Meeting] {
        try db.read { db in
            try Meeting.filter(status.map(\.rawValue).contains(Column("status")))
                .order(Column("startedAt")).fetchAll(db)
        }
    }

    public func allMeetings() throws -> [Meeting] {
        try db.read { try Meeting.order(Column("startedAt").desc).fetchAll($0) }
    }

    public func hasMeetings() throws -> Bool {
        try db.read { try Meeting.fetchCount($0) > 0 }
    }

    /// Deletes the meeting with its segments, summary and action items.
    public func deleteMeeting(id: String) throws {
        _ = try db.write { try Meeting.deleteOne($0, key: id) }
    }

    // MARK: transcript

    /// Inserts a track's new segments and advances its cursor in one transaction,
    /// so a crash can never transcribe the same audio twice or skip any.
    public func appendSegments(meetingID: String, track: Track,
                               _ pieces: [(start: Double, end: Double, text: String)], cursor: Double) throws {
        try db.write { db in
            for p in pieces {
                var seg = Segment(meetingID: meetingID, track: track, startS: p.start, endS: p.end, text: p.text)
                try seg.insert(db)
            }
            let column = track == .you ? "youCursorS" : "othersCursorS"
            try db.execute(sql: "UPDATE meeting SET \(column) = ?, hasSpeech = hasSpeech OR ? WHERE id = ?",
                           arguments: [cursor, !pieces.isEmpty, meetingID])
        }
    }

    public func segments(meetingID: String, includeHidden: Bool = false) throws -> [Segment] {
        try db.read { db in
            var request = Segment.filter(Column("meetingID") == meetingID)
            if !includeHidden { request = request.filter(Column("hiddenReason") == nil) }
            return try request.order(Column("startS"), Column("id")).fetchAll(db)
        }
    }

    public func hide(segmentIDs: [Int64], reason: String) throws {
        guard !segmentIDs.isEmpty else { return }
        try db.write { db in
            _ = try Segment.filter(keys: segmentIDs).updateAll(db, Column("hiddenReason").set(to: reason))
        }
    }

    // MARK: speakers + people

    public func speakers(meetingID: String) throws -> [MeetingSpeaker] {
        try db.read { try MeetingSpeaker.filter(Column("meetingID") == meetingID).order(Column("number")).fetchAll($0) }
    }

    /// Everyone named so far, alphabetically.
    public func people() throws -> [Person] {
        try db.read { try Person.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }
    }

    /// Voiceprints of named people from other meetings, for recognizing them.
    public func voiceGallery(excluding meetingID: String) throws -> [(personID: String, voiceprint: [Float])] {
        try db.read { db in
            try MeetingSpeaker.filter(Column("personID") != nil && Column("meetingID") != meetingID
                && Column("speechS") >= SpeakerMatching.minSpeechS && length(Column("embedding")) > 0)
                .fetchAll(db)
                .compactMap { s in s.personID.map { ($0, Voiceprint.decode(s.embedding)) } }
        }
    }

    /// Replaces a meeting's speakers and points each "Others" segment at one.
    public func saveSpeakers(meetingID: String, _ speakers: [MeetingSpeaker], segmentLabels: [Int64: String]) throws {
        try db.write { db in
            try MeetingSpeaker.filter(Column("meetingID") == meetingID).deleteAll(db)
            try db.execute(sql: "UPDATE segment SET speaker = NULL WHERE meetingID = ?", arguments: [meetingID])
            for s in speakers { try s.insert(db) }
            for (id, label) in segmentLabels {
                try db.execute(sql: "UPDATE segment SET speaker = ? WHERE id = ?", arguments: [label, id])
            }
        }
    }

    /// The user says who a voice is (nil = "not who Mynah guessed"). Their voiceprint
    /// then counts toward recognizing that person in later meetings.
    public func nameSpeaker(meetingID: String, label: String, personID: String?, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE meetingSpeaker SET personID = ?, matchScore = NULL, namedAt = ? WHERE meetingID = ? AND label = ?
                """, arguments: [personID, now, meetingID, label])
        }
    }

    /// Returns the person with this name (case-insensitive), creating them if needed.
    public func person(named name: String) throws -> Person {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try db.write { db in
            if let p = try Person.fetchAll(db).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return p
            }
            let p = Person(name: name)
            try p.insert(db)
            return p
        }
    }

    public func renamePerson(id: String, to name: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE person SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Their speakers go back to "Speaker N".
    public func deletePerson(id: String) throws {
        _ = try db.write { try Person.deleteOne($0, key: id) }
    }

    /// Deletes everyone and every voiceprint; transcripts keep their "Speaker N" split.
    public func forgetAllVoices() throws {
        try db.write { db in
            try Person.deleteAll(db)
            try db.execute(sql: "UPDATE meetingSpeaker SET embedding = x'', matchScore = NULL")
        }
    }

    /// How many meetings each person has been heard in.
    public func meetingCounts() throws -> [String: Int] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT personID, COUNT(DISTINCT meetingID) AS n FROM meetingSpeaker WHERE personID IS NOT NULL GROUP BY personID
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["personID"], $0["n"]) })
        }
    }

    // MARK: summary + action items

    public func summary(meetingID: String) throws -> MeetingSummary? {
        try db.read { try MeetingSummary.fetchOne($0, key: meetingID) }
    }

    /// Stores a (re)generated summary. Untouched open items from a previous run are
    /// replaced; items the user edited, completed or deleted are kept, and new
    /// items matching one of them are skipped.
    public func saveSummary(_ summary: MeetingSummary, items: [ExtractedItem], now: Date = Date()) throws {
        try db.write { db in
            try summary.save(db)
            try ActionItem
                .filter(Column("meetingID") == summary.meetingID && Column("userEdited") == false
                    && Column("status") == ItemStatus.open.rawValue && Column("deleted") == false)
                .deleteAll(db)
            var keys = Set(try String.fetchAll(db, sql: """
                SELECT extractionKey FROM actionItem WHERE meetingID = ? AND extractionKey IS NOT NULL
                """, arguments: [summary.meetingID]))
            for x in items {
                let key = Self.extractionKey(x.text)
                guard !key.isEmpty, keys.insert(key).inserted else { continue }
                let owner = x.owner.trimmingCharacters(in: .whitespaces)
                let kind: OwnerKind = owner.lowercased() == "me" ? .me
                    : (owner.isEmpty || owner.lowercased() == "unassigned") ? .unassigned : .person
                var item = ActionItem(meetingID: summary.meetingID, source: "meeting", text: x.text, ownerKind: kind,
                                      ownerName: kind == .person ? owner : nil, dueDate: x.due, timeS: x.timeS, now: now)
                item.extractionKey = key
                try item.insert(db)
            }
        }
    }

    /// Lowercased words only, so trivial rewording of punctuation/case still matches.
    public static func extractionKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public enum ItemFilter: Sendable {
        case all, mine
    }

    /// Visible (non-deleted) items, open first, then newest.
    public func actionItems(meetingID: String? = nil, owner: ItemFilter = .all, status: ItemStatus? = nil) throws -> [ActionItem] {
        try db.read { db in
            var r = ActionItem.filter(Column("deleted") == false)
            if let meetingID { r = r.filter(Column("meetingID") == meetingID) }
            if owner == .mine { r = r.filter(Column("ownerKind") == OwnerKind.me.rawValue) }
            if let status { r = r.filter(Column("status") == status.rawValue) }
            return try r.order(Column("status").desc, Column("createdAt").desc, Column("id")).fetchAll(db)
        }
    }

    @discardableResult
    public func addActionItem(text: String, meetingID: String? = nil, ownerKind: OwnerKind = .me,
                              ownerName: String? = nil, dueDate: String? = nil, now: Date = Date()) throws -> ActionItem {
        try db.write { db in
            var item = ActionItem(meetingID: meetingID, source: "manual", text: text, ownerKind: ownerKind,
                                  ownerName: ownerName, dueDate: dueDate, now: now)
            item.userEdited = true
            try item.insert(db)
            return item
        }
    }

    /// User edit of text/owner/due date: marks the item so re-runs never replace it.
    public func editActionItem(id: Int64, now: Date = Date(), _ change: (inout ActionItem) -> Void) throws {
        try db.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            change(&item)
            item.userEdited = true
            item.updatedAt = now
            try item.update(db)
        }
    }

    public func setActionItem(id: Int64, done: Bool, now: Date = Date()) throws {
        try db.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            item.status = done ? .done : .open
            item.completedAt = done ? now : nil
            item.updatedAt = now
            try item.update(db)
        }
    }

    public func deleteActionItem(id: Int64, now: Date = Date()) throws {
        try db.write { db in
            guard var item = try ActionItem.fetchOne(db, key: id) else { return }
            if item.source == "manual" {
                try item.delete(db)  // nothing to tombstone against
            } else {
                item.deleted = true
                item.updatedAt = now
                try item.update(db)
            }
        }
    }

    // MARK: search

    /// Full-text search across visible transcript lines, summaries and action items.
    public func search(_ query: String, limit: Int = 200) throws -> [SearchHit] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try db.read { db in
            var hits: [SearchHit] = []
            let segs = try Row.fetchAll(db, sql: """
                SELECT segment.meetingID AS meetingID, segment.startS AS t,
                       snippet(segmentFTS, 0, '', '', '…', 16) AS snip
                FROM segmentFTS JOIN segment ON segment.id = segmentFTS.rowid
                WHERE segmentFTS MATCH ? AND segment.hiddenReason IS NULL
                ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit])
            hits += segs.map { SearchHit(meetingID: $0["meetingID"], kind: .transcript, snippet: $0["snip"], timeS: $0["t"]) }
            let sums = try Row.fetchAll(db, sql: """
                SELECT meetingSummary.meetingID AS meetingID,
                       snippet(meetingSummaryFTS, -1, '', '', '…', 16) AS snip
                FROM meetingSummaryFTS JOIN meetingSummary ON meetingSummary.rowid = meetingSummaryFTS.rowid
                WHERE meetingSummaryFTS MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit])
            hits += sums.map { SearchHit(meetingID: $0["meetingID"], kind: .summary, snippet: Self.unJSON($0["snip"])) }
            let items = try Row.fetchAll(db, sql: """
                SELECT actionItem.id AS id, actionItem.meetingID AS meetingID, actionItem.timeS AS t, actionItem.text AS text
                FROM actionItemFTS JOIN actionItem ON actionItem.id = actionItemFTS.rowid
                WHERE actionItemFTS MATCH ? AND actionItem.deleted = 0 ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit])
            hits += items.map {
                SearchHit(meetingID: $0["meetingID"], kind: .actionItem, snippet: $0["text"], timeS: $0["t"],
                          actionItemID: $0["id"])
            }
            return hits
        }
    }

    /// Summary lists are stored as JSON arrays; strip the syntax from snippets.
    private static func unJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\",\"", with: " · ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]\""))
    }
}
