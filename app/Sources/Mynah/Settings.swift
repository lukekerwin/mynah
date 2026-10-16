import AppKit
import Combine
import Foundation

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var text: String
}

enum HotkeyChoice: String, Codable, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightOption: return .option
        case .rightCommand: return .command
        }
    }
}

/// User settings, persisted as JSON in ~/Library/Application Support/Mynah/settings.json.
final class SettingsStore: ObservableObject {
    struct Data: Codable {
        var asrModel = "parakeet-v3"
        var llmModel = Data.defaultLLM
        var commandModel = Data.defaultCommandLLM
        var cleanupEnabled = true
        var vocabulary: [String] = []
        var snippets: [Snippet] = []
        var hotkey: HotkeyChoice = .fn
        var playSounds = true
        var restoreClipboard = true
        var onboarded = false

        /// Gemma 4 E4B (~5 GB) + Parakeet (~3.7 GB) is comfortable on 16 GB+ Macs.
        /// Smaller machines get the 0.6B cleanup model and no command mode.
        static var hasRoomForLargeModels: Bool { ProcessInfo.processInfo.physicalMemory >= 15 << 30 }
        static var defaultLLM: String { hasRoomForLargeModels ? "gemma-4-e4b" : "s1-mini" }
        static var defaultCommandLLM: String { hasRoomForLargeModels ? "gemma-4-e4b" : "none" }

        init() {}

        /// Missing keys (e.g. settings saved by an older version) fall back to defaults
        /// instead of failing the whole decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Data()
            asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? d.asrModel
            llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? d.llmModel
            commandModel = try c.decodeIfPresent(String.self, forKey: .commandModel) ?? d.commandModel
            cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? d.cleanupEnabled
            vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
            snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
            hotkey = (try? c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey)) ?? d.hotkey
            playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
            restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
            onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
        }
    }

    @Published var data: Data
    private var saver: AnyCancellable?

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mynah", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    init() {
        if let raw = try? Foundation.Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(Data.self, from: raw) {
            data = decoded
        } else {
            data = Data()
        }
        saver = $data
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { value in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let raw = try? encoder.encode(value) {
                    try? raw.write(to: Self.fileURL, options: .atomic)
                }
            }
    }
}
