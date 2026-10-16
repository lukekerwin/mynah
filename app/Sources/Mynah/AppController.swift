import AppKit
import Combine
import MynahCore

/// Ties hotkey → recorder → engine → paste together.
///
/// Interaction model (mirrors Wispr Flow):
///  - hold the hotkey to talk, release to insert
///  - tap it once for hands-free; tap again to finish
///  - hold Control as well to give a voice *command* that rewrites the selection
///  - Esc cancels
@MainActor
final class AppController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(command: Bool, handsFree: Bool)
        case processing
    }

    let settings = SettingsStore()
    let engine = EngineClient()
    let history = HistoryStore()
    let overlay = OverlayController()
    let onboarding = OnboardingWindowController()
    /// Meetings database (~/Library/Application Support/Mynah/mynah.sqlite).
    let meetingStore: MeetingStore? = {
        do {
            return try MeetingStore(path: SettingsStore.directory.appendingPathComponent("mynah.sqlite").path)
        } catch {
            NSLog("Mynah: couldn't open meetings database: \(error)")
            return nil
        }
    }()
    let probe = MeetingProbe()
    /// Meeting capture (nil only if the database couldn't be opened).
    lazy var meetings: MeetingController? = meetingStore.map {
        MeetingController(store: $0, settings: settings, engine: engine)
    }

    static let repoURL = URL(string: "https://github.com/lukekerwin/mynah")!

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var accessibilityOK = Permissions.accessibilityGranted
    @Published private(set) var microphoneOK = Permissions.microphoneGranted

    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private var pressedAt = Date()
    private var focus: FocusContext?
    private var subscriptions = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    private static let tapThreshold: TimeInterval = 0.3
    private static let minSamples = 16_000 / 4

    init() {
        probe.enginePID = { [weak engine] in engine?.pid }
        recorder.onLevel = { [weak self] level in self?.overlay.model.push(level: level) }
        hotkey.onPress = { [weak self] command in self?.handlePress(command: command) }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onEscape = { [weak self] in self?.cancel() }
        hotkey.onPauseMic = { [weak self] in
            guard let self, self.settings.data.meetings.pauseMicShortcut else { return }
            self.meetings?.togglePauseMic()
        }
        hotkey.hotkey = settings.data.hotkey

        settings.$data.map(\.hotkey).removeDuplicates()
            .sink { [weak self] key in self?.hotkey.hotkey = key }
            .store(in: &subscriptions)
        settings.$data.map { [$0.asrModel, $0.llmModel, $0.commandModel] }.removeDuplicates().dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyModels() }
            .store(in: &subscriptions)
    }

    // MARK: lifecycle

    func launch() {
        Task { microphoneOK = await Permissions.requestMicrophone() }
        hotkey.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        startEngine()
        meetings?.launch(isDictating: { [weak self] in self?.phase != .idle })
        if !settings.data.onboarded {
            showOnboarding()
        } else if !Permissions.accessibilityGranted {
            Permissions.promptAccessibility()
        }
    }

    func showOnboarding() {
        onboarding.show(controller: self)
    }

    func shutdown() {
        engine.stop()
    }

    func startEngine() {
        engine.start(asr: settings.data.asrModel, llm: llmKey, commandLLM: commandKey)
    }

    private var llmKey: String? { settings.data.llmModel == "none" ? nil : settings.data.llmModel }
    private var commandKey: String? { settings.data.commandModel == "none" ? nil : settings.data.commandModel }

    private func applyModels() {
        Task { await engine.configure(asr: settings.data.asrModel, llm: llmKey, commandLLM: commandKey) }
    }

    private func refreshPermissions() {
        let ax = Permissions.accessibilityGranted
        if ax, !accessibilityOK { hotkey.start() }  // monitors only fire once trusted
        accessibilityOK = ax
        microphoneOK = Permissions.microphoneGranted
    }

    // MARK: hotkey handling

    private func handlePress(command: Bool) {
        switch phase {
        case .idle:
            guard engine.status == .ready else {
                overlay.flash(engine.status.isBusy ? engine.status.summary : "Engine not running — see menu bar")
                return
            }
            guard Permissions.microphoneGranted else {
                overlay.flash("Microphone access needed — open Mynah Settings")
                return
            }
            do {
                try recorder.start(deviceUID: settings.data.inputDevice)
            } catch {
                overlay.flash(error.localizedDescription)
                return
            }
            meetings?.setDictating(true)
            pressedAt = Date()
            phase = .recording(command: command, handsFree: false)
            overlay.show(.recording(command: command, handsFree: false))
            play("Tink")
            focus = FocusContext.capture()
        case .recording(_, handsFree: true):
            finish()
        default:
            break
        }
    }

    private func handleRelease() {
        guard case let .recording(command, false) = phase else { return }
        if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
            phase = .recording(command: command, handsFree: true)
            overlay.show(.recording(command: command, handsFree: true))
        } else {
            finish()
        }
    }

    private func cancel() {
        guard case .recording = phase else { return }
        _ = recorder.stop()
        meetings?.setDictating(false)
        phase = .idle
        overlay.hide()
        play("Bottle")
    }

    // MARK: processing

    private func finish() {
        guard case let .recording(command, _) = phase else { return }
        let samples = recorder.stop()
        meetings?.setDictating(false)
        play("Pop")
        let ctx = focus ?? FocusContext.capture()
        guard samples.count >= Self.minSamples else {
            phase = .idle
            overlay.hide()
            return
        }
        phase = .processing
        overlay.show(.processing(command: command))
        Task {
            defer { phase = .idle }
            do {
                if command {
                    try await runCommand(samples, ctx)
                } else {
                    try await runDictation(samples, ctx)
                }
            } catch {
                overlay.flash("⚠︎ \(error.localizedDescription)", seconds: 4)
            }
        }
    }

    private func runDictation(_ samples: [Float], _ ctx: FocusContext) async throws {
        let result = try await engine.dictate(samples: samples, context: payload(ctx))
        guard !result.text.isEmpty else {
            overlay.flash("No speech detected", seconds: 1.2)
            return
        }
        overlay.hide()
        TextInserter.insert(Self.withLeadingSpace(result.text, after: ctx.precedingCharacter),
                            restoreClipboard: settings.data.restoreClipboard)
        history.add(HistoryEntry(app: ctx.appName, kind: "dictation", raw: result.raw, text: result.text,
                                 asrMs: result.asr_ms, llmMs: result.llm_ms))
    }

    private func runCommand(_ samples: [Float], _ ctx: FocusContext) async throws {
        var selection = ctx.selectedText
        if selection == nil { selection = await TextInserter.copySelection() }
        let result = try await engine.command(samples: samples, selection: selection ?? "", context: payload(ctx))
        guard !result.text.isEmpty else {
            overlay.flash("Didn't catch an instruction", seconds: 1.5)
            return
        }
        overlay.hide()
        TextInserter.insert(result.text, restoreClipboard: settings.data.restoreClipboard)
        history.add(HistoryEntry(app: ctx.appName, kind: "command", raw: result.instruction, text: result.text,
                                 asrMs: result.asr_ms, llmMs: result.llm_ms))
    }

    func pasteLast() {
        guard let last = history.recent.first else { return }
        TextInserter.insert(last.text, restoreClipboard: settings.data.restoreClipboard)
    }

    private func payload(_ ctx: FocusContext) -> [String: Any] {
        [
            "app": ctx.appName,
            "title": ctx.windowTitle ?? "",
            "vocab": settings.data.vocabulary,
            "snippets": settings.data.snippets.map { ["trigger": $0.trigger, "text": $0.text] },
            "cleanup": settings.data.cleanupEnabled,
        ]
    }

    /// Dictating right after a word shouldn't glue the new text onto it.
    static func withLeadingSpace(_ text: String, after previous: Character?) -> String {
        guard let previous, !previous.isWhitespace, !"([{\"'“‘/".contains(previous),
              let first = text.first, !".,;:!?)]}".contains(first) else { return text }
        return " " + text
    }

    private func play(_ name: String) {
        guard settings.data.playSounds, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.25
        sound.play()
    }
}
