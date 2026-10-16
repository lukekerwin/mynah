import Accelerate
import AudioToolbox
import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone available"
        case let .coreAudio(step, status): return "Microphone error (\(step): \(status))"
        }
    }
}

/// Captures from one specific input device and resamples to 16 kHz mono Float32.
///
/// Talks to a HAL audio unit directly rather than `AVAudioEngine`: on recent macOS the
/// engine's input node rebuilds itself around the *system default* input whenever it
/// reconfigures, silently undoing any device choice. With a Bluetooth headset as the
/// default, that both breaks recording and drops the headset to call quality.
/// The unit is created per recording and disposed afterwards so nothing holds the mic.
final class AudioRecorder {
    /// RMS level of each captured chunk, delivered on the main queue.
    var onLevel: ((Float) -> Void)?

    private var unit: AudioUnit?
    private var buffer: AVAudioPCMBuffer?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private(set) var isRecording = false

    /// - Parameter deviceUID: Core Audio UID of the mic to use (see `AudioDevices.resolve`).
    func start(deviceUID: String) throws {
        guard !isRecording else { return }
        guard var device = AudioDevices.resolve(uid: deviceUID) else { throw RecorderError.noInputDevice }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw RecorderError.noInputDevice }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "open")
        guard let unit = created else { throw RecorderError.noInputDevice }

        do {
            var on: UInt32 = 1, off: UInt32 = 0
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, "enable input")
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, "disable output")
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, "select device")

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                           &hardware, &size), "read format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else { throw RecorderError.noInputDevice }

            // Take the first channel at the device's own rate; AVAudioConverter handles 16 kHz.
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                       channels: 1, interleaved: false)!
            var client = format.streamDescription.pointee
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, "set format")

            var maxFrames: UInt32 = 4096
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                 &maxFrames, &size)
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, 4096))
            converter = AVAudioConverter(from: format, to: target)

            var callback = AURenderCallbackStruct(inputProc: inputCallback,
                                                  inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, "callback")

            self.unit = unit
            try check(AudioUnitInitialize(unit), "initialize")
            try check(AudioOutputUnitStart(unit), "start")
        } catch {
            teardown(unit)
            throw error
        }
        isRecording = true
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        guard isRecording, let unit else { return [] }
        teardown(unit)
        isRecording = false
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func teardown(_ unit: AudioUnit) {
        AudioOutputUnitStop(unit)  // synchronous: no callbacks run after this returns
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        buffer = nil
        converter = nil
    }

    /// Runs on the HAL's I/O thread.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, let buffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, bus, frames, buffer.mutableAudioBufferList)
        if status == noErr { process(buffer) }
        return status
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

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw RecorderError.coreAudio(step, status) }
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: inout T, _ step: String) throws {
        let status = withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<T>.size))
        }
        try check(status, step)
    }
}

private let inputCallback: AURenderCallback = { refCon, flags, time, bus, frames, _ in
    Unmanaged<AudioRecorder>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
}
