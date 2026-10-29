import CoreAudio
import Foundation
import MynahCore

private let log = AppLogger(category: "tap")

enum TapError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noAudio

    var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status): return "\(step) failed (\(status))"
        case .noAudio: return "The system audio tap produced no callbacks"
        }
    }
}

/// Captures what some processes play (or everything but some processes), as mono
/// Float32 at the tap's native rate, into a RingBuffer. Uses a Core Audio process
/// tap inside a private aggregate device (macOS 14.2+).
///
/// The first time an aggregate containing a tap starts, macOS asks for "System
/// Audio Recording" permission. If it's denied, everything still "works" but the
/// buffers are silent — callers detect that from the audio itself.
@available(macOS 14.2, *)
final class ProcessTap {
    enum Target: Equatable {
        case processes([AudioObjectID])
        case everythingExcept([AudioObjectID])
    }

    /// `.tapOnly` has no hardware sub-device, so it's unaffected by output device
    /// changes; `.withOutputDevice` clocks from the default output (AudioCap's way).
    enum Mode: String { case tapOnly, withOutputDevice }

    let ring: RingBuffer
    private(set) var sampleRate: Double = 48_000
    private(set) var mode: Mode = .tapOnly
    var onRebuild: ((String) -> Void)?

    private var target: Target
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.lukekerwin.mynah.tap-io", qos: .userInteractive)
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(target: Target, ring: RingBuffer) {
        self.target = target
        self.ring = ring
    }

    deinit { stop() }

    /// Starts capture. Tries the tap-only aggregate first and falls back to one
    /// clocked by the output device if no callbacks arrive within 2 s.
    func start() throws {
        try build(mode: .tapOnly)
        let before = ring.totalWritten
        Thread.sleep(forTimeInterval: 2)
        if ring.totalWritten == before {
            log.notice("tap-only aggregate produced no callbacks; retrying with output device")
            teardown()
            try build(mode: .withOutputDevice)
        }
        running = true
        watchOutputDevice()
    }

    func stop() {
        running = false
        if let outputListener {
            var addr = CoreAudioProcesses.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(CoreAudioProcesses.system, &addr, .main, outputListener)
            self.outputListener = nil
        }
        teardown()
    }

    /// Change which processes are captured (e.g. Teams started a helper mid-call).
    func update(target newTarget: Target) {
        guard newTarget != target else { return }
        target = newTarget
        guard running else { return }
        rebuild(reason: "process list changed")
    }

    // MARK: setup / teardown

    private func makeDescription() -> CATapDescription {
        let desc: CATapDescription
        switch target {
        case let .processes(ids): desc = CATapDescription(monoMixdownOfProcesses: ids)
        case let .everythingExcept(ids): desc = CATapDescription(monoGlobalTapButExcludeProcesses: ids)
        }
        desc.uuid = UUID()
        desc.name = "Mynah meeting tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted  // the user keeps hearing the call
        return desc
    }

    private func build(mode: Mode) throws {
        self.mode = mode
        let desc = makeDescription()
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = CoreAudioProcesses.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format), "read tap format")
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mynah Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        if mode == .withOutputDevice {
            guard let output = CoreAudioProcesses.defaultDevice(output: true),
                  let uid = CoreAudioProcesses.deviceUID(output), !uid.contains("MSTeamsAudioDevice") else {
                teardown()
                throw TapError.coreAudio("find output device", -1)
            }
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")
            let ring = self.ring
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
                // Real-time thread: copy out and nothing else.
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, let data = first.mData else { return }
                let channels = max(1, Int(first.mNumberChannels))
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
                // Mono mixdown gives one channel; if not, take the first (interleaved) channel only.
                if channels == 1 {
                    ring.write(data.assumingMemoryBound(to: Float.self), count: frames)
                } else {
                    let p = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { ring.write(p + i * channels, count: 1) }
                }
            }, "create IO proc")
            try check(AudioDeviceStart(aggregateID, procID), "start aggregate")
        } catch {
            teardown()
            throw error
        }
        log.notice("tap started (\(mode.rawValue, privacy: .public), \(self.sampleRate) Hz)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            procID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Full rebuild: restarting only the IO proc or aggregate after a device change
    /// is reported to leave the tap silent.
    private func rebuild(reason: String) {
        teardown()
        do {
            try build(mode: mode)
            onRebuild?(reason)
        } catch {
            log.error("tap rebuild failed: \(error.localizedDescription, privacy: .public)")
            onRebuild?("\(reason) — rebuild FAILED: \(error.localizedDescription)")
        }
    }

    private func watchOutputDevice() {
        var addr = CoreAudioProcesses.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.rebuild(reason: "default output device changed")
        }
        if AudioObjectAddPropertyListenerBlock(CoreAudioProcesses.system, &addr, .main, block) == noErr {
            outputListener = block
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError.coreAudio(step, status) }
    }
}
