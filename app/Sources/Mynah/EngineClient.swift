import Foundation

struct DownloadInfo: Decodable, Equatable {
    var repo: String
    var label: String
    var done: Int64
    var total: Int64
}

struct EngineHealth: Decodable, Equatable {
    var ready: Bool
    var loading: Bool
    var error: String?
    var download: DownloadInfo?
    var asr: String?
    var llm: String?
    var command_llm: String?
}

struct ModelInfo: Decodable, Identifiable, Hashable {
    var key: String
    var params: String
    var downloaded: Bool
    var notes: String?
    var style: String?
    var can_command: Bool?
    var hotwords: Bool?

    var id: String { key }
}

struct ModelsResponse: Decodable {
    var asr: [ModelInfo]
    var llm: [ModelInfo]
}

struct DictationResult: Decodable {
    var raw: String
    var text: String
    var asr_ms: Int
    var llm_ms: Int
}

struct CommandResult: Decodable {
    var instruction: String
    var text: String
    var asr_ms: Int
    var llm_ms: Int
}

struct EngineError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Sets up and runs the Python inference engine bundled in Mynah.app.
///
/// The app ships the engine source, its lockfile and a `uv` binary in
/// Contents/Resources. On launch, `uv sync` creates (first run, ~1 min) or
/// verifies (instant) a private Python environment in ~/.local/share/mynah,
/// then the engine runs from it and exits when the app does.
@MainActor
final class EngineClient: ObservableObject {
    enum Status: Equatable {
        case stopped
        case settingUp
        case starting
        case downloading(label: String, done: Int64, total: Int64)
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .settingUp, .starting, .downloading, .loading: return true
            default: return false
            }
        }

        var summary: String {
            switch self {
            case .stopped: return "Engine stopped"
            case .settingUp: return "Installing engine (first launch)…"
            case .starting: return "Starting engine…"
            case let .downloading(label, done, total):
                guard total > 0 else { return "Downloading \(label.lowercased())…" }
                return "Downloading \(label.lowercased()) — \(Self.gb(done)) of \(Self.gb(total))"
            case .loading: return "Loading models…"
            case .ready: return "Ready"
            case let .failed(message): return "Error: \(message)"
            }
        }

        /// `summary` as a full sentence, for use inside longer copy.
        var sentence: String {
            let s = summary
            return s.hasSuffix("…") || s.hasSuffix(".") ? s : s + "."
        }

        private static func gb(_ bytes: Int64) -> String {
            String(format: "%.1f GB", Double(bytes) / 1e9)
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var health: EngineHealth?

    private var setupProcess: Process?
    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private var port = 0
    private let token = UUID().uuidString
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    // MARK: locations

    private static let support = SettingsStore.directory
    /// Python runtime + environment live in a path without spaces: several tools in
    /// the Python/uv chain have broken on "Application Support" over the years.
    private static let runtime: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/mynah", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static var envDir: URL { runtime.appendingPathComponent("env") }
    private static var pidFile: URL { support.appendingPathComponent("engine.pid") }
    private static var caches: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mynah", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var logFile: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Mynah", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log")
    }

    /// Engine source + uv: bundled in the app, or overridden for development
    /// (`MYNAH_ENGINE_DIR=…/engine swift run`).
    private static func engineLocation() -> (source: URL, uv: URL)? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MYNAH_ENGINE_DIR"] {
            let uv = env["MYNAH_UV"] ?? "/opt/homebrew/bin/uv"
            return (URL(fileURLWithPath: dir), URL(fileURLWithPath: uv))
        }
        guard let res = Bundle.main.resourceURL else { return nil }
        let source = res.appendingPathComponent("engine")
        let uv = res.appendingPathComponent("bin/uv")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("uv.lock").path),
              FileManager.default.isExecutableFile(atPath: uv.path) else { return nil }
        return (source, uv)
    }

    // MARK: lifecycle

    func start(asr: String, llm: String?, commandLLM: String?) {
        killStaleEngine()
        stop()
        generation += 1
        let gen = generation
        guard let location = Self.engineLocation() else {
            status = .failed("Engine files are missing from the app bundle — try reinstalling Mynah.")
            return
        }
        Task { await launch(gen: gen, location: location, asr: asr, llm: llm, commandLLM: commandLLM) }
    }

    private func launch(gen: Int, location: (source: URL, uv: URL), asr: String, llm: String?, commandLLM: String?) async {
        Self.rotateLogIfLarge()
        let firstRun = !FileManager.default.fileExists(atPath: Self.envDir.appendingPathComponent("bin/python").path)
        status = firstRun ? .settingUp : .starting
        Self.appendLog("=== \(Date()) launching engine (first run: \(firstRun))\n")

        // 1. Create/verify the Python environment from the bundled lockfile.
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = Self.envDir.path
        env["UV_PYTHON_INSTALL_DIR"] = Self.runtime.appendingPathComponent("python").path
        env["UV_CACHE_DIR"] = Self.caches.appendingPathComponent("uv").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_NO_CONFIG"] = "1"
        let syncStatus = await runSetup(location.uv, env: env, args: [
            "sync", "--frozen", "--no-dev", "--no-install-project", "--python", "3.12",
            "--project", location.source.path,
        ])
        guard gen == generation else { return }
        guard syncStatus == 0 else {
            status = .failed("Engine setup failed (needs internet on first launch). See the engine log.")
            return
        }

        // 2. Run the engine from that environment.
        port = Self.freePort()
        let proc = Process()
        proc.executableURL = Self.envDir.appendingPathComponent("bin/python")
        proc.arguments = ["-m", "mynah_engine", "--port", "\(port)", "--asr", asr,
                          "--llm", llm ?? "none", "--command-llm", commandLLM ?? "none",
                          "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)"]
        var runEnv = ProcessInfo.processInfo.environment
        runEnv["MYNAH_ENGINE_TOKEN"] = token
        runEnv["PYTHONPATH"] = location.source.appendingPathComponent("src").path
        runEnv["PYTHONPYCACHEPREFIX"] = Self.caches.appendingPathComponent("pycache").path
        runEnv["PYTHONNOUSERSITE"] = "1"
        runEnv["PYTHONUNBUFFERED"] = "1"
        proc.environment = runEnv
        if let log = Self.logHandle() {
            proc.standardOutput = log
            proc.standardError = log
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.process = nil
                self.status = .failed("Engine stopped unexpectedly (code \(p.terminationStatus)). See the engine log.")
            }
        }
        do {
            try proc.run()
        } catch {
            status = .failed("Couldn't launch engine: \(error.localizedDescription)")
            return
        }
        process = proc
        try? "\(proc.processIdentifier)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
        status = .starting
        startPolling(gen: gen)
    }

    private func runSetup(_ uv: URL, env: [String: String], args: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = uv
            proc.arguments = args
            proc.environment = env
            if let log = Self.logHandle() {
                proc.standardOutput = log
                proc.standardError = log
            }
            proc.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try proc.run()
                setupProcess = proc
            } catch {
                Self.appendLog("couldn't run uv: \(error)\n")
                continuation.resume(returning: -1)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let setupProcess, setupProcess.isRunning { setupProcess.terminate() }
        setupProcess = nil
        if let process {
            self.process = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: Self.pidFile)
        }
        status = .stopped
    }

    /// An engine left over from a previous app instance would hold GPU memory.
    /// (Engines also exit on their own once their parent app is gone.)
    private func killStaleEngine() {
        guard process == nil,
              let raw = try? String(contentsOf: Self.pidFile, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        try? FileManager.default.removeItem(at: Self.pidFile)
        guard kill(pid, SIGTERM) == 0 else { return }
        for _ in 0..<30 where kill(pid, 0) == 0 {
            usleep(100_000)
        }
    }

    private func startPolling(gen: Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                if let health = try? await self.get("/health", as: EngineHealth.self) {
                    self.health = health
                    if let err = health.error {
                        self.status = .failed(err)
                    } else if health.ready {
                        self.status = .ready
                    } else if let d = health.download {
                        self.status = .downloading(label: d.label, done: d.done, total: d.total)
                    } else {
                        self.status = .loading
                    }
                }
                let interval: UInt64 = self.status == .ready ? 5 : 1
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    // MARK: API

    func configure(asr: String, llm: String?, commandLLM: String?) async {
        let body: [String: Any] = ["asr": asr, "llm": llm ?? NSNull(), "command_llm": commandLLM ?? NSNull()]
        _ = try? await post("/config", body: body, as: [String: Bool].self)
        status = .loading
    }

    func models() async throws -> ModelsResponse {
        try await get("/models", as: ModelsResponse.self)
    }

    func dictate(samples: [Float], context: [String: Any]) async throws -> DictationResult {
        try await post("/dictate", body: ["audio": Self.encode(samples), "context": context], as: DictationResult.self)
    }

    func command(samples: [Float], selection: String, context: [String: Any]) async throws -> CommandResult {
        try await post("/command", body: ["audio": Self.encode(samples), "selection": selection, "context": context],
                       as: CommandResult.self)
    }

    // MARK: helpers

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: addr.sin_port)) : 47821
    }

    private static func logHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    private static func rotateLogIfLarge() {
        let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int) ?? 0
        guard size > 5_000_000 else { return }
        let old = logFile.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logFile, to: old)
    }

    private static func appendLog(_ text: String) {
        logHandle()?.write(Data(text.utf8))
    }

    private static func encode(_ samples: [Float]) -> String {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767).littleEndian
        }
        return pcm.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request(path))
        return try decode(data, response)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], as: T.Type) async throws -> T {
        var req = request(path)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw EngineError(message: message ?? "Engine error \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
