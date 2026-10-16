import Foundation
import Testing
@testable import MynahCore

struct BleedGateTests {
    static let rate = 16_000

    /// Speech-like test signal: noise in syllable-length bursts of varying loudness.
    /// `talking` limits it to those time ranges (seconds).
    func speech(seconds: Double, seed: UInt64, level: Float, talking: [ClosedRange<Double>]) -> [Float] {
        var rng = Rng(seed)
        let n = Int(seconds * Double(Self.rate))
        var x = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let len = Int(rng.uniform(0.08, 0.3) * Double(Self.rate))
            let gap = Int(rng.uniform(0.02, 0.15) * Double(Self.rate))
            let amp = level * Float(rng.uniform(0.3, 1))
            for s in i..<min(n, i + len) {
                let t = Double(s) / Double(Self.rate)
                if talking.contains(where: { $0.contains(t) }) { x[s] = amp * Float(rng.uniform(-1, 1)) }
            }
            i += len + gap
        }
        return x
    }

    /// What the laptop mic hears of `others` through its speakers: later, quieter, with some echo.
    func leak(_ others: [Float], delay: Int, gain: Float) -> [Float] {
        var y = [Float](repeating: 0, count: others.count)
        for (d, g) in [(delay, gain), (delay + 800, gain * 0.4), (delay + 2_000, gain * 0.15)] {
            for s in d..<others.count { y[s] += g * others[s - d] }
        }
        return y
    }

    func noise(_ n: Int, level: Float, seed: UInt64) -> [Float] {
        var rng = Rng(seed)
        return (0..<n).map { _ in level * Float(rng.uniform(-1, 1)) }
    }

    func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map(+) }

    func energy(_ x: [Float], _ range: ClosedRange<Double>) -> Float {
        let lo = Int(range.lowerBound * Double(Self.rate)), hi = Int(range.upperBound * Double(Self.rate))
        return x[lo..<hi].reduce(0) { $0 + $1 * $1 }
    }

    /// Splits a 16 s call track into the gate's (others-with-lead, you) layout.
    func window(_ others: [Float], _ you: [Float], from: Int) -> (others: [Float], you: [Float], lead: Int) {
        let lead = min(from, BleedGate.othersLead)
        return (Array(others[(from - lead)...]), Array(you[from...]), lead)
    }

    @Test func removesTheCallFromTheMicOnSpeakers() throws {
        let others = speech(seconds: 16, seed: 1, level: 0.3, talking: [0...16])
        let mic = add(leak(others, delay: 1_600, gain: 0.05), noise(others.count, level: 0.0005, seed: 2))
        let w = window(others, mic, from: 32_000)
        guard case let .coupled(c) = BleedGate.estimate(you: w.you, others: w.others, lead: w.lead) else {
            Issue.record("expected coupling")
            return
        }
        #expect(abs(c.lag - 5) <= 1)  // 100 ms
        let out = BleedGate.apply(c, you: w.you, others: w.others, lead: w.lead)
        #expect(energy(out, 0...13.9) < energy(w.you, 0...13.9) * 0.02)
    }

    @Test func keepsYouTalkingOverTheCall() throws {
        let others = speech(seconds: 16, seed: 3, level: 0.3, talking: [0...16])
        let me = speech(seconds: 16, seed: 4, level: 0.15, talking: [6...9])
        let mic = add(add(leak(others, delay: 1_600, gain: 0.05), me), noise(others.count, level: 0.0005, seed: 5))
        let w = window(others, mic, from: 32_000)
        guard case let .coupled(c) = BleedGate.estimate(you: w.you, others: w.others, lead: w.lead) else {
            Issue.record("expected coupling")
            return
        }
        let out = BleedGate.apply(c, you: w.you, others: w.others, lead: w.lead)
        // Your speech is in the window at 4…7 s.
        #expect(energy(out, 4...7) > energy(w.you, 4...7) * 0.9)
        #expect(energy(out, 9...13.9) < energy(w.you, 9...13.9) * 0.02)
    }

    /// Leak delays 0–600 ms, quiet to loud speakers, you talking up to half the time.
    @Test(arguments: [(0, Float(0.1), 6.0...9.0), (4_800, 0.02, 3.0...10.0), (9_600, 0.05, 1.0...8.0), (3_200, 0.01, 6.0...7.0)])
    func handlesDifferentRooms(delay: Int, gain: Float, talking: ClosedRange<Double>) throws {
        let others = speech(seconds: 16, seed: UInt64(delay), level: 0.3, talking: [0...16])
        let me = speech(seconds: 16, seed: 20, level: 0.15, talking: [talking.lowerBound + 2...talking.upperBound + 2])
        let mic = add(add(leak(others, delay: delay, gain: gain), me), noise(others.count, level: 0.0005, seed: 21))
        let w = window(others, mic, from: 32_000)
        guard case let .coupled(c) = BleedGate.estimate(you: w.you, others: w.others, lead: w.lead) else {
            Issue.record("expected coupling")
            return
        }
        #expect(abs(c.lag - delay / BleedGate.block) <= 1)
        let out = BleedGate.apply(c, you: w.you, others: w.others, lead: w.lead)
        #expect(energy(out, talking) > energy(w.you, talking) * 0.9)
        #expect(energy(out, talking.upperBound + 0.5...13.9) < energy(w.you, talking.upperBound + 0.5...13.9) * 0.05)
    }

    @Test func leavesHeadphoneAudioAlone() {
        let others = speech(seconds: 16, seed: 6, level: 0.3, talking: [0...16])
        let mic = add(speech(seconds: 16, seed: 7, level: 0.15, talking: [3...5, 10...12]),
                      noise(others.count, level: 0.0005, seed: 8))
        let w = window(others, mic, from: 32_000)
        #expect(BleedGate.estimate(you: w.you, others: w.others, lead: w.lead) == .uncoupled)
    }

    @Test func unknownWhileTheCallIsQuiet() {
        let others = [Float](repeating: 0, count: 16 * Self.rate)
        let mic = speech(seconds: 16, seed: 9, level: 0.15, talking: [3...5])
        let w = window(others, mic, from: 32_000)
        #expect(BleedGate.estimate(you: w.you, others: w.others, lead: w.lead) == .unknown)
    }

    @Test func doesNotTouchTheMicWhenTheCallIsSilent() {
        let others = speech(seconds: 16, seed: 10, level: 0.3, talking: [0...4])
        let mic = add(leak(others, delay: 1_600, gain: 0.05),
                      speech(seconds: 16, seed: 11, level: 0.02, talking: [10...14]))  // quiet, but no call audio
        let w = window(others, mic, from: 0)
        let out = BleedGate.apply(.init(lag: 5, gainDB: -26), you: w.you, others: w.others, lead: w.lead)
        #expect(energy(out, 10...14) == energy(w.you, 10...14))
    }
}

/// Deterministic SplitMix64.
private struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}
