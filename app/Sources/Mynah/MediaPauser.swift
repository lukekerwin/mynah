import Foundation

/// Pauses whatever is playing (Music, Spotify, a YouTube tab…) while you dictate and
/// resumes it afterwards, but only if it was playing and Mynah paused it.
///
/// Uses the private MediaRemote framework, the same "Now Playing" the media keys
/// drive. Since macOS 15.4 it ignores reads from apps without Apple's entitlement but
/// still accepts commands, so "is anything playing?" is asked through osascript (an
/// Apple-signed binary that's still allowed, ~30 ms) and pause/play are sent directly.
/// Pause and play are explicit commands, not a toggle, so a wrong guess can't start
/// something that was stopped.
@MainActor
final class MediaPauser {
    /// Bumped by every pause/resume so a slow "is it playing?" answer that arrives after
    /// the dictation already ended doesn't pause anything.
    private var generation = 0
    private var pausedByUs = false

    func pause() {
        generation += 1
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let playing = Self.isPlaying()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard playing, token == self.generation, !self.pausedByUs else { return }
                    if Self.send(.pause) { self.pausedByUs = true }
                }
            }
        }
    }

    func resume() {
        generation += 1
        guard pausedByUs else { return }
        pausedByUs = false
        _ = Self.send(.play)
    }

    // MARK: MediaRemote

    private enum Command: UInt32 {
        case play = 0, pause = 1
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            NSLog("Mynah: MediaRemote unavailable; media won't pause while dictating")
            return nil
        }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }

    nonisolated private static let isPlayingScript = """
        ObjC.import("Foundation");
        $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
        $.NSClassFromString("MRNowPlayingRequest").localIsPlaying
        """

    /// Blocking; call off the main thread. False on any failure or after a second.
    nonisolated private static func isPlaying() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", isPlayingScript]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return false }
        guard done.wait(timeout: .now() + 1) == .success else {
            process.terminate()
            return false
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}
