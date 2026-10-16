import AppKit
import ApplicationServices
import Darwin
import Foundation
import MynahCore

/// Phase 0 proof-of-concept tools, shown in a hidden Debug menu:
///   defaults write com.lukekerwin.mynah MynahDebugMeetings -bool YES
/// Logs which processes use audio, records Teams' output + the mic to WAV files,
/// samples CPU/memory/thermal state, and dumps Teams' accessibility tree.
@MainActor
final class MeetingProbe: ObservableObject {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "MynahDebugMeetings") }
    static let teamsPrefix = "com.microsoft.teams2"

    @Published private(set) var logging = false
    @Published private(set) var recording = false
    @Published private(set) var status = ""

    var enginePID: () -> pid_t? = { nil }

    private let monitor = AudioActivityMonitor()
    private var lastSnapshot: [AudioProcess] = []
    private var tap: AnyObject?  // ProcessTap (macOS 14.2+)
    private var othersWriter: TrackWriter?
    private var mic: MeetingMic?
    private var youWriter: TrackWriter?
    private var statsTimer: Timer?
    private var cpuBaseline: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
    private var folder: URL?
    private var teamsOutputSince: Date?
    private var silentWarned = false
    private var tapEverHeard = false

    static let logURL: URL = EngineClient.logFile.deletingLastPathComponent().appendingPathComponent("meetings.log")

    // MARK: process logging

    func toggleLogging() {
        if logging {
            monitor.stop()
            logging = false
            write("process logging stopped")
            return
        }
        monitor.onChange = { [weak self] in self?.processesChanged() }
        monitor.start()
        logging = true
        lastSnapshot = []
        write("process logging started")
        processesChanged()
    }

    private func processesChanged() {
        let now = CoreAudioProcesses.snapshot()
        let before = Dictionary(lastSnapshot.map { ($0.objectID, $0) }, uniquingKeysWith: { a, _ in a })
        for p in now where before[p.objectID] != p {
            write(String(format: "proc %-6d %-45@ in=%d out=%d", p.pid, p.bundleID as NSString,
                         p.runningInput ? 1 : 0, p.runningOutput ? 1 : 0))
        }
        let nowIDs = Set(now.map(\.objectID))
        for p in lastSnapshot where !nowIDs.contains(p.objectID) {
            write(String(format: "gone %-6d %@", p.pid, p.bundleID as NSString))
        }
        lastSnapshot = now
        if recording, #available(macOS 14.2, *), let tap = tap as? ProcessTap {
            let teams = now.filter { $0.bundleID.hasPrefix(Self.teamsPrefix) }.map(\.objectID)
            if !teams.isEmpty { tap.update(target: .processes(teams)) }
        }
    }

    // MARK: recording

    func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard #available(macOS 14.2, *) else {
            status = "Needs macOS 14.2+"
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/mynah-probe-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folder = dir

        let snapshot = CoreAudioProcesses.snapshot()
        let teams = snapshot.filter { $0.bundleID.hasPrefix(Self.teamsPrefix) }
        let target: ProcessTap.Target
        if teams.isEmpty {
            // No Teams running: capture everything except Mynah, so the probe can be
            // tested with any audio (e.g. a video in a browser).
            target = .everythingExcept(CoreAudioProcesses.ownProcessObject().map { [$0] } ?? [])
            write("record: no Teams processes; tapping all system audio except Mynah")
        } else {
            target = .processes(teams.map(\.objectID))
            write("record: tapping \(teams.map { "\($0.pid) \($0.bundleID)" }.joined(separator: ", "))")
        }
        status = "Starting…"
        recording = true
        teamsOutputSince = nil
        silentWarned = false
        tapEverHeard = false

        let othersRing = RingBuffer(capacity: 48_000 * 10)
        let youRing = RingBuffer(capacity: 48_000 * 10)
        Task.detached(priority: .userInitiated) {
            do {
                let tap = ProcessTap(target: target, ring: othersRing)
                tap.onRebuild = { reason in Task { @MainActor in self.write("tap rebuilt: \(reason)") } }
                try tap.start()  // blocks ≤ 2 s while checking for callbacks
                let others = try TrackWriter(url: dir.appendingPathComponent("others.wav"), sourceRate: tap.sampleRate,
                                             ring: othersRing)
                let mic = MeetingMic(ring: youRing)
                try mic.start()
                let you = try TrackWriter(url: dir.appendingPathComponent("you.wav"), sourceRate: mic.sampleRate, ring: youRing)
                others.start()
                you.start()
                await MainActor.run {
                    self.tap = tap
                    self.othersWriter = others
                    self.mic = mic
                    self.youWriter = you
                    self.write("record: started (tap \(tap.mode.rawValue) \(Int(tap.sampleRate)) Hz, mic \(Int(mic.sampleRate)) Hz) → \(dir.path)")
                    self.status = "Recording → \(dir.lastPathComponent)"
                    self.startStats()
                }
            } catch {
                await MainActor.run {
                    self.write("record: FAILED \(error.localizedDescription)")
                    self.status = "Failed: \(error.localizedDescription)"
                    self.recording = false
                }
            }
        }
    }

    private func stopRecording() {
        statsTimer?.invalidate()
        statsTimer = nil
        if #available(macOS 14.2, *) { (tap as? ProcessTap)?.stop() }
        tap = nil
        mic?.stop()
        mic = nil
        othersWriter?.close()
        youWriter?.close()
        let secs = Double(othersWriter?.samplesWritten ?? 0) / 16_000
        write(String(format: "record: stopped, %.0f s captured", secs))
        othersWriter = nil
        youWriter = nil
        recording = false
        status = "Saved to \(folder?.lastPathComponent ?? "?")"
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    // MARK: stats

    private func startStats() {
        cpuBaseline = [:]
        _ = sampleCPU()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logStats() }
        }
    }

    private func logStats() {
        let cpu = sampleCPU()
        let thermal = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
        let o = othersWriter?.takeStats() ?? .init()
        let y = youWriter?.takeStats() ?? .init()
        let own = ProcessInfo.processInfo.processIdentifier
        let engine = enginePID()
        func db(_ peak: Float) -> String { peak > 0 ? String(format: "%.0f dBFS", 20 * log10(peak)) : "silent" }
        write(String(format: "stats thermal=%@ cpu mynah=%.1f%% engine=%@ mem mynah=%.0f MB | others %.0fs peak %@ drop %d | you %.0fs peak %@ drop %d",
                     thermal, cpu[own] ?? 0, engine.flatMap { cpu[$0] }.map { String(format: "%.1f%%", $0) } ?? "-",
                     Double(footprint(own)) / 1e6,
                     Double(o.samplesWritten) / 16_000, db(o.peak), o.dropped,
                     Double(y.samplesWritten) / 16_000, db(y.peak), y.dropped))

        // Silent-tap check. A denied permission yields exact digital zeros; a real
        // call never does (even quiet stretches carry a little noise), and Teams keeps
        // its output open through silence, so "quiet for a while" proves nothing.
        if o.peak > 0 { tapEverHeard = true }
        let teamsPlaying = CoreAudioProcesses.snapshot().contains { $0.bundleID.hasPrefix(Self.teamsPrefix) && $0.runningOutput }
        if teamsPlaying {
            teamsOutputSince = teamsOutputSince ?? Date()
            if !tapEverHeard, Date().timeIntervalSince(teamsOutputSince!) >= 60, !silentWarned {
                silentWarned = true
                write("TAP SILENT — Teams has been playing for 60 s and the tap has produced only zeros (permission?)")
                status = "Tap silent — check System Audio Recording permission"
            }
        } else {
            teamsOutputSince = nil
        }
    }

    /// CPU % of one core since the previous sample, per pid (Mynah + engine).
    private func sampleCPU() -> [pid_t: Double] {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        var out: [pid_t: Double] = [:]
        let now = mach_absolute_time()
        for pid in [ProcessInfo.processInfo.processIdentifier, enginePID()].compactMap({ $0 }) {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            guard ok else { continue }
            let cpu = usage.ri_user_time + usage.ri_system_time  // mach time units on Apple silicon
            if let base = cpuBaseline[pid], now > base.at {
                out[pid] = Double(cpu - base.cpu) / Double(now - base.at) * 100
            }
            cpuBaseline[pid] = (cpu, now)
        }
        return out
    }

    private func footprint(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
        }
        return ok ? usage.ri_phys_footprint : 0
    }

    // MARK: accessibility dump

    func dumpTeamsAccessibility() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix(Self.teamsPrefix) == true }
        guard !apps.isEmpty else {
            status = "Teams isn't running"
            return
        }
        guard Permissions.accessibilityGranted else {
            status = "Needs Accessibility permission"
            return
        }
        status = "Dumping Teams accessibility tree…"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/mynah-probe-ax-\(stamp).txt")
        let targets = apps.map { ($0.processIdentifier, $0.bundleIdentifier ?? "?", $0.localizedName ?? "?") }
        Task.detached(priority: .utility) {
            var lines: [String] = []
            for (pid, bundle, name) in targets {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                lines.append("=== \(name) pid \(pid) \(bundle)")
                var budget = 30_000
                for window in AXDump.children(app, kAXWindowsAttribute) {
                    AXDump.walk(window, depth: 0, budget: &budget, into: &lines)
                }
            }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            let count = lines.count
            await MainActor.run {
                self.status = "Wrote \(url.lastPathComponent) (\(count) lines)"
                self.write("ax dump: \(url.path) (\(count) lines)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    // MARK: log

    func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = Self.logURL
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}

enum AXDump {
    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func children(_ e: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
        (attr(e, name) as? [AXUIElement]) ?? []
    }

    static func walk(_ e: AXUIElement, depth: Int, budget: inout Int, into lines: inout [String]) {
        guard depth <= 25, budget > 0 else { return }
        budget -= 1
        func s(_ name: String) -> String? {
            guard let v = attr(e, name) as? String, !v.isEmpty else { return nil }
            return v.count > 100 ? String(v.prefix(100)) + "…" : v
        }
        var parts = [s(kAXRoleAttribute) ?? "?"]
        if let v = s(kAXSubroleAttribute) { parts.append("sub=\(v)") }
        if let v = s(kAXTitleAttribute) { parts.append("title=\"\(v)\"") }
        if let v = s(kAXDescriptionAttribute) { parts.append("desc=\"\(v)\"") }
        if let v = s(kAXIdentifierAttribute) { parts.append("id=\"\(v)\"") }
        if let v = s(kAXValueAttribute) { parts.append("value=\"\(v)\"") }
        if let v = s(kAXHelpAttribute) { parts.append("help=\"\(v)\"") }
        if let v = attr(e, kAXValueAttribute) as? NSNumber { parts.append("value=\(v)") }
        lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
        for child in children(e) {
            walk(child, depth: depth + 1, budget: &budget, into: &lines)
        }
    }
}
