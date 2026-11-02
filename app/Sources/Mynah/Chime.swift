import AVFoundation

/// The start/stop sounds, played off the main thread. Starting playback waits for the
/// output device to start, which can take 20 s or more for a monitor's speakers just
/// after the Mac wakes; on the main thread that froze Mynah. If a sound is still stuck
/// starting, later ones are skipped rather than queued.
///
/// Some devices are slow every time (a Dell monitor took 10 s per sound), and while a
/// sound is starting Core Audio holds a lock the microphone needs, so the next
/// dictation stalls too. A device that takes over a second to start is left silent
/// until Mynah relaunches.
enum Chime {
    private static let queue = DispatchQueue(label: "com.lukekerwin.mynah.chime", qos: .userInitiated)
    private static let lock = NSLock()
    private static var busy = false
    private static let log = AppLogger(category: "chime")
    private static let slowStart: TimeInterval = 1
    // Only touched on `queue`.
    private static var players: [String: AVAudioPlayer] = [:]
    private static var slowDevices: Set<String> = []

    static func play(_ name: String, volume: Float = 0.25) {
        lock.lock()
        let skip = busy
        busy = true
        lock.unlock()
        guard !skip else { return }

        queue.async {
            defer {
                lock.lock()
                busy = false
                lock.unlock()
            }
            let device = CoreAudioProcesses.defaultDevice(output: true).flatMap(CoreAudioProcesses.deviceUID)
            if let device, slowDevices.contains(device) { return }
            guard let player = player(name) else { return }
            player.volume = volume
            player.currentTime = 0
            let started = Date()
            player.play()
            let took = Date().timeIntervalSince(started)
            if let device, took > slowStart {
                slowDevices.insert(device)
                log.notice("output \(device) took \(took, format: .fixed(precision: 1)) s to start; no more sounds on it")
            }
        }
    }

    private static func player(_ name: String) -> AVAudioPlayer? {
        if let player = players[name] { return player }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
