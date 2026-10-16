import Foundation
import MynahCore
import os

private let log = Logger(subsystem: "com.lukekerwin.mynah", category: "summary")

/// Writes summaries + action items in the background, one meeting at a time, only
/// while the Mac is idle and cool and no call is being recorded. A running job is
/// cancelled (and re-queued) if a call starts or the Mac heats up; dictation is
/// never blocked because the engine runs it between summary tokens.
@MainActor
final class SummaryRunner: ObservableObject {
    @Published private(set) var running: String?

    var isRecording: () -> Bool = { false }
    var isDictating: () -> Bool = { false }
    var onFinished: ((Meeting, Bool) -> Void)?

    private let store: MeetingStore
    private let engine: EngineClient
    private let settings: SettingsStore
    private var notBefore = Date()
    private var manualID: String?
    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?

    init(store: MeetingStore, engine: EngineClient, settings: SettingsStore) {
        self.store = store
        self.engine = engine
        self.settings = settings
    }

    func start() {
        // A crash mid-summary leaves "summarizing" behind.
        for m in (try? store.meetings(status: [.summarizing])) ?? [] {
            try? store.setStatus(m.id, .queued)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Called when a meeting finishes transcribing.
    func schedule(after delay: TimeInterval = 180) {
        notBefore = max(notBefore, Date().addingTimeInterval(delay))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) { [weak self] in self?.tick() }
    }

    /// "Summarize now" / "Retry": runs as soon as no call is being recorded.
    func summarizeNow(_ meetingID: String) {
        try? store.setStatus(meetingID, .queued)
        manualID = meetingID
        tick()
    }

    private func conditions(manual: Bool) -> SummaryEligibility.Conditions {
        .init(engineReady: engine.status == .ready, recording: isRecording(), dictating: isDictating(),
              thermalState: ProcessInfo.processInfo.thermalState.rawValue, manual: manual)
    }

    /// Re-evaluate: start a job if allowed, or interrupt the running one.
    func tick() {
        if let running {
            if SummaryEligibility.shouldInterrupt(conditions(manual: running == manualID)) {
                log.notice("interrupting summary of \(running, privacy: .public)")
                Task { await engine.cancel(jobID: running) }
            }
            return
        }
        guard let queued = try? store.meetings(status: [.queued]), !queued.isEmpty else { return }
        if let manualID, let m = queued.first(where: { $0.id == manualID }),
           SummaryEligibility.canStart(conditions(manual: true)) {
            run(m)
        } else if Date() >= notBefore, let m = queued.first, SummaryEligibility.canStart(conditions(manual: false)) {
            run(m)
        }
    }

    private func run(_ meeting: Meeting) {
        running = meeting.id
        try? store.setStatus(meeting.id, .summarizing)
        Task {
            defer {
                running = nil
                if manualID == meeting.id { manualID = nil }
            }
            do {
                let segments = try store.segments(meetingID: meeting.id)
                let m = settings.data.meetings
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd (EEEE)"
                let result = try await engine.summarize(
                    segments: TranscriptFormatter.engineSegments(segments), title: meeting.title,
                    myName: m.myName.isEmpty ? nil : m.myName,
                    model: m.summaryModel == "default" ? nil : m.summaryModel,
                    duration: meeting.duration ?? (segments.last?.endS ?? 0),
                    meetingDate: df.string(from: meeting.startedAt), jobID: meeting.id)
                try store.saveSummary(MeetingSummary(meetingID: meeting.id, model: result.model, tldr: result.tldr,
                                                     keyPoints: result.key_points, decisions: result.decisions,
                                                     openQuestions: result.open_questions),
                                      items: result.action_items)
                try store.setStatus(meeting.id, .done)
                log.notice("summarized \(meeting.id, privacy: .public) in \(result.llm_ms) ms")
                onFinished?(meeting, true)
            } catch let error as EngineError where error.isCancelled {
                try? store.setStatus(meeting.id, .queued)
                notBefore = Date().addingTimeInterval(120)
            } catch {
                log.error("summary failed: \(error.localizedDescription, privacy: .public)")
                try? store.setStatus(meeting.id, .failed, error: error.localizedDescription)
                onFinished?(meeting, false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.tick() }
        }
    }
}
