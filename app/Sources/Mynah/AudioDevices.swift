import CoreAudio
import Foundation

/// A Core Audio device that can capture audio.
struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap(device)
    }

    static var builtInUID: String? { inputs().first(where: \.isBuiltIn)?.uid }

    /// The device to record from: the user's choice while it's connected, otherwise the
    /// built-in mic. Never follows the system default, which macOS switches to Bluetooth
    /// headsets on connect — recording from those drops playback to call quality.
    /// Macs without a built-in mic fall back to the system default.
    static func resolve(uid: String) -> AudioDeviceID? {
        let all = inputs()
        return (all.first { $0.uid == uid } ?? all.first(where: \.isBuiltIn))?.id ?? defaultInputID
    }

    private static var defaultInputID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func device(_ id: AudioDeviceID) -> InputDevice? {
        guard hasInputStreams(id),
              let uid: CFString = property(id, kAudioDevicePropertyDeviceUID),
              let name: CFString = property(id, kAudioObjectPropertyName),
              let transport: UInt32 = property(id, kAudioDevicePropertyTransportType) else { return nil }
        return InputDevice(id: id, uid: uid as String, name: name as String, transport: transport)
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func property<T>(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.move()
    }
}
