import AppKit
import Combine
import CoreAudio
import MynahCore
import os

private let log = Logger(subsystem: "com.lukekerwin.mynah", category: "meeting")

/// An app whose audio can be recorded manually ("Record Meeting ›").
struct AudioApp: Identifiable, Hashable {
    var bundlePrefix: String  // empty = all system audio
    var name: String
    var id: String { bundlePrefix }

    static let allAudio = AudioApp(bundlePrefix: "", name: "All System Audio")
}

/// Meeting capture: detects Teams calls, runs the recording session, drives
/// transcription during and after the call, recovers after crashes, and applies
/// audio retention. The summary job lives in SummaryRunner.
@MainActor
final class MeetingController: ObservableObject {
    struct Recording: Equatable {
        var meetingID: String
        var title: String
        var since: Date
        var app: AudioApp
        var manual: Bool
        var paused = false
    }

    enum State: Equatable {
        case off
        case unavailable(String)
        case idle
        case asking
        case recording(Recording)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var elapsed = ""
    /// Teams has been playing for a minute but the tap only produced zeros.
    @Published private(set) var permissionProblem = false
    @Published private(set) var teamsMuted: Bool?

    let store: MeetingStore
    let processor: MeetingProcessor
    let summaries: SummaryRunner
    let notifications = MeetingNotifications()
    /// Opens the Meetings page in the app window (set by AppController).
    var onShowMeetings: ((String?) -> Void)?
    /// Live transcript pill at the screen edge; nil until launch (and in previews that don't want it).
    var livePanel: LiveTranscriptController?

