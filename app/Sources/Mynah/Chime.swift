import AVFoundation

/// The start/stop sounds, played off the main thread. Starting playback waits for the
/// output device to start, which can take 20 s or more for a monitor's speakers just
/// after the Mac wakes; on the main thread that froze Mynah. If a sound is still stuck
/// starting, later ones are skipped rather than queued.
enum Chime {
    private static let queue = DispatchQueue(label: "com.lukekerwin.mynah.chime", qos: .userInitiated)
    private static let lock = NSLock()
    private static var busy = false
    private static var players: [String: AVAudioPlayer] = [:]  // only touched on `queue`

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
            guard let player = player(name) else { return }
            player.volume = volume
            player.currentTime = 0
            player.play()
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
