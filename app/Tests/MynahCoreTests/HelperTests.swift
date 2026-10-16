import Foundation
import Testing
@testable import MynahCore

struct EchoFilterTests {
    func seg(_ id: Int64, _ track: Track, _ s: Double, _ e: Double, _ text: String) -> Segment {
        Segment(id: id, meetingID: "m", track: track, startS: s, endS: e, text: text)
    }

    @Test func exactAndPartialEcho() {
        let others = [seg(1, .others, 10, 14, "Can you send me the updated invoice by Friday?")]
        let you = [
            seg(2, .you, 10.3, 14.2, "can you send me the updated invoice by friday"),  // echo
            seg(3, .you, 11, 13, "send me the invoice, sure thing, and also my notes from yesterday"),  // < 60%
            seg(4, .you, 30, 33, "can you send me the updated invoice by friday"),  // no time overlap
            seg(5, .you, 11, 12, "by Friday"),  // too short to judge
        ]
        #expect(EchoFilter.echoIDs(you: you, others: others) == [2])
    }

    @Test func overlapUsesSlackAndMultipleOthers() {
        let others = [seg(1, .others, 1, 3.2, "the launch moves"), seg(2, .others, 3.2, 4, "to November third")]
        let you = [seg(3, .you, 4.5, 5.5, "the launch moves to November third")]  // both within 1.5 s slack
        #expect(EchoFilter.echoIDs(you: you, others: others) == [3])
    }
}

struct WAVHeaderTests {
    @Test func makeAndRepair() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = WAVHeader.make(dataBytes: 0)
        #expect(data.count == WAVHeader.size)
        data.append(Data(repeating: 1, count: 1001))  // odd: a torn last sample
        try data.write(to: url)
        #expect(try WAVHeader.repair(url: url) == 500)
        let fixed = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 { fixed[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        #expect(u32(40) == 1000)
        #expect(u32(4) == 1036)
        #expect(String(decoding: fixed[0..<4], as: UTF8.self) == "RIFF")
        #expect(u32(24) == 16_000)
    }
}

struct RetentionTests {
    let end = Date(timeIntervalSince1970: 1_000_000)

    @Test func policies() {
        #expect(AudioRetention.afterTranscript.audioDue(endedAt: end, now: end))
        #expect(!AudioRetention.days7.audioDue(endedAt: end, now: end.addingTimeInterval(7 * 86_400 - 1)))
        #expect(AudioRetention.days7.audioDue(endedAt: end, now: end.addingTimeInterval(7 * 86_400)))
        #expect(!AudioRetention.days30.audioDue(endedAt: end, now: end.addingTimeInterval(29 * 86_400)))
        #expect(!AudioRetention.forever.audioDue(endedAt: end, now: end.addingTimeInterval(1e9)))
    }
}

struct TranscriptFormatterTests {
    @Test func mergesSameSpeakerAndSkipsHidden() {
        let segs = [
            Segment(id: 3, meetingID: "m", track: .you, startS: 9, endS: 10, text: "Sure."),
            Segment(id: 1, meetingID: "m", track: .others, startS: 0, endS: 2, text: "Hi."),
            Segment(id: 2, meetingID: "m", track: .others, startS: 2, endS: 4, text: "Send it?"),
            Segment(id: 4, meetingID: "m", track: .you, startS: 9.5, endS: 10, text: "echo", hiddenReason: "echo"),
            Segment(id: 5, meetingID: "m", track: .others, startS: 11, endS: 12, text: "Thanks."),
        ]
        let lines = TranscriptFormatter.lines(segs)
        #expect(lines.map(\.text) == ["Hi. Send it?", "Sure.", "Thanks."])
        #expect(lines[0].segmentIDs == [1, 2])
        #expect(TranscriptFormatter.engineSegments(segs).count == 4)
        #expect(TranscriptFormatter.timestamp(754) == "12:34")
    }

    @Test func splitsSameSpeakerAtPausesAndLength() {
        let segs = [
            Segment(id: 1, meetingID: "m", track: .others, startS: 0, endS: 3, text: "First person."),
            Segment(id: 2, meetingID: "m", track: .others, startS: 3.5, endS: 6, text: "Still them."),
            Segment(id: 3, meetingID: "m", track: .others, startS: 8, endS: 10, text: "Someone else."),  // 2 s pause
            Segment(id: 4, meetingID: "m", track: .others, startS: 10.5, endS: 30, text: "Long point."),
            Segment(id: 5, meetingID: "m", track: .others, startS: 30.5, endS: 45, text: "Continued."),  // > 30 s
        ]
        #expect(TranscriptFormatter.lines(segs).map(\.text)
            == ["First person. Still them.", "Someone else. Long point.", "Continued."])
        #expect(TranscriptFormatter.timestamp(3700) == "1:01:40")
    }
}

struct RingBufferTests {
    @Test func wrapsAndDrainsInOrder() {
        let ring = RingBuffer(capacity: 8)
        let a: [Float] = [1, 2, 3, 4, 5]
        a.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) }
        #expect(ring.drain() == [1, 2, 3, 4, 5])
        let b: [Float] = [6, 7, 8, 9, 10, 11]
        b.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) }  // wraps around the end
        #expect(ring.drain() == [6, 7, 8, 9, 10, 11])
        #expect(ring.drain() == [])
    }

    @Test func overflowDropsOldestAndZeroWrites() {
        let ring = RingBuffer(capacity: 4)
        let a: [Float] = [1, 2, 3, 4, 5, 6]
        a.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) }
        #expect(ring.drain() == [3, 4, 5, 6])
        #expect(ring.takeDropped() == 2)
        #expect(ring.takeDropped() == 0)
        a.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3, zero: true) }
        #expect(ring.drain() == [0, 0, 0])
    }
}

struct SemanticVersionTests {
    @Test func ordersReleasesAndPreReleases() {
        let ascending = ["0.1.9", "0.2.0-beta.2", "0.2.0-beta.3", "0.2.0-beta.10", "0.2.0-rc.1", "0.2.0", "0.2.1-beta.1",
                         "0.2.1", "0.10.0", "1.0.0"]
        for (i, a) in ascending.enumerated() {
            for b in ascending[(i + 1)...] {
                #expect(SemanticVersion.compare(a, b) == .orderedAscending, "\(a) < \(b)")
                #expect(SemanticVersion.compare(b, a) == .orderedDescending, "\(b) > \(a)")
            }
        }
    }

    @Test func equalVersions() {
        #expect(SemanticVersion.compare("0.2.0", "0.2.0") == .orderedSame)
        #expect(SemanticVersion.compare("v0.2", "0.2.0+42") == .orderedSame)
        #expect(SemanticVersion.compare("0.2.0-beta.1", "0.2.0-beta.1") == .orderedSame)
    }
}
