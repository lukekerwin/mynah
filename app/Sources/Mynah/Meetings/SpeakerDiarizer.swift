import FluidAudio
import Foundation
import MynahCore

/// Splits a recording into voices with FluidAudio's offline pipeline (pyannote
/// segmentation, WeSpeaker voiceprints, VBx clustering) on the Neural Engine, about
/// 150x faster than realtime. The models (~21 MB) download on first use.
enum SpeakerDiarizer {
    struct Voice {
        var voiceprint: [Float]
        var speechS: Double
    }

    struct Result {
        var turns: [SpeakerMatching.Turn]
        var voices: [String: Voice]
    }

    static var modelsDirectory: URL {
        SettingsStore.directory.appendingPathComponent("Models/Speakers", isDirectory: true)
    }

    /// Any file AVAudioFile reads (the WAV during a call, the AAC copy afterwards).
    static func diarize(url: URL) async throws -> Result {
        // Built per call so the models don't sit in memory between meetings.
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels(directory: Self.modelsDirectory)
        let result = try await manager.process(url)
        var speech: [String: Double] = [:]
        for s in result.segments { speech[s.speakerId, default: 0] += Double(s.durationSeconds) }
        var voices: [String: Voice] = [:]
        for (id, v) in result.speakerDatabase ?? [:] { voices[id] = Voice(voiceprint: v, speechS: speech[id] ?? 0) }
        let turns = result.segments.map {
            SpeakerMatching.Turn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), label: $0.speakerId)
        }
        return Result(turns: turns, voices: voices)
    }
}
