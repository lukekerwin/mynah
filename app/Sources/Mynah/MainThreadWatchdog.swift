import Foundation

/// Notices when the main thread stops responding and saves a `sample` of Mynah
/// (hang-*.txt, next to app.log), so a freeze can be diagnosed after the fact.
/// Measured in uptime, which stops while the Mac sleeps, so sleep isn't a freeze.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private static let threshold: UInt64 = 5_000_000_000
    private static let keepSamples = 5

    private let lock = NSLock()
    private var lastResponse = DispatchTime.now().uptimeNanoseconds
    private var longestGap: UInt64 = 0  // between two main-thread replies, since the last report
    private var started = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [self] in run() }
        thread.name = "main-thread-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        var stalled = false
        while true {
            Thread.sleep(forTimeInterval: 1)
            DispatchQueue.main.async { [self] in
                lock.lock()
                let now = DispatchTime.now().uptimeNanoseconds
                longestGap = max(longestGap, now - lastResponse)
                lastResponse = now
                lock.unlock()
            }
            lock.lock()
            let last = lastResponse
            lock.unlock()
            let now = DispatchTime.now().uptimeNanoseconds
            let silent = now > last ? now - last : 0

            if !stalled, silent > Self.threshold {
                stalled = true
                AppLog.write("watchdog", "error", "main thread unresponsive for \(silent / 1_000_000_000) s; sampling")
                sample()
            } else if stalled, silent < 2_000_000_000 {
                stalled = false
                lock.lock()
                let gap = longestGap
                longestGap = 0
                lock.unlock()
                AppLog.write("watchdog", "notice", String(format: "main thread responsive again after %.0f s", Double(gap) / 1e9))
            }
        }
    }

    private func sample() {
        let dir = AppLog.fileURL.deletingLastPathComponent()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("hang-\(f.string(from: Date())).txt")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        proc.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-file", url.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            AppLog.write("watchdog", "notice", "saved \(url.lastPathComponent)")
        } catch {
            AppLog.write("watchdog", "error", "sample failed: \(error.localizedDescription)")
        }

        // Keep the newest few.
        let samples = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }
            .sorted()
        for name in samples.dropLast(Self.keepSamples) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
