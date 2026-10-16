import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var app: String
    var kind: String  // "dictation" | "command"
    var raw: String
    var text: String
    var asrMs: Int
    var llmMs: Int

    var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
    var totalMs: Int { asrMs + llmMs }
}

/// Lifetime usage, derived from the whole history file once at launch and kept up to date.
struct UsageStats: Equatable {
    var dictations = 0
    var words = 0
    var wordsThisWeek = 0
    var wordsToday = 0
    /// Sum of end-to-end latencies, for the average.
    var latencyMs = 0
    /// Days (as start-of-day dates) with at least one dictation; for the streak.
    var activeDays: Set<Date> = []

    var averageLatencyMs: Int { dictations == 0 ? 0 : latencyMs / dictations }

    /// Consecutive days ending today (or yesterday, so a quiet morning doesn't break it).
    var streakDays: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if !activeDays.contains(day) {
            day = cal.date(byAdding: .day, value: -1, to: day)!
            guard activeDays.contains(day) else { return 0 }
        }
        var n = 0
        while activeDays.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    /// Roughly how long typing those words would have taken at 40 wpm, versus speaking at ~150 wpm.
    var minutesSaved: Int { max(0, words / 40 - words / 150) }

    mutating func add(_ entry: HistoryEntry, now: Date = Date()) {
        let cal = Calendar.current
        dictations += 1
        words += entry.wordCount
        latencyMs += entry.totalMs
        activeDays.insert(cal.startOfDay(for: entry.date))
        if cal.isDate(entry.date, equalTo: now, toGranularity: .weekOfYear) { wordsThisWeek += entry.wordCount }
        if cal.isDateInToday(entry.date) { wordsToday += entry.wordCount }
    }
}

/// Append-only JSONL log of everything dictated; the newest entries are kept in memory.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var recent: [HistoryEntry] = []
    @Published private(set) var stats = UsageStats()

    static var fileURL: URL { SettingsStore.directory.appendingPathComponent("history.jsonl") }
    private let keep = 200

    init() {
        guard let raw = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = raw.split(separator: "\n").compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
        var stats = UsageStats()
        for entry in all { stats.add(entry) }
        self.stats = stats
        recent = Array(all.suffix(keep).reversed())
    }

    func add(_ entry: HistoryEntry) {
        recent.insert(entry, at: 0)
        if recent.count > keep { recent.removeLast(recent.count - keep) }
        stats.add(entry)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: Self.fileURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: Self.fileURL)
        }
    }

    func clear() {
        recent = []
        stats = UsageStats()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }
}
