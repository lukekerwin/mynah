import Foundation
import Testing
@testable import MynahCore

struct MeetingSettingsTests {
    @Test func oldSettingsDecodeToDefaults() throws {
        let s = try JSONDecoder().decode(MeetingSettings.self, from: Data("{}".utf8))
        #expect(s == MeetingSettings())
        #expect(!s.enabled && s.autoRecord && s.audioRetention == .days7 && s.summaryModel == "default")
    }

    @Test func partialAndUnknownValues() throws {
        let json = #"{"enabled": true, "audioRetention": "bogus", "myName": "Luke"}"#
        let s = try JSONDecoder().decode(MeetingSettings.self, from: Data(json.utf8))
        #expect(s.enabled && s.myName == "Luke" && s.audioRetention == .days7)
    }

    @Test func roundTrip() throws {
        var s = MeetingSettings()
        s.enabled = true
        s.autoRecord = false
        s.audioRetention = .forever
        let back = try JSONDecoder().decode(MeetingSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}

struct TeamsUITests {
    @Test func title() {
        #expect(TeamsUI.meetingTitle(windowTitle: "Test Meeting | Microsoft Teams") == "Test Meeting")
        #expect(TeamsUI.meetingTitle(windowTitle: "A | B | Microsoft Teams") == "A | B")
        #expect(TeamsUI.meetingTitle(windowTitle: "teams.microsoft.com/v2/") == nil)
        #expect(TeamsUI.meetingTitle(windowTitle: " | Microsoft Teams") == nil)
    }

    @Test func mute() {
        #expect(TeamsUI.isMuted(buttonDescriptions: ["Turn camera off", "Unmute mic", "Leave"]) == true)
        #expect(TeamsUI.isMuted(buttonDescriptions: ["Turn camera off", "Mute mic"]) == false)
        #expect(TeamsUI.isMuted(buttonDescriptions: ["Leave"]) == nil)
    }
}

struct WAVReaderTests {
    @Test func readsWindows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = WAVHeader.make(dataBytes: 8)
        for v: Int16 in [0, 16384, -16384, 32767] { data.appendLE(v) }
        try data.write(to: url)
        #expect(WAVReader.sampleCount(url: url) == 4)
        #expect(try WAVReader.read(url: url, from: 1, count: 2) == [0.5, -0.5])
        #expect(try WAVReader.read(url: url, from: 3, count: 10).count == 1)
        #expect(try WAVReader.read(url: url, from: 4, count: 10).isEmpty)
    }
}

struct SummaryEligibilityTests {
    typealias C = SummaryEligibility.Conditions

    @Test func automatic() {
        #expect(SummaryEligibility.canStart(C(engineReady: true, recording: false, dictating: false, thermalState: 0)))
        #expect(SummaryEligibility.canStart(C(engineReady: true, recording: false, dictating: false, thermalState: 1)))
        #expect(!SummaryEligibility.canStart(C(engineReady: true, recording: false, dictating: false, thermalState: 2)))
        #expect(!SummaryEligibility.canStart(C(engineReady: true, recording: true, dictating: false, thermalState: 0)))
        #expect(!SummaryEligibility.canStart(C(engineReady: true, recording: false, dictating: true, thermalState: 0)))
        #expect(!SummaryEligibility.canStart(C(engineReady: false, recording: false, dictating: false, thermalState: 0)))
    }

    @Test func manualIgnoresHeatButNotCalls() {
        #expect(SummaryEligibility.canStart(C(engineReady: true, recording: false, dictating: true, thermalState: 3, manual: true)))
        #expect(!SummaryEligibility.canStart(C(engineReady: true, recording: true, dictating: false, thermalState: 0, manual: true)))
        #expect(SummaryEligibility.shouldInterrupt(C(engineReady: true, recording: true, dictating: false, thermalState: 0, manual: true)))
        #expect(!SummaryEligibility.shouldInterrupt(C(engineReady: true, recording: false, dictating: false, thermalState: 3, manual: true)))
        #expect(SummaryEligibility.shouldInterrupt(C(engineReady: true, recording: false, dictating: false, thermalState: 2)))
    }
}
