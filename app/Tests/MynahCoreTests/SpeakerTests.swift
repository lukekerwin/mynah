import Foundation
import Testing
@testable import MynahCore

struct SpeakerMatchingTests {
    typealias Turn = SpeakerMatching.Turn

    @Test func segmentsTakeTheSpeakerTheyOverlapMost() {
        let turns = [Turn(start: 0, end: 4, label: "A"), Turn(start: 4, end: 10, label: "B"), Turn(start: 20, end: 22, label: "A")]
        let labels = SpeakerMatching.labels(for: [(0.5, 3), (3, 9), (10.5, 11), (15, 16)], turns: turns)
        #expect(labels == ["A", "B", "B", nil])  // 10.5 is within 1 s of B's turn; 15 is near nobody
    }

    @Test func numbersFollowFirstSpeech() {
        let turns = [Turn(start: 5, end: 6, label: "X"), Turn(start: 1, end: 2, label: "Y"), Turn(start: 7, end: 8, label: "Y")]
        #expect(SpeakerMatching.numbers(turns) == ["Y": 1, "X": 2])
    }

    @Test func matchNamesKnownVoicesOneToOne() {
        let bob: [Float] = [1, 0, 0], anna: [Float] = [0, 1, 0]
        let gallery = [(personID: "bob", voiceprint: bob), (personID: "anna", voiceprint: anna),
                       (personID: "bob", voiceprint: [0.9, 0.1, 0])]
        let voices: [String: [Float]] = [
            "S1": [0.95, 0.05, 0],  // Bob
            "S2": [0.9, 0.2, 0],  // also closest to Bob, but Bob is taken by the better match
            "S3": [0.1, 1, 0],  // Anna
            "S4": [0, 0, 1],  // a stranger
        ]
        let m = SpeakerMatching.match(voices: voices, gallery: gallery)
        #expect(m["S1"]?.personID == "bob")
        #expect(m["S2"] == nil)
        #expect(m["S3"]?.personID == "anna")
        #expect(m["S4"] == nil)
    }

    @Test func voiceprintRoundTripsAndCosine() {
        let v: [Float] = [0.25, -1.5, 3]
        #expect(Voiceprint.decode(Voiceprint.encode(v)) == v)
        #expect(abs(Voiceprint.cosine(v, v) - 1) < 1e-6)
        #expect(Voiceprint.cosine(v, []) == 0)
    }
}

struct SpeakerStoreTests {
    let store: MeetingStore
    let meeting: Meeting
    let earlier: Meeting

    init() throws {
        store = try MeetingStore()
        earlier = Meeting(title: "Monday", appBundleID: "x", appName: "Teams", source: "auto")
        meeting = Meeting(title: "Tuesday", appBundleID: "x", appName: "Teams", source: "auto")
        try store.createMeeting(earlier)
        try store.createMeeting(meeting)
    }

    private func speaker(_ meetingID: String, _ label: String, _ n: Int, speech: Double = 30, v: [Float] = [1, 0]) -> MeetingSpeaker {
        MeetingSpeaker(meetingID: meetingID, label: label, number: n, speechS: speech, embedding: Voiceprint.encode(v))
    }

    @Test func saveSpeakersLabelsSegmentsAndReplacesOldRun() throws {
        try store.appendSegments(meetingID: meeting.id, track: .others, [(0, 2, "Hi."), (3, 5, "Hello.")], cursor: 5)
        let ids = try store.segments(meetingID: meeting.id).compactMap(\.id)
        try store.saveSpeakers(meetingID: meeting.id, [speaker(meeting.id, "S1", 1), speaker(meeting.id, "S2", 2)],
                               segmentLabels: [ids[0]: "S1", ids[1]: "S2"])
        #expect(try store.segments(meetingID: meeting.id).map(\.speaker) == ["S1", "S2"])

        try store.saveSpeakers(meetingID: meeting.id, [speaker(meeting.id, "A", 1)], segmentLabels: [ids[1]: "A"])
        #expect(try store.speakers(meetingID: meeting.id).map(\.label) == ["A"])
        #expect(try store.segments(meetingID: meeting.id).map(\.speaker) == [nil, "A"])
    }

