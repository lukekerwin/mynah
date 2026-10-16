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
}

/// Append-only JSONL log of everything dictated; the newest entries are kept in memory.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var recent: [HistoryEntry] = []

    static var fileURL: URL { SettingsStore.directory.appendingPathComponent("history.jsonl") }
    private let keep = 50

    init() {
        guard let raw = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        recent = raw.split(separator: "\n").suffix(keep).reversed().compactMap {
            try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
        }
    }

    func add(_ entry: HistoryEntry) {
        recent.insert(entry, at: 0)
        if recent.count > keep { recent.removeLast(recent.count - keep) }
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
}
