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
            var samples = try await Task.detached(priority: .utility) {
                try WAVReader.read(url: url, from: start, count: count)
            }.value
            guard !samples.isEmpty else { return false }
            if track == .you { samples = try await removeBleed(meetingID: meetingID, you: samples, from: start) }
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

    /// Per meeting: how the call leaks into the mic, from the last window that showed it.
    private var couplings: [String: BleedGate.Coupling] = [:]

    /// Silences the call audio the mic picked up through the speakers (see BleedGate).
    private func removeBleed(meetingID: String, you: [Float], from start: Int) async throws -> [Float] {
        let othersURL = Self.audioURL(Self.directory(meetingID), .others)
        guard FileManager.default.fileExists(atPath: othersURL.path) else { return you }
        let lead = min(start, BleedGate.othersLead)
        let previous = couplings[meetingID]
        let (out, coupling) = try await Task.detached(priority: .utility) {
            var others = try WAVReader.read(url: othersURL, from: start - lead, count: lead + you.count)
            others += [Float](repeating: 0, count: max(0, lead + you.count - others.count))
            var coupling = previous
            switch BleedGate.estimate(you: you, others: others, lead: lead) {
            case let .coupled(c): coupling = c
            case .uncoupled: coupling = nil
            case .unknown: break
            }
            guard let coupling else { return (you, nil as BleedGate.Coupling?) }
            return (BleedGate.apply(coupling, you: you, others: others, lead: lead), coupling)
        }.value
        if coupling != previous {
            log.notice("bleed \(meetingID, privacy: .public): \(coupling.map { "lag \($0.lag * 20) ms, \(Int($0.gainDB)) dB" } ?? "none", privacy: .public)")
        }
        couplings[meetingID] = coupling
        return out
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

        couplings[meetingID] = nil

        do {
            let all = try store.segments(meetingID: meetingID)
            let echo = try hideEcho(meetingID: meetingID)
            if settings.data.meetings.recognizeSpeakers { await identifySpeakers(meetingID: meetingID) }
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

    /// Hides "You" lines that repeat what the others said (mic leak BleedGate missed).
    @discardableResult
    func hideEcho(meetingID: String) throws -> [Int64] {
        let all = try store.segments(meetingID: meetingID)
        let echo = EchoFilter.echoIDs(you: all.filter { $0.track == .you }, others: all.filter { $0.track == .others })
        try store.hide(segmentIDs: echo, reason: "echo")
        return echo
    }

    /// Splits the "Others" track into voices, labels its segments, and names voices
    /// that match people the user has named before. Needs the audio; a failure (say,
    /// no network for the first model download) just leaves the transcript as "Others".
    @discardableResult
    func identifySpeakers(meetingID: String) async -> Bool {
        let dir = Self.directory(meetingID)
        let wav = Self.audioURL(dir, .others)
        let url = FileManager.default.fileExists(atPath: wav.path) ? wav : wav.deletingPathExtension().appendingPathExtension("m4a")
        guard FileManager.default.fileExists(atPath: url.path),
              let segments = try? store.segments(meetingID: meetingID).filter({ $0.track == .others }), !segments.isEmpty
        else { return false }
        do {
            let t0 = Date()
            let result = try await SpeakerDiarizer.diarize(url: url)
            let gallery = try store.voiceGallery(excluding: meetingID)
            let matches = SpeakerMatching.match(
                voices: result.voices.filter { $0.value.speechS >= SpeakerMatching.minSpeechS }.mapValues(\.voiceprint),
                gallery: gallery)
            let labels = SpeakerMatching.labels(for: segments.map { ($0.startS, $0.endS) }, turns: result.turns)
            var segmentLabels: [Int64: String] = [:]
            for (seg, label) in zip(segments, labels) {
                if let id = seg.id, let label, result.voices[label] != nil { segmentLabels[id] = label }
            }
            // Only voices that actually say something in the transcript are worth listing.
            let used = Set(segmentLabels.values)
            let numbers = SpeakerMatching.numbers(result.turns.filter { used.contains($0.label) })
            let speakers = result.voices.filter { used.contains($0.key) }.compactMap { label, voice -> MeetingSpeaker? in
                guard let number = numbers[label] else { return nil }
                let match = matches[label]
                return MeetingSpeaker(meetingID: meetingID, label: label, number: number, speechS: voice.speechS,
                                      embedding: Voiceprint.encode(voice.voiceprint), personID: match?.personID,
                                      matchScore: match.map { Double($0.score) })
            }
            try store.saveSpeakers(meetingID: meetingID, speakers, segmentLabels: segmentLabels)
            log.notice("speakers \(meetingID, privacy: .public): \(speakers.count) voices, \(matches.count) recognized, \(Date().timeIntervalSince(t0), format: .fixed(precision: 1)) s")
            return true
        } catch {
            log.error("speakers \(meetingID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
