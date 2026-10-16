import AppKit
import CoreAudio
import Foundation

/// A process that has an audio connection, as Core Audio reports it.
struct AudioProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let runningInput: Bool
    let runningOutput: Bool

    var appName: String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundleID
    }
}

/// Reads Core Audio's process objects (macOS 14+). None of this needs a permission.
/// Uses the C API: the Swift wrappers for these properties are macOS 15+.
enum CoreAudioProcesses {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func snapshot() -> [AudioProcess] {
        objectList(system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = uint32(id, kAudioProcessPropertyPID) else { return nil }
            return AudioProcess(objectID: id, pid: pid_t(bitPattern: pid),
                                bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                                runningInput: uint32(id, kAudioProcessPropertyIsRunningInput) == 1,
                                runningOutput: uint32(id, kAudioProcessPropertyIsRunningOutput) == 1)
        }
    }

    static func defaultDevice(output: Bool) -> AudioObjectID? {
        let id = uint32(system, output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : AudioObjectID($0) }
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    /// Our own process object, so global taps can exclude Mynah's sounds.
    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Calls `onChange` (main queue, coalesced) when anything that affects "who is
/// using audio" may have changed. Listeners on IsRunningInput/IsRunningOutput
/// don't fire, so this listens to the process list, each process's IsRunning,
/// the default input's IsRunningSomewhere and default-device changes; callers
/// re-read `CoreAudioProcesses.snapshot()`.
final class AudioActivityMonitor {
    var onChange: (() -> Void)?

    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var registrations: [Registration] = []
    private var pending = false
    private let queue = DispatchQueue.main

    func start() {
        stop()
        listen(CoreAudioProcesses.system, kAudioHardwarePropertyProcessObjectList, rebuild: true)
        listen(CoreAudioProcesses.system, kAudioHardwarePropertyDefaultInputDevice, rebuild: true)
        listen(CoreAudioProcesses.system, kAudioHardwarePropertyDefaultOutputDevice, rebuild: false)
        if let input = CoreAudioProcesses.defaultDevice(output: false) {
            listen(input, kAudioDevicePropertyDeviceIsRunningSomewhere, rebuild: false)
        }
        for process in CoreAudioProcesses.objectList(CoreAudioProcesses.system, kAudioHardwarePropertyProcessObjectList) {
            listen(process, kAudioProcessPropertyIsRunning, rebuild: false)
            listen(process, kAudioProcessPropertyIsRunningInput, rebuild: false)
            listen(process, kAudioProcessPropertyIsRunningOutput, rebuild: false)
        }
    }

    func stop() {
        for var r in registrations {
            AudioObjectRemovePropertyListenerBlock(r.object, &r.address, queue, r.block)
        }
        registrations.removeAll()
    }

    deinit { stop() }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, rebuild: Bool) {
        var addr = CoreAudioProcesses.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if rebuild { self.start() }  // new processes/devices need their own listeners
            self.changed()
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr {
            registrations.append(Registration(object: object, address: addr, block: block))
        }
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pending = false
            self?.onChange?()
        }
    }
}
