import Foundation
import MynahCore

/// One live recording: the "Others" tap and the "You" mic, each written to a WAV
/// in the meeting's folder on a shared timeline. Transcription is driven by
/// MeetingController/MeetingProcessor reading those files.
@available(macOS 14.2, *)
@MainActor
final class MeetingSession {
    let meetingID: String
    let directory: URL
    private(set) var startedAt = Date()
    private var tap: ProcessTap?
    private var mic: MeetingMic?
    private(set) var othersWriter: TrackWriter?
    private(set) var youWriter: TrackWriter?
    /// The tap has delivered at least one non-zero sample (permission is granted).
    private(set) var othersEverHeard = false

    private let micUID: String

    init(meetingID: String, directory: URL, micUID: String) {
        self.meetingID = meetingID
        self.directory = directory
        self.micUID = micUID
    }

    func start(target: ProcessTap.Target) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let othersRing = RingBuffer(capacity: 48_000 * 10)
        let youRing = RingBuffer(capacity: 48_000 * 10)

        let tap = ProcessTap(target: target, ring: othersRing)
        try await Task.detached(priority: .userInitiated) { try tap.start() }.value  // ≤ 2 s
        let mic = MeetingMic(ring: youRing, deviceUID: micUID)
        do {
            try mic.start()
        } catch {
            tap.stop()
            throw error
        }
        let others = try TrackWriter(url: MeetingProcessor.audioURL(directory, .others), sourceRate: tap.sampleRate, ring: othersRing)
        let you = try TrackWriter(url: MeetingProcessor.audioURL(directory, .you), sourceRate: mic.sampleRate, ring: youRing)
        tap.onRebuild = { [weak others, weak tap] _ in
            if let rate = tap?.sampleRate { others?.updateSourceRate(rate) }
        }
        mic.onRateChange = { [weak you] rate in you?.updateSourceRate(rate) }

        // Both tracks start at the same instant: discard what arrived while setting up.
        _ = othersRing.drain()
        _ = youRing.drain()
        startedAt = Date()
        others.start()
        you.start()
        self.tap = tap
        self.mic = mic
        othersWriter = others
        youWriter = you
    }

    func update(target: ProcessTap.Target) {
        tap?.update(target: target)
    }

    func setGate(_ change: (inout MeetingMic.Gate) -> Void) {
        mic?.gate.withLock { change(&$0) }
    }

    /// Peak of the "Others" track since the last call (also tracks othersEverHeard).
    func takeOthersPeak() -> Float {
        let peak = othersWriter?.takeStats().peak ?? 0
        if peak > 0 { othersEverHeard = true }
        return peak
    }

    /// Peak of the "You" track since the last call (silence while gated).
    func takeYouPeak() -> Float {
        youWriter?.takeStats().peak ?? 0
    }

    func samplesWritten(_ track: Track) -> Int {
        (track == .you ? youWriter : othersWriter)?.samplesWritten ?? 0
    }

    func stop() {
        tap?.stop()
        tap = nil
        mic?.stop()
        mic = nil
        othersWriter?.close()
        youWriter?.close()
    }
}
