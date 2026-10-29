import AppKit
import CoreAudio
import Foundation

private let log = AppLogger(category: "audio")

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
///
/// When processes come and go, only their listeners are added or removed, at most
/// once per coalescing window: re-registering every listener on each notification
/// pinned the main thread inside Core Audio and froze Mynah.
final class AudioActivityMonitor {
    var onChange: (() -> Void)?

    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var systemRegistrations: [Registration] = []
    private var processRegistrations: [AudioObjectID: [Registration]] = [:]
    private var inputRegistration: Registration?
    private var inputDevice: AudioObjectID?
    private var pending = false
    private var needsSync = false
    private let queue = DispatchQueue.main

    func start() {
        stop()
        for (selector, sync) in [(kAudioHardwarePropertyProcessObjectList, true),
                                 (kAudioHardwarePropertyDefaultInputDevice, true),
                                 (kAudioHardwarePropertyDefaultOutputDevice, false)] {
            if let r = listen(CoreAudioProcesses.system, selector, sync: sync) { systemRegistrations.append(r) }
        }
        sync()
    }

    func stop() {
        let all = systemRegistrations + processRegistrations.values.flatMap { $0 } + [inputRegistration].compactMap { $0 }
        all.forEach(remove)
        systemRegistrations.removeAll()
        processRegistrations.removeAll()
        inputRegistration = nil
        inputDevice = nil
        pending = false
        needsSync = false
    }

    deinit { stop() }

    /// Brings the per-process and default-input listeners in line with what exists now.
    private func sync() {
        let initial = processRegistrations.isEmpty
        let current = Set(CoreAudioProcesses.objectList(CoreAudioProcesses.system, kAudioHardwarePropertyProcessObjectList))
        let gone = processRegistrations.keys.filter { !current.contains($0) }
        for id in gone { processRegistrations.removeValue(forKey: id)?.forEach(remove) }
        let added = current.filter { processRegistrations[$0] == nil }
        for id in added {
            processRegistrations[id] = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningInput,
                                        kAudioProcessPropertyIsRunningOutput].compactMap { listen(id, $0, sync: false) }
        }

        let input = CoreAudioProcesses.defaultDevice(output: false)
        if input != inputDevice {
            inputRegistration.map(remove)
            inputRegistration = input.flatMap { listen($0, kAudioDevicePropertyDeviceIsRunningSomewhere, sync: false) }
            inputDevice = input
        }
        if !initial, !gone.isEmpty || !added.isEmpty {
            log.info("audio processes +\(added.count) -\(gone.count), watching \(processRegistrations.count)")
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, sync: Bool) -> Registration? {
        var addr = CoreAudioProcesses.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if sync { self.needsSync = true }  // new processes/devices need their own listeners
            self.changed()
        }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr else { return nil }
        return Registration(object: object, address: addr, block: block)
    }

    private func remove(_ registration: Registration) {
        var r = registration
        AudioObjectRemovePropertyListenerBlock(r.object, &r.address, queue, r.block)
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.pending else { return }
            self.pending = false
            if self.needsSync {
                self.needsSync = false
                self.sync()
            }
            self.onChange?()
        }
    }
}
