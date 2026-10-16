import Foundation
import GRDB
import Testing
@testable import MynahCore

struct MeetingStoreTests {
    let store: MeetingStore
    let meeting: Meeting

    init() throws {
        store = try MeetingStore()
        meeting = Meeting(title: "Henderson sync", appBundleID: "com.microsoft.teams2", appName: "Microsoft Teams",
                          source: "auto")
        try store.createMeeting(meeting)
    }

    @Test func appendAdvancesCursorAndFlagsSpeech() throws {
        try store.appendSegments(meetingID: meeting.id, track: .others,
                                 [(0, 1.8, "Hi, thanks for joining."), (1.8, 5.3, "The invoice is late.")], cursor: 21.9)
        try store.appendSegments(meetingID: meeting.id, track: .you, [], cursor: 30)
        let m = try #require(try store.meeting(id: meeting.id))
        #expect(m.othersCursorS == 21.9)
        #expect(m.youCursorS == 30)
        #expect(m.hasSpeech)
        #expect(try store.segments(meetingID: meeting.id).map(\.text) == ["Hi, thanks for joining.", "The invoice is late."])
    }

    @Test func emptyAppendDoesNotFlagSpeech() throws {
        try store.appendSegments(meetingID: meeting.id, track: .you, [], cursor: 30)
        #expect(try store.meeting(id: meeting.id)?.hasSpeech == false)
    }

    @Test func hiddenSegmentsAreExcluded() throws {
        try store.appendSegments(meetingID: meeting.id, track: .you, [(0, 1, "echo echo echo"), (2, 3, "real")], cursor: 3)
        let ids = try store.segments(meetingID: meeting.id).compactMap(\.id)
        try store.hide(segmentIDs: [ids[0]], reason: "echo")
        #expect(try store.segments(meetingID: meeting.id).map(\.text) == ["real"])
        #expect(try store.segments(meetingID: meeting.id, includeHidden: true).count == 2)
    }

    @Test func deleteCascades() throws {
        try store.appendSegments(meetingID: meeting.id, track: .you, [(0, 1, "hello there friend")], cursor: 1)
        try store.saveSummary(summary(), items: [ExtractedItem(text: "Send invoice", owner: "me")])
        try store.addActionItem(text: "Manual, attached", meetingID: meeting.id)
        let unrelated = try store.addActionItem(text: "Unrelated manual")
        try store.deleteMeeting(id: meeting.id)
        let (segs, sums, items) = try store.db.read { db in
            (try Segment.fetchCount(db), try MeetingSummary.fetchCount(db), try ActionItem.fetchAll(db).map(\.id))
        }
        #expect(segs == 0)
        #expect(sums == 0)
        #expect(items == [unrelated.id])
    }

    @Test func searchFindsTranscriptSummaryAndItems() throws {
        try store.appendSegments(meetingID: meeting.id, track: .others, [(12, 14, "Can you send the invoices by Friday?")],
                                 cursor: 20)
        try store.appendSegments(meetingID: meeting.id, track: .you, [(15, 16, "invoice invoice invoice")], cursor: 20)
        let echo = try store.segments(meetingID: meeting.id).first { $0.track == .you }!.id!
        try store.hide(segmentIDs: [echo], reason: "echo")
        try store.saveSummary(summary(tldr: "Discussed the overdue invoice."),
                              items: [ExtractedItem(text: "Send the invoice", owner: "me", timeS: 12)])

        let hits = try store.search("invoice")
        #expect(Set(hits.map(\.kind)) == [.transcript, .summary, .actionItem])
        #expect(hits.filter { $0.kind == .transcript }.count == 1)  // hidden echo excluded; porter stems "invoices"
        #expect(hits.first { $0.kind == .transcript }?.timeS == 12)
        #expect(try store.search("   ").isEmpty)
        #expect(try store.search("nonexistentword").isEmpty)
    }

    @Test func rerunKeepsEditedDoneAndDeletedItems() throws {
        try store.saveSummary(summary(), items: [
            ExtractedItem(text: "Send the invoice", owner: "me"),
            ExtractedItem(text: "Book a room", owner: "Priya"),
            ExtractedItem(text: "Update the site", owner: "unassigned"),
            ExtractedItem(text: "Call the bank", owner: "me"),
        ])
        var items = try store.actionItems(meetingID: meeting.id)
        func id(_ text: String) -> Int64 { items.first { $0.text == text }!.id! }
        try store.editActionItem(id: id("Book a room")) { $0.text = "Book the big room" }
        try store.setActionItem(id: id("Update the site"), done: true)
        try store.deleteActionItem(id: id("Call the bank"))

        // Re-run produces the same four plus a new one.
        try store.saveSummary(summary(), items: [
            ExtractedItem(text: "Send the invoice.", owner: "me"),
            ExtractedItem(text: "Book a room", owner: "Priya"),
            ExtractedItem(text: "update the site", owner: "unassigned"),
            ExtractedItem(text: "Call the bank", owner: "me"),
            ExtractedItem(text: "Draft the agenda", owner: "me"),
        ])
        items = try store.actionItems(meetingID: meeting.id)
        let texts = items.map(\.text).sorted()
        // The edited item keeps its original key, so the unedited suggestion doesn't come back.
        #expect(texts == ["Book the big room", "Draft the agenda", "Send the invoice.", "Update the site"])
        #expect(items.first { $0.text == "Update the site" }?.status == .done)
        #expect(!items.contains { $0.text == "Call the bank" })
    }

    @Test func ownersAndFilters() throws {
        try store.saveSummary(summary(), items: [
            ExtractedItem(text: "Mine", owner: "me"),
            ExtractedItem(text: "Hers", owner: "Priya"),
            ExtractedItem(text: "Nobody", owner: "unassigned"),
            ExtractedItem(text: "Dup", owner: "me"),
            ExtractedItem(text: "dup!", owner: "me"),
        ])
        let all = try store.actionItems()
        #expect(all.count == 4)
        #expect(all.first { $0.text == "Hers" }?.ownerKind == .person)
        #expect(all.first { $0.text == "Hers" }?.ownerName == "Priya")
        #expect(try store.actionItems(owner: .mine).map(\.text).sorted() == ["Dup", "Mine"])
        let mine = try #require(all.first { $0.text == "Mine" }?.id)
        try store.setActionItem(id: mine, done: true)
        #expect(try store.actionItems(status: .done).map(\.text) == ["Mine"])
        #expect(try store.actionItems(status: .open).count == 3)
    }

    @Test func manualItemsDeleteOutright() throws {
        let item = try store.addActionItem(text: "Buy stamps")
        try store.deleteActionItem(id: item.id!)
        #expect(try store.db.read { try ActionItem.fetchCount($0) } == 0)
    }

    @Test func statusQueries() throws {
        try store.setStatus(meeting.id, .queued)
        #expect(try store.meetings(status: [.queued]).map(\.id) == [meeting.id])
        #expect(try store.meetings(status: [.recording, .transcribing]).isEmpty)
        try store.setStatus(meeting.id, .failed, error: "boom")
        #expect(try store.meeting(id: meeting.id)?.error == "boom")
    }

    @Test func onDiskStoreMigrates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("mynah.sqlite").path
        try MeetingStore(path: path).createMeeting(meeting)
        #expect(try MeetingStore(path: path).meeting(id: meeting.id)?.title == "Henderson sync")
    }

    private func summary(tldr: String = "Short call.") -> MeetingSummary {
        MeetingSummary(meetingID: meeting.id, model: "gemma-4-e4b", tldr: tldr, keyPoints: ["a"], decisions: [],
                       openQuestions: ["Is the budget open?"])
    }
}