    @Test func galleryHasNamedVoicesFromOtherMeetingsOnly() throws {
        let bob = try store.person(named: "Bob")
        try store.saveSpeakers(meetingID: earlier.id, [speaker(earlier.id, "S1", 1, v: [1, 0]),
                                                       speaker(earlier.id, "S2", 2, speech: 2, v: [0, 1]),
                                                       speaker(earlier.id, "S3", 3, v: [0.5, 0.5])], segmentLabels: [:])
        try store.saveSpeakers(meetingID: meeting.id, [speaker(meeting.id, "S1", 1)], segmentLabels: [:])
        for label in ["S1", "S2"] { try store.nameSpeaker(meetingID: earlier.id, label: label, personID: bob.id) }
        try store.nameSpeaker(meetingID: meeting.id, label: "S1", personID: bob.id)

        let gallery = try store.voiceGallery(excluding: meeting.id)
        #expect(gallery.count == 1)  // S2 is too short, S3 unnamed, today's excluded
        #expect(gallery.first?.personID == bob.id)
        #expect(gallery.first?.voiceprint == [1, 0])
        #expect(try store.meetingCounts() == [bob.id: 2])
    }

    @Test func personNamedReusesExistingCaseInsensitively() throws {
        let a = try store.person(named: "Anna")
        #expect(try store.person(named: "  anna ").id == a.id)
        #expect(try store.people().count == 1)
    }

    @Test func deletingAPersonUnnamesTheirSpeakers() throws {
        let bob = try store.person(named: "Bob")
        try store.saveSpeakers(meetingID: meeting.id, [speaker(meeting.id, "S1", 1)], segmentLabels: [:])
        try store.nameSpeaker(meetingID: meeting.id, label: "S1", personID: bob.id)
        try store.deletePerson(id: bob.id)
        #expect(try store.speakers(meetingID: meeting.id).first?.personID == nil)
    }

    @Test func forgetAllVoicesKeepsTheSplitButNotTheVoiceprints() throws {
        let bob = try store.person(named: "Bob")
        try store.saveSpeakers(meetingID: earlier.id, [speaker(earlier.id, "S1", 1)], segmentLabels: [:])
        try store.nameSpeaker(meetingID: earlier.id, label: "S1", personID: bob.id)
        try store.forgetAllVoices()
        #expect(try store.people().isEmpty)
        let s = try #require(try store.speakers(meetingID: earlier.id).first)
        #expect(s.embedding.isEmpty)
        #expect(try store.voiceGallery(excluding: meeting.id).isEmpty)
    }

    @Test func transcriptUsesNamesAndSplitsBySpeaker() throws {
        let bob = try store.person(named: "Bob")
        try store.appendSegments(meetingID: meeting.id, track: .others,
                                 [(0, 1, "Hi."), (1, 2, "Ready?"), (2, 3, "Yes."), (3, 4, "Unlabelled.")], cursor: 4)
        let ids = try store.segments(meetingID: meeting.id).compactMap(\.id)
        try store.saveSpeakers(meetingID: meeting.id, [speaker(meeting.id, "S1", 1), speaker(meeting.id, "S2", 2)],
                               segmentLabels: [ids[0]: "S1", ids[1]: "S1", ids[2]: "S2"])
        try store.nameSpeaker(meetingID: meeting.id, label: "S1", personID: bob.id)

        let names = TranscriptFormatter.speakerNames(try store.speakers(meetingID: meeting.id), people: try store.people())
        #expect(names == ["S1": "Bob", "S2": "Speaker 2"])
        let lines = TranscriptFormatter.lines(try store.segments(meetingID: meeting.id), names: names)
        #expect(lines.map(\.who) == ["Bob", "Speaker 2", "Others"])
        #expect(lines.first?.text == "Hi. Ready?")
        #expect(lines.first?.speakerLabel == "S1")
        let engine = TranscriptFormatter.engineSegments(try store.segments(meetingID: meeting.id), names: names)
        #expect(engine.map { $0["speaker"] as? String } == ["Bob", "Bob", "Speaker 2", nil])
    }
}
