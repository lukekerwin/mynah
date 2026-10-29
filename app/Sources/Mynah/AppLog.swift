import Foundation
import os

/// Mynah's own log file, ~/Library/Logs/Mynah/app.log, next to engine.log. The
/// unified log needs an admin account to read, so everything logged through
/// `AppLogger` is also written here.
enum AppLog {
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mynah", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    private static let queue = DispatchQueue(label: "com.lukekerwin.mynah.applog", qos: .utility)
    private static let maxBytes = 5 << 20
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Safe from any thread; doesn't touch the main thread, so the freeze watchdog can use it.
    static func write(_ category: String, _ level: String, _ message: String) {
        let date = Date()
        queue.async {
            let line = "\(stamp.string(from: date)) \(level) [\(category)] \(message)\n"
            let url = fileURL
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

/// Logs to the unified log and to app.log. Takes the same interpolations as
/// os.Logger (`privacy:`, `format: .fixed(precision:)`); `.private` values are
/// redacted in both.
struct AppLogger {
    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: "com.lukekerwin.mynah", category: category)
    }

    func info(_ message: LogMessage) {
        logger.info("\(message.text, privacy: .public)")
        AppLog.write(category, "info", message.text)
    }

    func notice(_ message: LogMessage) {
        logger.notice("\(message.text, privacy: .public)")
        AppLog.write(category, "notice", message.text)
    }

    func error(_ message: LogMessage) {
        logger.error("\(message.text, privacy: .public)")
        AppLog.write(category, "error", message.text)
    }
}

enum LogPrivacy { case `public`, `private`, auto }

enum LogFormat { case fixed(precision: Int) }

struct LogMessage: ExpressibleByStringInterpolation {
    let text: String

    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }

        mutating func appendLiteral(_ literal: String) { text += literal }

        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .auto) {
            text += privacy == .private ? "<private>" : "\(value)"
        }

        mutating func appendInterpolation(_ value: Double, format: LogFormat, privacy: LogPrivacy = .auto) {
            guard privacy != .private else { text += "<private>"; return }
            switch format {
            case let .fixed(precision): text += String(format: "%.\(precision)f", value)
            }
        }
    }
}
