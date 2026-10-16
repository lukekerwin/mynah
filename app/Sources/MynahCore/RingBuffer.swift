import Foundation
import os

/// Fixed-size buffer between a real-time audio callback (producer) and a writer
/// queue (consumer). The producer never allocates; the lock is held only for a
/// memcpy. When full, the oldest samples are overwritten and counted as dropped.
public final class RingBuffer: @unchecked Sendable {
    private struct State {
        var storage: [Float]
        var readIndex = 0
        var count = 0
        var dropped = 0
        var written = 0
    }

    private let lock: OSAllocatedUnfairLock<State>
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
        lock = OSAllocatedUnfairLock(initialState: State(storage: [Float](repeating: 0, count: capacity)))
    }

    /// Producer side. `zero` writes silence of the same length instead (gated mic).
    public func write(_ samples: UnsafePointer<Float>, count n: Int, zero: Bool = false) {
        guard n > 0 else { return }
        lock.withLockUnchecked { s in
            let cap = capacity
            var src = samples
            var remaining = n
            if remaining > cap {  // only the newest `cap` samples fit
                s.dropped += remaining - cap
                src += remaining - cap
                remaining = cap
            }
            let overflow = s.count + remaining - cap
            if overflow > 0 {
                s.readIndex = (s.readIndex + overflow) % cap
                s.count -= overflow
                s.dropped += overflow
            }
            var writeIndex = (s.readIndex + s.count) % cap
            s.storage.withUnsafeMutableBufferPointer { buf in
                var left = remaining
                while left > 0 {
                    let chunk = min(left, cap - writeIndex)
                    if zero {
                        (buf.baseAddress! + writeIndex).update(repeating: 0, count: chunk)
                    } else {
                        (buf.baseAddress! + writeIndex).update(from: src, count: chunk)
                        src += chunk
                    }
                    left -= chunk
                    writeIndex = (writeIndex + chunk) % cap
                }
            }
            s.count += remaining
            s.written += n
        }
    }

    /// Consumer side: everything buffered so far, oldest first.
    public func drain() -> [Float] {
        lock.withLock { s in
            guard s.count > 0 else { return [] }
            var out = [Float](repeating: 0, count: s.count)
            let first = min(s.count, capacity - s.readIndex)
            out.withUnsafeMutableBufferPointer { dst in
                s.storage.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress! + s.readIndex, count: first)
                    if s.count > first {
                        (dst.baseAddress! + first).update(from: src.baseAddress!, count: s.count - first)
                    }
                }
            }
            s.readIndex = (s.readIndex + s.count) % capacity
            s.count = 0
            return out
        }
    }

    /// Total samples ever written (including dropped ones). Used to tell whether
    /// a real-time callback is firing at all.
    public var totalWritten: Int { lock.withLock { $0.written } }

    /// Samples lost to overflow since the last call.
    public func takeDropped() -> Int {
        lock.withLock { s in
            defer { s.dropped = 0 }
            return s.dropped
        }
    }
}
