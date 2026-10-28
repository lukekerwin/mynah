import AppKit
import Combine
import MynahCore
import SwiftUI

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
    /// Meetings database (~/Library/Application Support/Mynah/mynah.sqlite); in
    /// memory with demo data under MYNAH_UI_PREVIEW so previews never touch real meetings.
    let meetingStore: MeetingStore? = {
        do {
            if ProcessInfo.processInfo.environment["MYNAH_UI_PREVIEW"] != nil { return try MeetingStore() }
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
    let mainWindow = MainWindowController()
    let updater = Updater()
    private(set) var statusBar: StatusBarController?

    static let repoURL = URL(string: "https://github.com/lukekerwin/mynah")!

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var accessibilityOK = Permissions.accessibilityGranted
    @Published private(set) var microphoneOK = Permissions.microphoneGranted

    private let recorder = AudioRecorder()
    private let media = MediaPauser()
    private let hotkey = HotkeyMonitor()
    private var pressedAt = Date()
    private var focus: FocusContext?
    private var subscriptions = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    private static let tapThreshold: TimeInterval = 0.3
    private static let minSamples = 16_000 / 4

    init() {
        probe.enginePID = { [weak engine] in engine?.pid }
        probe.micDeviceUID = { [weak settings] in settings?.data.inputDevice ?? "" }
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
        // Every Accessibility call (other apps' focus, Teams' call window) gives up after
        // 1 s instead of the default ~6 s when the other app is busy.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        statusBar = StatusBarController(controller: self)
        // Show a Dock icon while any window is open, so the app can be found,
        // reopened, or force-quit like a normal app; hide it again after.
        // Synchronous (queue .main), so the two can't land out of order.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivationPolicy() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self?.updateActivationPolicy(closing: closing) }
        }
        if let mode = ProcessInfo.processInfo.environment["MYNAH_UI_PREVIEW"] {
            previewUI(mode)
            return
        }
        Task { microphoneOK = await Permissions.requestMicrophone() }
        hotkey.start()
        observeSleepAndLock()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        startEngine()
        updater.isBusy = { [weak self] in self?.meetings?.isRecording == true }
        updater.start()
        meetings?.onShowMeetings = { [weak self] id in self?.showMain(.meetings, meeting: id.map { MeetingFocus(meetingID: $0) }) }
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

    func showMain(_ page: Page = .home, meeting: MeetingFocus? = nil) {
        mainWindow.show(page, meeting: meeting, controller: self)
    }

    /// `closing` is still visible while it closes, so it's left out of the count. (It
    /// used to be subtracted blindly: closing any popover, e.g. "New to-do", with only
    /// the main window open counted zero windows, went `.accessory`, and sent the
    /// main window behind the previous app.)
    private func updateActivationPolicy(closing: NSWindow? = nil) {
        let open = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }.count
        let policy: NSApplication.ActivationPolicy = open > 0 ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// `MYNAH_UI_PREVIEW=home|onboarding|overlay|meetings|meeting|todos|livepanel|…`: open
    /// that UI without starting the engine or the hotkey, so a development build can run
    /// next to the installed app. Meeting previews use demo data in an in-memory database.
    private func previewUI(_ mode: String) {
        if let look = ProcessInfo.processInfo.environment["MYNAH_UI_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
        }
        let demo = meetingStore.map(PreviewData.seed)
        meetings?.onShowMeetings = { [weak self] id in self?.showMain(.meetings, meeting: id.map { MeetingFocus(meetingID: $0) }) }
        switch mode {
        case "none":
            break
        case "meeting":
            showMain(.meetings, meeting: demo.map { MeetingFocus(meetingID: $0.finished) })
        case "livepanel", "livemeeting":
            if let demo { meetings?.previewRecording(meetingID: demo.live, title: "Launch sync", script: PreviewData.liveScript) }
            if mode == "livemeeting" { showMain(.meetings, meeting: demo.map { MeetingFocus(meetingID: $0.live) }) }
        case "statusbar":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.statusBar?.show() }
        case "onboarding":
            showOnboarding()
        case "overlay":
            overlay.show(.recording(command: false, handsFree: true))
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.overlay.model.push(level: Float.random(in: 0.0008...0.06)) }
            }
        case "menu":
            let panel = MenuPanel(controller: self, settings: settings, engine: engine, history: history)
            let window = NSWindow(contentViewController: NSHostingController(rootView: panel))
            window.styleMask = [.borderless]
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
        default:
            showMain(Page(rawValue: mode) ?? .home)
        }
        // MYNAH_UI_SHOT=/dir: write a PNG of every visible window there, then quit.
        if let dir = ProcessInfo.processInfo.environment["MYNAH_UI_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(mode)-\(i).png"))
                }
                NSApp.terminate(nil)
            }
        }
    }

    func shutdown() {
        engine.stop()
    }

    /// Opening and closing the lid. Before this, a dictation left recording carried on
    /// through sleep, a meeting recording got hours of silence appended on wake, and the
    /// first dictation after a long sleep waited ~20 s for the models to page back in.
    private func observeSleepAndLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        // Screen locked or another user switched in: stop listening (a hands-free
        // dictation would otherwise record the room until you're back).
        let locked: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(quietly: true) }
        }
        let unlocked: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkey.start() }
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: locked)
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: unlocked)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: locked)
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: unlocked)
    }

    private func systemWillSleep() {
        cancel(quietly: true)
        meetings?.systemWillSleep()
    }

    private func systemDidWake() {
        // Re-arms the key monitors and forgets a key-down whose key-up was lost
        // (otherwise the next press is ignored and its release ends a phantom dictation).
        hotkey.start()
        refreshPermissions()
        meetings?.systemDidWake()
        engine.systemDidWake()
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
        // Assign only on change: every @Published write re-renders all the views
        // observing the controller, even hidden ones, and this runs every 2 s.
        let ax = Permissions.accessibilityGranted
        if ax != accessibilityOK {
            if ax { hotkey.start() }  // monitors only fire once trusted
            accessibilityOK = ax
        }
        let mic = Permissions.microphoneGranted
        if mic != microphoneOK { microphoneOK = mic }
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
            engine.warmUp()
            meetings?.setDictating(true)
            if settings.data.pauseMedia { media.pause() }
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

    /// Esc, or `quietly` when the Mac sleeps or locks: then media we paused stays
    /// paused (resuming would start it playing as the lid closes) and no sound plays.
    private func cancel(quietly: Bool = false) {
        guard case .recording = phase else { return }
        _ = recorder.stop()
        meetings?.setDictating(false)
        if quietly { media.forget() } else { media.resume() }
        phase = .idle
        overlay.hide()
        if !quietly { play("Bottle") }
    }

    // MARK: processing

    private func finish() {
        guard case let .recording(command, _) = phase else { return }
        let samples = recorder.stop()
        meetings?.setDictating(false)
        media.resume()
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
