import Foundation

/// On speakers the mic also hears the call, and anything on the mic track is
/// transcribed as "You" — even while you're muted in Teams. This silences the
/// stretches of the mic track that the call audio explains.
///
/// Works on 20 ms energy envelopes of both tracks (16 kHz, shared timeline).
/// `estimate` finds how the call leaks into the mic: the delay with the best
/// envelope correlation, and the level drop. With headphones there's no such
/// correlation and nothing is touched. `apply` then zeroes mic blocks that
/// aren't clearly louder than the predicted leak, keeping a little audio around
/// anything that is (you talking over the call).
public enum BleedGate {
    public static let block = 320  // 20 ms at 16 kHz
    /// How far the mic may lag the call audio (speaker + mic latency), in blocks.
    public static let maxLag = 40
    /// How far the mic may lead it (the two capture paths buffer differently).
    public static let maxLead = 10
    /// Samples of call audio needed before the mic window.
    public static var othersLead: Int { (maxLag + tail) * block }

    static let floorDB: Float = -80
    static let activeDB: Float = -50  // the call is playing something
    static let minActiveBlocks = 50  // 1 s of call audio to judge coupling
    static let minCorrelation: Float = 0.55
    static let marginDB: Float = 6  // the mic must beat the predicted leak by this to count as you
    static let tail = 8  // room reverb: the leak lingers this many blocks…
    static let tailDecayDB: Float = 3  // …fading this much per block
    static let hang = 10  // blocks kept either side of your speech

    public struct Coupling: Equatable, Sendable {
        public var lag: Int  // blocks; positive = the mic hears it later
        public var gainDB: Float  // mic level minus call level
        public init(lag: Int, gainDB: Float) {
            self.lag = lag
            self.gainDB = gainDB
        }
    }

    public enum Estimate: Equatable, Sendable {
        case coupled(Coupling)
        case uncoupled  // enough call audio, and the mic doesn't follow it
        case unknown  // too little call audio to tell
    }

    /// `others` covers the same time as `you`, preceded by `lead` extra samples.
    public static func estimate(you: [Float], others: [Float], lead: Int) -> Estimate {
        let m = envelope(you)
        let o = envelope(others)
        let shift = lead / block
        var best: (r: Float, lag: Int) = (-1, 0)
        var enough = false
        for lag in -maxLead...maxLag {
            var xs: [Float] = [], ys: [Float] = []
            for i in m.indices {
                let j = i + shift - lag
                // Exact silence on the mic is the gate (muted, dictating), not the room.
                guard j >= 0, j < o.count, o[j] > activeDB, m[i] > floorDB else { continue }
                xs.append(o[j])
                ys.append(m[i])
            }
            guard xs.count >= minActiveBlocks else { continue }
            enough = true
            // Leave out blocks far louder than the typical leak: that's you talking over the call.
            let typical = median(zip(ys, xs).map { $0 - $1 })
            let kept = xs.indices.filter { ys[$0] - xs[$0] <= typical + marginDB * 2 }
            guard kept.count >= minActiveBlocks else { continue }
            let r = correlation(kept.map { xs[$0] }, kept.map { ys[$0] })
            if r > best.r { best = (r, lag) }
        }
        guard enough else { return .unknown }
        guard best.r >= minCorrelation else { return .uncoupled }
        // Typical leak level; a low percentile ignores blocks where you talk over the call.
        var diffs: [Float] = []
        for i in m.indices {
            let j = i + shift - best.lag
            guard j >= 0, j < o.count, o[j] > activeDB + 10, m[i] > floorDB else { continue }
            diffs.append(m[i] - o[j])
        }
        guard !diffs.isEmpty else { return .unknown }
        diffs.sort()
        return .coupled(Coupling(lag: best.lag, gainDB: diffs[diffs.count * 3 / 10]))
    }

    /// `you` with the leaked blocks zeroed. Same `others`/`lead` layout as `estimate`.
    public static func apply(_ c: Coupling, you: [Float], others: [Float], lead: Int) -> [Float] {
        let m = envelope(you)
        let o = envelope(others)
        let shift = lead / block
        var leak = [Bool](repeating: false, count: m.count)
        var mine = [Bool](repeating: false, count: m.count)
        for i in m.indices {
            var predicted = floorDB
            for k in -1...tail {
                let j = i + shift - c.lag - k
                guard j >= 0, j < o.count, o[j] > activeDB else { continue }
                predicted = max(predicted, o[j] + c.gainDB - tailDecayDB * Float(max(k, 0)))
            }
            guard predicted > floorDB else { continue }
            if m[i] > predicted + marginDB { mine[i] = true } else { leak[i] = true }
        }
        var out = you
        for i in m.indices where leak[i] {
            let near = max(0, i - hang)...min(m.count - 1, i + hang)
            if near.contains(where: { mine[$0] }) { continue }
            let end = min(out.count, (i + 1) * block)
            for s in (i * block)..<end { out[s] = 0 }
        }
        return out
    }

    static func envelope(_ x: [Float]) -> [Float] {
        let n = (x.count + block - 1) / block
        return (0..<n).map { b in
            let lo = b * block, hi = min(x.count, lo + block)
            var sum: Float = 0
            for s in lo..<hi { sum += x[s] * x[s] }
            return max(floorDB, 10 * log10(sum / Float(hi - lo) + 1e-12))
        }
    }

    static func median(_ x: [Float]) -> Float {
        x.isEmpty ? 0 : x.sorted()[x.count / 2]
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab: Float = 0, saa: Float = 0, sbb: Float = 0
        for k in a.indices {
            let da = a[k] - ma, db = b[k] - mb
            sab += da * db
            saa += da * da
            sbb += db * db
        }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }
}