    private let settings: SettingsStore
    private let engine: EngineClient
    private let detector = MeetingDetector()
    private var session: AnyObject?  // MeetingSession (macOS 14.2+)
    private var dictating = false
    private var ignoreCurrentCall = false
    private var loopTask: Task<Void, Never>?
    private var ticker: Timer?
    private var axTimer: Timer?
    private var silenceTimer: Timer?
    private var teamsOutputSince: Date?
    private var readingTeams = false
    /// This recording already logged/notified why Teams' mute state can't be read.
    private var muteProblemReported = false
    private var micCandidatesLogged = false
    /// Call-window end detection: the window was seen this recording, when it went
    /// away, and when the call last made a sound.
    private var callWindowSeen = false
    private var callWindowGoneSince: Date?
    private var lastCallSound = Date()
    /// Window gone and the call silent this long: the call is over.
    private static let windowEndSeconds: TimeInterval = 20
    private var sweepTimer: Timer?
    private var preparedGeneration = false
    private var subscriptions = Set<AnyCancellable>()
    private static let askNotificationID = "meeting-ask"

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    init(store: MeetingStore, settings: SettingsStore, engine: EngineClient) {
        self.store = store
        self.settings = settings
        self.engine = engine
        processor = MeetingProcessor(store: store, engine: engine, settings: settings)
        summaries = SummaryRunner(store: store, engine: engine, settings: settings)
        summaries.isRecording = { [weak self] in self?.isRecording ?? false }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var recording: Recording? {
        if case let .recording(r) = state { return r }
        return nil
    }

    var enabled: Bool { settings.data.meetings.enabled }

    /// Recording a Teams call with mute detection on, but its mic button can't be read
    /// (no Accessibility permission, or the call window isn't found).
    var teamsMuteUnreadable: Bool {
        guard let r = recording, r.app.bundlePrefix == MeetingDetector.teamsPrefix,
              settings.data.meetings.teamsMuteDetection else { return false }
        return teamsMuted == nil && Date().timeIntervalSince(r.since) > 15
    }

    // MARK: lifecycle

    func launch(isDictating: @escaping () -> Bool) {
        summaries.isDictating = isDictating
        summaries.onFinished = { [weak self] meeting, ok in
            guard let self else { return }
            let title = (try? self.store.meeting(id: meeting.id))?.title ?? meeting.title
            self.notifications.post(ok ? "Meeting notes ready" : "Couldn't summarize the meeting",
                                    ok ? title : "\(title) — open it to retry", meetingID: meeting.id)
        }
        notifications.setUp()
        notifications.onRecord = { [weak self] in self?.acceptAsk() }
        notifications.onIgnore = { [weak self] in self?.declineAsk() }
        notifications.onOpen = { [weak self] id in self?.showMeetings(focus: id) }
        livePanel = LiveTranscriptController(meetings: self, settings: settings)

        detector.onCallStarted = { [weak self] in self?.callStarted() }
        detector.onCallEnded = { [weak self] in self?.callEnded() }
        detector.onTeamsProcessesChanged = { [weak self] processes in self?.teamsProcessesChanged(processes) }

        settings.$data.map(\.meetings.enabled).removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &subscriptions)
        engine.$status.removeDuplicates()
            .sink { [weak self] status in DispatchQueue.main.async { self?.engineStatusChanged(status) } }
            .store(in: &subscriptions)

        summaries.start()
        recoverInterrupted()
        if MeetingProbe.enabled, let path = UserDefaults.standard.string(forKey: "MynahImportProbe") {
            importProbe(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))  // -MynahImportProbe <folder>
        }
        processor.sweepRetention()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processor.sweepRetention() }
        }
        apply()
    }

    /// Turn detection on/off to match the setting.
    private func apply() {
        guard enabled else {
            detector.stop()
            if isRecording { stop(discard: false) }
            state = .off
            return
        }
        guard Self.isSupported else {
            state = .unavailable("Meeting capture needs macOS 14.2 or later.")
            return
        }
        detector.start()
        if case .off = state { state = .idle }
        if case .unavailable = state { state = .idle }
        prepareEngine()
    }

    private func engineStatusChanged(_ status: EngineClient.Status) {
        if status != .ready { preparedGeneration = false }
        prepareEngine()
        if status == .ready { summaries.tick() }
    }

    /// Load the voice detector once per engine launch (downloads ~2 MB the first time).
    private func prepareEngine() {
        guard enabled, engine.status == .ready, !preparedGeneration else { return }
        preparedGeneration = true
        Task {
            do { try await engine.prepareMeetings() } catch {
                preparedGeneration = false
                log.error("prepare meetings failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: detection

    private func callStarted() {
        guard enabled, !isRecording else { return }
        ignoreCurrentCall = false
        if settings.data.meetings.autoRecord {
            startRecording(app: AudioApp(bundlePrefix: MeetingDetector.teamsPrefix, name: "Microsoft Teams"), manual: false)
        } else {
            state = .asking
            notifications.post("Teams call started", "Record and transcribe this call?", ask: true,
                               id: Self.askNotificationID)
        }
    }

    private func callEnded() {
        notifications.remove(id: Self.askNotificationID)
        ignoreCurrentCall = false
        switch state {
        case .asking: state = .idle
        case let .recording(r) where !r.manual: stop(discard: false)
        default: break
        }
    }

    func recordAskedCall() { acceptAsk() }

    private func acceptAsk() {
        guard case .asking = state, detector.inCall else { return }
        startRecording(app: AudioApp(bundlePrefix: MeetingDetector.teamsPrefix, name: "Microsoft Teams"), manual: false)
    }

    private func declineAsk() {
        guard case .asking = state else { return }
        ignoreCurrentCall = true
        state = .idle
    }

    private func teamsProcessesChanged(_ processes: [AudioProcess]) {
        guard #available(macOS 14.2, *), let r = recording, r.app.bundlePrefix == MeetingDetector.teamsPrefix,
              let session = session as? MeetingSession, !processes.isEmpty else { return }
        session.update(target: .processes(processes.map(\.objectID)))
    }

    // MARK: recording

    /// Apps currently playing audio (for manual recording), plus "All System Audio".
    func audioApps() -> [AudioApp] {
        let own = Bundle.main.bundleIdentifier ?? ""
        var seen = Set<String>()
        var apps: [AudioApp] = []
        for p in CoreAudioProcesses.snapshot() where p.runningOutput && !p.bundleID.isEmpty && p.bundleID != own {
            let prefix = p.bundleID.split(separator: ".").prefix(3).joined(separator: ".")
            guard seen.insert(prefix).inserted else { continue }
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: prefix).first?.localizedName
                ?? p.appName
            apps.append(AudioApp(bundlePrefix: prefix, name: name))
        }
        return apps.sorted { $0.name < $1.name } + [.allAudio]
    }

    func startManual(_ app: AudioApp) {
        guard enabled, !isRecording else { return }
        startRecording(app: app, manual: true)
    }

    private func startRecording(app: AudioApp, manual: Bool) {
        guard #available(macOS 14.2, *) else { return }
        let shortName = app.bundlePrefix == MeetingDetector.teamsPrefix ? "Teams" : app.name
        var meeting = Meeting(title: MeetingTitle.placeholder(app: shortName, date: Date()),
                              appBundleID: app.bundlePrefix.isEmpty ? "system" : app.bundlePrefix,
                              appName: app.name, source: manual ? "manual" : "auto")
        do {
            try store.createMeeting(meeting)
        } catch {
            log.error("couldn't create meeting: \(error.localizedDescription, privacy: .public)")
            return
        }
        let target = tapTarget(for: app)
        let session = MeetingSession(meetingID: meeting.id, directory: MeetingProcessor.directory(meeting.id),
                                     micUID: settings.data.inputDevice)
        self.session = session
        state = .recording(Recording(meetingID: meeting.id, title: meeting.title, since: Date(), app: app, manual: manual))
        permissionProblem = false
        teamsMuted = nil
        muteProblemReported = false
        micCandidatesLogged = false
        teamsOutputSince = nil
        callWindowSeen = false
        callWindowGoneSince = nil
        lastCallSound = Date()

        Task {
            do {
                try await session.start(target: target)
            } catch {
                log.error("recording failed to start: \(error.localizedDescription, privacy: .public)")
                self.session = nil
                state = enabled ? .idle : .off
                try? FileManager.default.removeItem(at: session.directory)
                try? store.deleteMeeting(id: meeting.id)
                notifications.post("Couldn't start recording", error.localizedDescription)
                return
            }
            guard self.session === session else { return }  // stopped while starting
            meeting.startedAt = session.startedAt
            try? store.update(meeting)
            session.setGate { $0.dictating = self.dictating }
            startTimers(meetingID: meeting.id, isTeams: app.bundlePrefix == MeetingDetector.teamsPrefix)
            notifications.post("Recording \(shortName) call", "Mynah is transcribing this call on your Mac.",
                               meetingID: meeting.id)
        }
        summaries.tick()  // interrupts a running summary
    }

    @available(macOS 14.2, *)
    private func tapTarget(for app: AudioApp) -> ProcessTap.Target {
        if app.bundlePrefix.isEmpty {
            return .everythingExcept(CoreAudioProcesses.ownProcessObject().map { [$0] } ?? [])
        }
        let ids = CoreAudioProcesses.snapshot().filter { $0.bundleID.hasPrefix(app.bundlePrefix) }.map(\.objectID)
        return .processes(ids)
    }

    func stop(discard: Bool) {
        guard let r = recording else { return }
        stopTimers()
        if #available(macOS 14.2, *) { (session as? MeetingSession)?.stop() }
        session = nil
        teamsMuted = nil
        state = enabled ? .idle : .off
        let id = r.meetingID
        if discard {
            try? FileManager.default.removeItem(at: MeetingProcessor.directory(id))
            try? store.deleteMeeting(id: id)
            return
        }
        _ = try? store.modifyMeeting(id: id) {
            $0.endedAt = Date()
            $0.status = .transcribing
        }
        Task {
            await processor.finalize(meetingID: id)
            let m = try? store.meeting(id: id)
            if m?.status == .queued {
                notifications.post("Transcript ready", m?.title ?? r.title, meetingID: id)
                summaries.schedule()
            }
        }
    }

    func confirmDiscard() {
        guard isRecording else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop and discard this recording?"
        alert.informativeText = "The audio and transcript so far will be deleted."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { stop(discard: true) }
    }

    func togglePauseMic() {
        guard var r = recording else { return }
        r.paused.toggle()
        state = .recording(r)
        if #available(macOS 14.2, *) {
            let paused = r.paused
            (session as? MeetingSession)?.setGate { $0.paused = paused }
        }
    }

    /// Dictation audio never goes into the meeting's "You" track.
    func setDictating(_ on: Bool) {
        dictating = on
        if #available(macOS 14.2, *) { (session as? MeetingSession)?.setGate { $0.dictating = on } }
        if !on { summaries.tick() }
    }

    // MARK: while recording

    private func startTimers(meetingID: String, isTeams: Bool) {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
        updateElapsed()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTapAudio() }
        }
        if isTeams {
            axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readTeamsWindow() }
            }
        }
        // Transcribe in bursts: each track every 16 s, staggered by 8 s, so the live
        // transcript keeps up with the call without hogging the engine.
        loopTask = Task { [weak self] in
            var track = Track.others
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled, #available(macOS 14.2, *),
                      let session = self.session as? MeetingSession, session.meetingID == meetingID else { return }
                // The mic window can't run ahead of the call audio BleedGate compares it with.
                let available = track == .you ? min(session.samplesWritten(.you), session.samplesWritten(.others))
                    : session.samplesWritten(track)
                if await self.processor.transcribe(meetingID: meetingID, track: track, available: available, final: false) {
                    try? self.processor.hideEcho(meetingID: meetingID)
                }
                track = track == .others ? .you : .others
            }
        }
    }

    private func stopTimers() {
        loopTask?.cancel()
        loopTask = nil
        for t in [ticker, axTimer, silenceTimer] { t?.invalidate() }
        ticker = nil
        axTimer = nil
        silenceTimer = nil
        elapsed = ""
    }

    private func updateElapsed() {
        guard let r = recording else { return }
        let s = Int(Date().timeIntervalSince(r.since))
        elapsed = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A denied System Audio Recording permission yields exact zeros; real calls
    /// never do. (Teams keeps its output open through silence, so "quiet" ≠ denied.)
    private func checkTapAudio() {
        guard #available(macOS 14.2, *), let r = recording, let session = session as? MeetingSession else { return }
        let peak = session.takeOthersPeak()
        if peak > 0.01 { lastCallSound = Date() }  // above -40 dBFS: someone's talking
        if peak > 0 {
            UserDefaults.standard.set(true, forKey: "MynahSystemAudioVerified")
            permissionProblem = false
            return
        }
        guard !session.othersEverHeard, !permissionProblem else { return }
        let prefix = r.app.bundlePrefix
        let playing = CoreAudioProcesses.snapshot().contains {
            $0.runningOutput && (prefix.isEmpty || $0.bundleID.hasPrefix(prefix))
        }
        if playing {
            teamsOutputSince = teamsOutputSince ?? Date()
            if Date().timeIntervalSince(teamsOutputSince!) >= 60 {
                permissionProblem = true
                notifications.post("Mynah can't hear the call",
                                   "Allow Mynah under System Settings › Privacy & Security › Screen & System Audio Recording.",
                                   meetingID: r.meetingID)
            }
        }
    }

    /// Meeting title and mute state from the Teams call window (best effort).
    private func readTeamsWindow() {
        guard let r = recording, !readingTeams else { return }
        readingTeams = true
        Task.detached(priority: .utility) {
            let call = TeamsAccessibility.read()
            await MainActor.run {
                self.readingTeams = false
                self.applyTeamsWindow(call, meetingID: r.meetingID)
            }
        }
    }

    private func applyTeamsWindow(_ call: TeamsAccessibility.CallState, meetingID: String) {
        guard var r = recording, r.meetingID == meetingID else { return }
        let muted = settings.data.meetings.teamsMuteDetection ? (call.muted ?? false) : false
        if teamsMuted != call.muted {
            log.notice("Teams mute state: \(call.muted.map { $0 ? "muted" : "live" } ?? "unknown", privacy: .public)")
            teamsMuted = call.muted
        }
        if #available(macOS 14.2, *) { (session as? MeetingSession)?.setGate { $0.teamsMuted = muted } }
        reportMuteProblem(call, r)
        if endIfCallWindowClosed(call.windowOpen, r) { return }
        if let title = call.title, title != r.title,
           let m = try? store.meeting(id: meetingID), !m.titleEdited {
            _ = try? store.modifyMeeting(id: meetingID) { $0.title = title }
            r.title = title
            state = .recording(r)
        }
    }

    /// Unreadable mute state means the mic is recorded while muted. Says so once per
    /// recording (log + notification), with what the call window offered instead.
    private func reportMuteProblem(_ call: TeamsAccessibility.CallState, _ r: Recording) {
        if let c = call.micCandidates, !micCandidatesLogged {
            micCandidatesLogged = true
            log.notice("Teams mic button not recognized; mic-like buttons: \(c.isEmpty ? "none" : c.joined(separator: " | "), privacy: .public)")
        }
        guard call.muted == nil, settings.data.meetings.teamsMuteDetection, !muteProblemReported,
              Date().timeIntervalSince(r.since) > 20 else { return }
        muteProblemReported = true
        let why = !call.accessible ? "no Accessibility permission"
            : call.windowOpen == true ? "no mic button found" : "no call window found"
        log.notice("Teams mute state unreadable: \(why, privacy: .public)\(call.searchNote.map { "; Teams windows: " + $0 } ?? "", privacy: .public)")
        let pause = settings.data.meetings.pauseMicShortcut ? " Press ⌃⌥M to pause your mic." : ""
        notifications.post("Mynah can't see Teams' mute button",
                           "Your mic is recorded even while you're muted in Teams.\(pause)", meetingID: r.meetingID)
    }

    /// Teams can hold the mic after you leave, so the audio-based detector may never
    /// fire. Once the call window has been seen, its closing ends the recording —
    /// but only after the call has also gone quiet, so a window Teams briefly
    /// rebuilds (pop-out, full screen) doesn't split the meeting.
    private func endIfCallWindowClosed(_ open: Bool?, _ r: Recording) -> Bool {
        guard !r.manual, let open else { return false }
        if open {
            callWindowSeen = true
            callWindowGoneSince = nil
            return false
        }
        guard callWindowSeen else { return false }
        let gone = callWindowGoneSince ?? Date()
        callWindowGoneSince = gone
        let now = Date()
        guard now.timeIntervalSince(gone) >= Self.windowEndSeconds,
              now.timeIntervalSince(lastCallSound) >= Self.windowEndSeconds else { return false }
        log.notice("Teams call window closed: ending \(r.meetingID, privacy: .public)")
        stop(discard: false)
        return true
    }

    // MARK: recovery & management

    /// Meetings cut off by a crash or force-quit: fix the WAV headers and finish them.
    private func recoverInterrupted() {
        guard let stuck = try? store.meetings(status: [.recording, .transcribing]), !stuck.isEmpty else { return }
        for m in stuck {
            let dir = MeetingProcessor.directory(m.id)
            var ended = m.endedAt
            for track in [Track.others, .you] {
                let url = MeetingProcessor.audioURL(dir, track)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                _ = try? WAVHeader.repair(url: url)
                if ended == nil {
                    ended = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                }
            }
            _ = try? store.modifyMeeting(id: m.id) {
                $0.endedAt = ended ?? $0.startedAt
                $0.status = .transcribing
            }
            log.notice("recovering meeting \(m.id, privacy: .public)")
            Task {
                await processor.finalize(meetingID: m.id)
                if (try? store.meeting(id: m.id))?.status == .queued { summaries.schedule(after: 60) }
            }
        }
    }

    func deleteMeeting(_ id: String) {
        if recording?.meetingID == id { stop(discard: true); return }
        try? FileManager.default.removeItem(at: MeetingProcessor.directory(id))
        try? store.deleteMeeting(id: id)
    }

    func deleteAudio(_ id: String) {
        guard recording?.meetingID != id else { return }
        processor.deleteAudio(meetingID: id)
    }

    func rename(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        _ = try? store.modifyMeeting(id: id) {
            $0.title = t
            $0.titleEdited = true
        }
        if var r = recording, r.meetingID == id {
            r.title = t
            state = .recording(r)
        }
    }

    /// Debug: treat a Phase 0 probe folder (others.wav + you.wav) as a finished
    /// meeting and run the real pipeline on it — transcript, echo filter, summary.
    func importProbe(_ folder: URL) {
        let others = folder.appendingPathComponent("others.wav")
        guard FileManager.default.fileExists(atPath: others.path) else {
            log.error("import: no others.wav in \(folder.path, privacy: .public)")
            return
        }
        let start = (try? FileManager.default.attributesOfItem(atPath: others.path)[.creationDate] as? Date) ?? Date()
        let seconds = Double(WAVReader.sampleCount(url: others)) / Double(MeetingProcessor.sampleRate)
        var meeting = Meeting(title: "Imported – \(folder.lastPathComponent)", appBundleID: "probe", appName: "Probe import",
                              source: "manual", startedAt: start)
        meeting.endedAt = start.addingTimeInterval(seconds)
        meeting.status = .transcribing
        let dir = MeetingProcessor.directory(meeting.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for track in [Track.others, .you] {
                let src = folder.appendingPathComponent("\(track.rawValue).wav")
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.copyItem(at: src, to: MeetingProcessor.audioURL(dir, track))
                }
            }
            try store.createMeeting(meeting)
        } catch {
            log.error("import failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        log.notice("imported probe \(folder.path, privacy: .public) as \(meeting.id, privacy: .public)")
        let id = meeting.id
        Task {
            await processor.finalize(meetingID: id)
            if (try? store.meeting(id: id))?.status == .queued { summaries.summarizeNow(id) }
        }
    }

    func showMeetings(focus meetingID: String? = nil) {
        onShowMeetings?(meetingID)
    }

    /// `MYNAH_UI_PREVIEW=livepanel`: pretend a call is being recorded, feeding demo lines
    /// into the store every few seconds so the live transcript pill can be seen and styled.
    func previewRecording(meetingID: String, title: String, script: [(Track, String)]) {
        state = .recording(Recording(meetingID: meetingID, title: title, since: Date().addingTimeInterval(-754),
                                     app: AudioApp(bundlePrefix: MeetingDetector.teamsPrefix, name: "Microsoft Teams"),
                                     manual: false))
        livePanel = LiveTranscriptController(meetings: self, settings: settings)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
        updateElapsed()
        // Screenshots: open the card and show a conversation straight away.
        let shot = ProcessInfo.processInfo.environment["MYNAH_UI_SHOT"] != nil
        if shot { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.livePanel?.pinOpen() } }
        Task {
            var t = 0.0
            for (index, (track, text)) in script.enumerated() {
                let seconds = Double(text.split(separator: " ").count) / 2.6
                try? store.appendSegments(meetingID: meetingID, track: track, [(start: t, end: t + seconds, text: text)],
                                          cursor: t + seconds)
                t += seconds + 0.8
                if !shot || index >= 4 { try? await Task.sleep(nanoseconds: UInt64(min(seconds, 4) * 1_000_000_000)) }
            }
        }
    }

    /// Setup step: start a short tap so macOS shows the System Audio Recording prompt.
    func requestSystemAudioPermission() async {
        guard #available(macOS 14.2, *) else { return }
        let tap = ProcessTap(target: .everythingExcept([]), ring: RingBuffer(capacity: 48_000))
        await Task.detached(priority: .userInitiated) {
            try? tap.start()
            usleep(1_000_000)
            tap.stop()
        }.value
    }

    var systemAudioVerified: Bool { UserDefaults.standard.bool(forKey: "MynahSystemAudioVerified") }
}
