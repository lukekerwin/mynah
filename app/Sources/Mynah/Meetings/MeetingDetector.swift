import Foundation

/// Watches Core Audio for a Teams call: it starts when any Teams process opens an
/// audio input, and ends once no Teams process has used input for `graceSeconds`
/// (so device switches and reconnects don't split a meeting). Matches the Teams
/// bundle prefix only — other processes (e.g. Siri's CoreSpeech) hold the mic
/// permanently.
@MainActor
final class MeetingDetector {
    nonisolated static let teamsPrefix = "com.microsoft.teams2"

    var onCallStarted: (() -> Void)?
    var onCallEnded: (() -> Void)?
    /// Called on every change with the current Teams processes (for the tap).
    var onTeamsProcessesChanged: (([AudioProcess]) -> Void)?
    var graceSeconds: TimeInterval = 30

    private(set) var inCall = false
    private(set) var teamsProcesses: [AudioProcess] = []
    private let monitor = AudioActivityMonitor()
    private var endTimer: Timer?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        monitor.onChange = { [weak self] in self?.refresh() }
        monitor.start()
        refresh()
    }

    func stop() {
        running = false
        monitor.stop()
        endTimer?.invalidate()
        endTimer = nil
        inCall = false
    }

    private func refresh() {
        guard running else { return }
        let teams = CoreAudioProcesses.snapshot().filter { $0.bundleID.hasPrefix(Self.teamsPrefix) }
        if teams != teamsProcesses {
            teamsProcesses = teams
            onTeamsProcessesChanged?(teams)
        }
        let usingMic = teams.contains { $0.runningInput }
        if usingMic {
            endTimer?.invalidate()
            endTimer = nil
            if !inCall {
                inCall = true
                onCallStarted?()
            }
        } else if inCall, endTimer == nil {
            endTimer = Timer.scheduledTimer(withTimeInterval: graceSeconds, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.inCall else { return }
                    self.endTimer = nil
                    self.inCall = false
                    self.onCallEnded?()
                }
            }
        }
    }
}
