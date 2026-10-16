import Accelerate
import AudioToolbox
import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice

    var errorDescription: String? { "No microphone available" }
}

/// Captures from the chosen input device and resamples to 16 kHz mono Float32.
///
/// A fresh engine is built per recording and released afterwards: an idle `AVAudioEngine`
/// keeps its input unit attached to the device, which holds Bluetooth headsets in
/// low-quality hands-free mode even between dictations.
final class AudioRecorder {
    /// RMS level of each captured chunk, delivered on the main queue.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private(set) var isRecording = false

    /// - Parameter deviceUID: Core Audio UID of the mic to use (see `AudioDevices.resolve`).
    func start(deviceUID: String) throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var device = AudioDevices.resolve(uid: deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        converter = AVAudioConverter(from: format, to: target)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        guard isRecording, let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        isRecording = false
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }

        let count = Int(out.frameLength)
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
    }
}
