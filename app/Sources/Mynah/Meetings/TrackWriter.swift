import Accelerate
import AVFoundation
import Foundation
import MynahCore
import os

/// Drains a RingBuffer every 250 ms on a utility queue, resamples to 16 kHz mono
/// and appends 16-bit PCM to a WAV file. Header sizes are refreshed every 5 s and
/// on close, so a crash leaves a file that `WAVHeader.repair` fully recovers.
///
/// Gaps (a tap rebuild, a device switch) are filled with silence so the file
/// stays aligned to wall-clock time — both tracks of a meeting share a timeline.
final class TrackWriter {
    struct Stats {
        var samplesWritten = 0  // 16 kHz frames on disk
        var peak: Float = 0  // since the last takeStats()
        var dropped = 0  // source samples lost to ring overflow
    }

    let url: URL
    private let ring: RingBuffer
    private let queue = DispatchQueue(label: "com.lukekerwin.mynah.track-writer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let handle: FileHandle
    private var converter: AVAudioConverter
    private var source: AVAudioFormat
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let stats = OSAllocatedUnfairLock(initialState: Stats())
    private var dataBytes: UInt32 = 0
    private var lastHeaderWrite = Date()
    private var startedAt: Date?
    private var written = 0  // 16 kHz frames, writer-queue copy of stats.samplesWritten

    init(url: URL, sourceRate: Double, ring: RingBuffer) throws {
        self.url = url
        self.ring = ring
        source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw CocoaError(.featureUnsupported)
        }
        self.converter = converter
        FileManager.default.createFile(atPath: url.path, contents: WAVHeader.make(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func start() {
        queue.sync { startedAt = Date() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Final drain, header fix, close. Safe to call twice.
    func close() {
        timer?.cancel()
        timer = nil
        queue.sync {
            drain()
            writeHeader()
            try? handle.close()
        }
    }

    /// 16 kHz frames written so far, plus peak/dropped since the last call.
    func takeStats() -> Stats {
        stats.withLock { s in
            defer {
                s.peak = 0
                s.dropped = 0
            }
            return s
        }
    }

    var samplesWritten: Int { stats.withLock { $0.samplesWritten } }

    /// The source's sample rate changed (new input device, rebuilt tap).
    func updateSourceRate(_ rate: Double) {
        queue.async { [self] in
            guard rate > 0, rate != source.sampleRate else { return }
            drain()
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            if let c = AVAudioConverter(from: format, to: target) {
                source = format
                converter = c
            }
        }
    }

    private func drain() {
        let samples = ring.drain()
        let dropped = ring.takeDropped()
        guard !samples.isEmpty else {
            if dropped > 0 { stats.withLock { $0.dropped += dropped } }
            padToWallClock(pending: 0)
            return
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / source.sampleRate + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }

        let n = Int(output.frameLength)
        padToWallClock(pending: n)
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(n))
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            pcm[i] = Int16(max(-1, min(1, channel[i])) * 32767).littleEndian
        }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        append(data, frames: n)
        let chunkPeak = peak
        stats.withLock {
            $0.peak = max($0.peak, chunkPeak)
            $0.dropped += dropped
        }
        if Date().timeIntervalSince(lastHeaderWrite) >= 5 { writeHeader() }
    }

    private func append(_ data: Data, frames: Int) {
        handle.write(data)
        dataBytes &+= UInt32(data.count)
        written += frames
        let total = written
        stats.withLock { $0.samplesWritten = total }
    }

    /// If the file has fallen more than 0.5 s behind real time (the source stopped
    /// delivering), write silence so later audio lands at the right time.
    private func padToWallClock(pending: Int) {
        guard let startedAt else { return }
        let expected = Int(Date().timeIntervalSince(startedAt) * target.sampleRate)
        let missing = expected - (written + pending)
        guard missing > Int(target.sampleRate / 2) else { return }
        // Keep a little slack for audio still in flight from the device.
        let frames = missing - Int(target.sampleRate / 10)
        append(Data(count: frames * 2), frames: frames)
    }

    private func writeHeader() {
        guard let end = try? handle.offset() else { return }
        try? handle.seek(toOffset: 0)
        handle.write(WAVHeader.make(dataBytes: dataBytes))
        try? handle.seek(toOffset: end)
        lastHeaderWrite = Date()
    }
}

/// The user's side of a meeting: its own AVAudioEngine on the default input
/// (separate from dictation's recorder; never voice-processing, which would duck
/// the call). While gated (dictating, paused, muted) it writes silence instead,
/// so both tracks keep the same timeline.
final class MeetingMic {
    struct Gate: Equatable {
        var dictating = false
        var paused = false
        var teamsMuted = false

        var closed: Bool { dictating || paused || teamsMuted }
    }

    let ring: RingBuffer
    let gate = OSAllocatedUnfairLock(initialState: Gate())
    private(set) var sampleRate: Double = 48_000
    /// Called (main queue) when the input device's sample rate changes.
    var onRateChange: ((Double) -> Void)?
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?

    init(ring: RingBuffer) {
        self.ring = ring
    }

    deinit { stop() }

    func start() throws {
        try install()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // Input device changed (e.g. headphones): restart on the new device.
            guard let self else { return }
            let old = self.sampleRate
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.install()
            if self.sampleRate != old { self.onRateChange?(self.sampleRate) }
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func install() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        sampleRate = format.sampleRate
        let ring = self.ring
        let gate = self.gate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let closed = gate.withLock { $0.closed }
            ring.write(channel, count: Int(buffer.frameLength), zero: closed)
        }
        engine.prepare()
        try engine.start()
    }
}
