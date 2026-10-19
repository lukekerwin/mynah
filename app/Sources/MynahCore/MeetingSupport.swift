import Foundation

/// Meeting-capture settings (stored inside settings.json as "meetings").
public struct MeetingSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var consentAcknowledged = false
    /// false = ask before recording each Teams call.
    public var autoRecord = true
    public var audioRetention: AudioRetention = .days7
    /// "default" = the cleanup model; otherwise an engine LLM key (general-purpose only).
    public var summaryModel = "default"
    /// Optional, helps the summary attribute action items to "me".
    public var myName = ""
    /// ⌃⌥M toggles "Pause my mic" while recording.
    public var pauseMicShortcut = true
    /// Drop the mic while Teams shows you as muted (read through Accessibility).
    public var teamsMuteDetection = true
    /// Show the live transcript pill at the right edge of the screen while recording.
    public var liveTranscript = true
    /// Split "Others" into individual voices after each call, and name the ones it knows.
    public var recognizeSpeakers = true

    public init() {}

    /// Missing keys (older settings files) fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeetingSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        consentAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .consentAcknowledged) ?? d.consentAcknowledged
        autoRecord = try c.decodeIfPresent(Bool.self, forKey: .autoRecord) ?? d.autoRecord
        audioRetention = (try? c.decodeIfPresent(AudioRetention.self, forKey: .audioRetention)) ?? d.audioRetention
        summaryModel = try c.decodeIfPresent(String.self, forKey: .summaryModel) ?? d.summaryModel
        myName = try c.decodeIfPresent(String.self, forKey: .myName) ?? d.myName
        pauseMicShortcut = try c.decodeIfPresent(Bool.self, forKey: .pauseMicShortcut) ?? d.pauseMicShortcut
        teamsMuteDetection = try c.decodeIfPresent(Bool.self, forKey: .teamsMuteDetection) ?? d.teamsMuteDetection
        liveTranscript = try c.decodeIfPresent(Bool.self, forKey: .liveTranscript) ?? d.liveTranscript
        recognizeSpeakers = try c.decodeIfPresent(Bool.self, forKey: .recognizeSpeakers) ?? d.recognizeSpeakers
    }
}

/// The title a meeting gets before anything better is known, e.g. "Teams call – Oct 16, 3:05 PM".
/// The summary's generated title replaces it (but not a Teams meeting name or a user edit).
public enum MeetingTitle {
    public static func placeholder(app: String, date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d, h:mm a"
        return "\(app) call – \(df.string(from: date))"
    }

    public static func isPlaceholder(_ title: String) -> Bool {
        title.contains(" call – ") || title.hasPrefix("Imported – ")
    }
}

/// Parsing what Teams exposes through Accessibility (English UI; anything
/// unrecognized is reported as unknown).
public enum TeamsUI {
    /// The meeting window's title is "<meeting name> | Microsoft Teams".
    public static func meetingTitle(windowTitle: String) -> String? {
        let suffix = " | Microsoft Teams"
        guard windowTitle.hasSuffix(suffix) else { return nil }
        let name = String(windowTitle.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// From the call toolbar's mic button: "Unmute mic" while muted, "Mute mic" while
    /// live. Also takes the wordings other Teams builds use ("Unmute (⌘+Shift+M)",
    /// "Turn on microphone", "Mic is muted"), but not "Mute all" and the like.
    public static func isMuted(buttonDescriptions: [String]) -> Bool? {
        for d in buttonDescriptions {
            let l = d.lowercased().trimmingCharacters(in: .whitespaces)
            if l == "unmute" || ["unmute mic", "unmute (", "turn on mic", "turn mic on"].contains(where: l.hasPrefix) {
                return true
            }
            if l == "mute" || ["mute mic", "mute (", "turn off mic", "turn mic off"].contains(where: l.hasPrefix) {
                return false
            }
            if l.hasPrefix("mic"), l.contains(" muted"), !l.contains("unmuted") { return true }
        }
        return nil
    }
}

/// Reads part of a 16-bit mono WAV written by TrackWriter (44-byte header).
public enum WAVReader {
    /// Samples [from, from + count) as Float in -1...1; shorter if the file ends first.
    public static func read(url: URL, from: Int, count: Int) throws -> [Float] {
        guard count > 0 else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(WAVHeader.size + from * 2))
        let data = try handle.read(upToCount: count * 2) ?? Data()
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        return out
    }

    /// Whole 16-bit samples currently in the file.
    public static func sampleCount(url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return max(0, size - WAVHeader.size) / 2
    }
}

/// When the background summary job may run.
public enum SummaryEligibility {
    public struct Conditions: Equatable, Sendable {
        public var engineReady: Bool
        public var recording: Bool
        public var dictating: Bool
        /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
        public var thermalState: Int
        public var manual: Bool

        public init(engineReady: Bool, recording: Bool, dictating: Bool, thermalState: Int, manual: Bool = false) {
            self.engineReady = engineReady
            self.recording = recording
            self.dictating = dictating
            self.thermalState = thermalState
            self.manual = manual
        }
    }

    /// Automatic runs need an idle, cool Mac; "Summarize now" only needs no call in progress.
    public static func canStart(_ c: Conditions) -> Bool {
        guard c.engineReady, !c.recording else { return false }
        if c.manual { return true }
        return !c.dictating && c.thermalState <= 1
    }

    /// A running job is cancelled (and re-queued) when a call starts or the Mac gets hot.
    public static func shouldInterrupt(_ c: Conditions) -> Bool {
        c.recording || (!c.manual && c.thermalState >= 2)
    }
}
