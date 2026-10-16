import AVFoundation
import Foundation
import MynahCore
import os

private let log = Logger(subsystem: "com.lukekerwin.mynah", category: "meeting")

/// Turns a meeting's WAV tracks into stored transcript segments (in bursts during
/// the call, then to the end once it's over), hides echo, and applies the audio
/// retention setting. Used for live meetings and for recovering after a crash.
@MainActor
final class MeetingProcessor {
    static let sampleRate = 16_000
    static let maxWindow = 120 * sampleRate  // seconds of audio per engine request, at most

    let store: MeetingStore
    let engine: EngineClient
    let settings: SettingsStore

    init(store: MeetingStore, engine: EngineClient, settings: SettingsStore) {
        self.store = store
        self.engine = engine
        self.settings = settings
    }

    nonisolated static func audioURL(_ directory: URL, _ track: Track) -> URL {
        directory.appendingPathComponent("\(track.rawValue).wav")
    }

    nonisolated static var meetingsDirectory: URL {
        SettingsStore.directory.appendingPathComponent("Meetings", isDirectory: true)
    }

    nonisolated static func directory(_ meetingID: String) -> URL {
        meetingsDirectory.appendingPathComponent(meetingID, isDirectory: true)
    }

    private var vocabulary: [String] {
        settings.data.vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Transcribes one window of a track, from its stored cursor up to `available`
    /// samples. Returns false when nothing could be done (engine busy/down, nothing new).
    @discardableResult
    func transcribe(meetingID: String, track: Track, available: Int, final: Bool) async -> Bool {
        guard engine.status == .ready, let meeting = try? store.meeting(id: meetingID) else { return false }
        let cursor = meeting.cursor(track)
        let start = Int(cursor * Double(Self.sampleRate))
        var count = available - start
        guard count >= (final ? 1_600 : Self.sampleRate * 5) else { return false }
        let lastWindow = final && count <= Self.maxWindow
        count = min(count, Self.maxWindow)
        let url = Self.audioURL(Self.directory(meetingID), track)
        do {
            let samples = try await Task.detached(priority: .utility) {
                try WAVReader.read(url: url, from: start, count: count)
            }.value
            guard !samples.isEmpty else { return false }
            let result = try await engine.transcribe(samples: samples, offset: cursor, vocab: vocabulary, final: lastWindow)
            let windowS = Double(samples.count) / Double(Self.sampleRate)
            var consumed = lastWindow ? windowS : min(result.consumed_s, windowS)
            if consumed < 0.5, samples.count == Self.maxWindow { consumed = windowS }  // never stall on a full window
            try store.appendSegments(meetingID: meetingID, track: track,
                                     result.segments.map { (start: $0.start, end: $0.end, text: $0.text) },
                                     cursor: cursor + consumed)
            return consumed > 0
        } catch {
            log.error("transcribe \(meetingID, privacy: .public)/\(track.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// After the call: transcribe both tracks to the end (waiting for the engine if
    /// needed), hide echo, set the status, and compress or delete the audio.
    func finalize(meetingID: String) async {
        for track in [Track.others, .you] {
            let url = Self.audioURL(Self.directory(meetingID), track)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let available = WAVReader.sampleCount(url: url)
            var stalls = 0
            while let m = try? store.meeting(id: meetingID),
                  Int(m.cursor(track) * Double(Self.sampleRate)) < available - 1_600 {
                if await transcribe(meetingID: meetingID, track: track, available: available, final: true) {
                    stalls = 0
                    continue
                }
                stalls += 1
                if stalls > 360 { break }  // ~30 min without the engine: give up on the rest
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        do {
            let all = try store.segments(meetingID: meetingID)
            let echo = EchoFilter.echoIDs(you: all.filter { $0.track == .you }, others: all.filter { $0.track == .others })
            try store.hide(segmentIDs: echo, reason: "echo")
            let hasSpeech = !(try store.segments(meetingID: meetingID)).isEmpty
            try store.modifyMeeting(id: meetingID) {
                $0.hasSpeech = hasSpeech
                $0.status = hasSpeech ? .queued : .noSpeech
                if $0.endedAt == nil { $0.endedAt = Date() }
            }
            log.notice("finalized \(meetingID, privacy: .public): \(all.count) segments, \(echo.count) echo")
        } catch {
            try? store.setStatus(meetingID, .failed, error: error.localizedDescription)
        }
        await keepOrDeleteAudio(meetingID: meetingID)
    }

    /// "Delete after transcript" removes the audio now; otherwise the WAVs are
    /// compressed to AAC (~14 MB/hour/track) until the retention sweep removes them.
    func keepOrDeleteAudio(meetingID: String) async {
        let dir = Self.directory(meetingID)
        if settings.data.meetings.audioRetention == .afterTranscript {
            deleteAudio(meetingID: meetingID)
            return
        }
        await Task.detached(priority: .utility) {
            for track in [Track.others, .you] {
                let wav = Self.audioURL(dir, track)
                guard FileManager.default.fileExists(atPath: wav.path) else { continue }
                let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
                do {
                    try Self.compress(wav, to: m4a)
                    try FileManager.default.removeItem(at: wav)
                } catch {
                    log.error("compress \(wav.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    try? FileManager.default.removeItem(at: m4a)
                }
            }
        }.value
    }

    func deleteAudio(meetingID: String) {
        try? FileManager.default.removeItem(at: Self.directory(meetingID))
        _ = try? store.modifyMeeting(id: meetingID) { $0.audioDeletedAt = Date() }
    }

    /// Deletes audio that the retention setting says is due.
    func sweepRetention(now: Date = Date()) {
        let policy = settings.data.meetings.audioRetention
        guard let meetings = try? store.meetings(status: [.queued, .summarizing, .done, .failed, .noSpeech]) else { return }
        for m in meetings where m.audioDeletedAt == nil {
            guard let ended = m.endedAt, policy.audioDue(endedAt: ended, now: now) else { continue }
            deleteAudio(meetingID: m.id)
        }
    }

    nonisolated static func compress(_ wav: URL, to m4a: URL) throws {
        let input = try AVAudioFile(forReading: wav)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let output = try AVAudioFile(forWriting: m4a, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000) else { return }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
