import FluidAudio
import Foundation

// speaker-probe --out <dir> <audio>...
// For each file: offline diarization (pyannote community-1 + WeSpeaker + VBx on
// Core ML), then a CAM++ voiceprint per speaker. Writes <dir>/<file stem>.json.

struct SegmentOut: Codable { let start: Double, end: Double, speaker: String }
struct SpeakerOut: Codable {
    let speechS: Double
    let wespeaker: [Float]  // 256-d centroid from the diarizer
    let campp: [Float]?  // 192-d CAM++ over up to `maxEmbedS` of the speaker's longest turns
}
struct ProbeOut: Codable {
    let file: String
    let durationS: Double
    let diarizeS: Double
    let embedS: Double
    let segments: [SegmentOut]
    let speakers: [String: SpeakerOut]
}

let sampleRate = 16_000
let chunkS = 10.0  // CAM++ is run on pieces of at most this length, then averaged
let minTurnS = 1.5
let maxEmbedS = 90.0

func average(_ vectors: [[Float]]) -> [Float]? {
    guard let first = vectors.first else { return nil }
    var sum = [Float](repeating: 0, count: first.count)
    for v in vectors { for i in sum.indices { sum[i] += v[i] } }
    let norm = max(sqrt(sum.reduce(0) { $0 + $1 * $1 }), 1e-9)
    return sum.map { $0 / norm }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let outFlag = args.firstIndex(of: "--out"), outFlag + 1 < args.count else {
    FileHandle.standardError.write("usage: speaker-probe --out <dir> <audio>...\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[outFlag + 1], isDirectory: true)
args.removeSubrange(outFlag...(outFlag + 1))
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let diarizer = OfflineDiarizerManager(config: .default)
try await diarizer.prepareModels()
let campp = try await CampPlusEmbedder.load()
let converter = AudioConverter(sampleRate: Double(sampleRate))
let encoder = JSONEncoder()

for path in args {
    let url = URL(fileURLWithPath: path)
    let stem = url.deletingPathExtension().lastPathComponent
    let audio = try converter.resampleAudioFile(url)
    let durationS = Double(audio.count) / Double(sampleRate)

    let t0 = Date()
    let result = try await diarizer.process(audio: audio)
    let diarizeS = Date().timeIntervalSince(t0)

    let t1 = Date()
    var turns: [String: [TimedSpeakerSegment]] = [:]
    for seg in result.segments { turns[seg.speakerId, default: []].append(seg) }
    var speakers: [String: SpeakerOut] = [:]
    for (id, centroid) in result.speakerDatabase ?? [:] {
        let mine = turns[id] ?? []
        let speechS = mine.reduce(0.0) { $0 + Double($1.durationSeconds) }
        // Longest turns first, cut into ≤10 s pieces, until maxEmbedS of speech.
        var pieces: [[Float]] = []
        var used = 0.0
        for seg in mine.sorted(by: { $0.durationSeconds > $1.durationSeconds }) where Double(seg.durationSeconds) >= minTurnS {
            var s = Double(seg.startTimeSeconds)
            let e = Double(seg.endTimeSeconds)
            while s < e - minTurnS / 2, used < maxEmbedS {
                let pe = min(e, s + chunkS)
                let a = max(0, Int(s * Double(sampleRate))), b = min(audio.count, Int(pe * Double(sampleRate)))
                if b - a >= Int(minTurnS * Double(sampleRate)) {
                    pieces.append(try await campp.embed(audio: Array(audio[a..<b])))
                    used += pe - s
                }
                s = pe
            }
            if used >= maxEmbedS { break }
        }
        speakers[id] = SpeakerOut(speechS: speechS, wespeaker: centroid, campp: average(pieces))
    }
    let embedS = Date().timeIntervalSince(t1)

    let out = ProbeOut(file: url.lastPathComponent, durationS: durationS, diarizeS: diarizeS, embedS: embedS,
                       segments: result.segments.map {
                           SegmentOut(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
                       },
                       speakers: speakers)
    try encoder.encode(out).write(to: outDir.appendingPathComponent("\(stem).json"))
    print(String(format: "%@  %.0f min audio  %d speakers  diarize %.1fs (%.0fx)  embed %.1fs",
                 stem, durationS / 60, speakers.count, diarizeS, durationS / diarizeS, embedS))
}
