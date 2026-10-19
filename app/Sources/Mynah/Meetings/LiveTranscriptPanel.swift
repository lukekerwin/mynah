import AppKit
import Combine
import GRDB
import MynahCore
import SwiftUI

/// What the live panel shows: the lines transcribed so far for the call being recorded.
@MainActor
final class LiveTranscriptModel: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var title = ""
    @Published var lines: [TranscriptLine] = []
    /// Shows a shrink/grow animation between the pill and the card.
    @Published var visible = false
}

/// A compact pill that hugs the right edge of the screen while a meeting is being
/// recorded. Hover over it and it opens into a card showing the transcript as it is
/// written: who said what, a few seconds after they said it. Pin it to keep it open.
@MainActor
final class LiveTranscriptController {
    static let pillSize = CGSize(width: 92, height: 34)
    static let cardSize = CGSize(width: 372, height: 540)
    /// Gap between the pill/card and the screen edge.
    private static let inset: CGFloat = 12

    let model = LiveTranscriptModel()
    private let panel: NSPanel
    private weak var meetings: MeetingController?
    private let settings: SettingsStore
    private var observation: AnyDatabaseCancellable?
    private var observedMeeting: String?
    private var subscriptions = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    /// Set by Close: hovering doesn't reopen the card until the mouse has left it.
    private var ignoreHover = false
    private var orderOutWork: DispatchWorkItem?

    init(meetings: MeetingController, settings: SettingsStore) {
        self.meetings = meetings
        self.settings = settings
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.pillSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none

        let view = LiveTranscriptView(model: model, meetings: meetings, settings: settings) { [weak self] action in
            self?.handle(action)
        }
        panel.contentView = NSHostingView(rootView: view)

        meetings.$state
            .combineLatest(settings.$data.map(\.meetings.liveTranscript).removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, enabled in self?.apply(state, enabled: enabled) }
            .store(in: &subscriptions)
    }

    enum Action { case open, close, pin }

    /// Previews: open the card and keep it open.
    func pinOpen() {
        model.pinned = true
        expand()
    }

    private func handle(_ action: Action) {
        switch action {
        case .open: expand()
        case .close:
            model.pinned = false
            ignoreHover = true
            collapse()
        case .pin:
            model.pinned.toggle()
            if model.pinned { expand() }
        }
    }

    private func apply(_ state: MeetingController.State, enabled: Bool) {
        guard enabled, case let .recording(r) = state else {
            hide()
            return
        }
        model.title = r.title
        guard observedMeeting != r.meetingID else { return }
        observedMeeting = r.meetingID
        model.lines = []
        model.pinned = false
        let id = r.meetingID
        observation = ValueObservation
            .tracking { db in
                try Segment.filter(Column("meetingID") == id && Column("hiddenReason") == nil)
                    .order(Column("startS"), Column("id")).fetchAll(db)
            }
            .start(in: meetings!.store.db, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] in self?.model.lines = TranscriptFormatter.lines($0) })
        show()
    }

    // MARK: showing

    private func show() {
        orderOutWork?.cancel()
        model.expanded = false
        panel.setFrame(frame(expanded: false), display: true)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.visible = true }
        // Hover is detected by polling the mouse: tracking areas in a non-activating
        // panel are unreliable while another app is frontmost.
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMouse() }
        }
    }

    private func hide() {
        guard observedMeeting != nil else { return }
        observedMeeting = nil
        observation = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        collapseWork?.cancel()
        withAnimation(.easeIn(duration: 0.18)) { model.visible = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel.orderOut(nil)
            self.model.expanded = false
            self.model.pinned = false
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func pollMouse() {
        let inside = NSMouseInRect(NSEvent.mouseLocation, panel.frame.insetBy(dx: -6, dy: -6), false)
        if ignoreHover {
            if !inside { ignoreHover = false }
            return
        }
        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if !model.expanded { expand() }
        } else if model.expanded, !model.pinned, collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func expand() {
        collapseWork?.cancel()
        collapseWork = nil
        guard !model.expanded else { return }
        panel.setFrame(frame(expanded: true), display: true)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.expanded = true }
    }

    private func collapse() {
        collapseWork = nil
        guard model.expanded else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.panel.setFrame(self.frame(expanded: false), display: true)
        }
    }

    /// Right edge of the screen the mouse is on, vertically centred. The pill and the
    /// card share the same top-right corner region so growing feels anchored.
    private func frame(expanded: Bool) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = expanded ? Self.cardSize : Self.pillSize
        let height = min(size.height, visible.height - 2 * Self.inset)
        let x = visible.maxX - size.width - Self.inset
        let y = (visible.midY - height / 2).rounded()
        return NSRect(x: x, y: y, width: size.width, height: height)
    }
}

// MARK: - View

struct LiveTranscriptView: View {
    @ObservedObject var model: LiveTranscriptModel
    @ObservedObject var meetings: MeetingController
    @ObservedObject var settings: SettingsStore
    var act: (LiveTranscriptController.Action) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            if model.expanded {
                card
                    .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity),
                                            removal: .scale(scale: 0.7, anchor: .trailing).combined(with: .opacity)))
            } else {
                pill
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .scaleEffect(model.visible ? 1 : 0.8, anchor: .trailing)
        .opacity(model.visible ? 1 : 0)
    }

    // The closed state: a dark capsule with the live dot and the call timer.
    private var pill: some View {
        HStack(spacing: 8) {
            LiveDot(color: Theme.coral)
            Text(meetings.elapsed.isEmpty ? "0:00" : meetings.elapsed)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.pillText)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(
            Capsule().fill(Theme.pill)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .shadow(color: Theme.coral.opacity(0.25), radius: 12)
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .padding(1)
        .accessibilityLabel("Live transcript, \(meetings.elapsed)")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            transcript
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            footer.padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: LiveTranscriptController.cardSize.width - 2, height: LiveTranscriptController.cardSize.height - 2)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.pill)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .padding(1)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            LiveDot(color: Theme.coral)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title.isEmpty ? "Recording" : model.title)
                    .font(Theme.display(14, weight: .semibold)).foregroundStyle(Theme.pillText).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meetings.elapsed).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.pillText.opacity(0.6))
                    if let note = statusNote {
                        Text("·").foregroundStyle(Theme.pillText.opacity(0.4))
                        Text(note).font(Theme.caption).foregroundStyle(Theme.amber).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", active: model.pinned,
                       help: model.pinned ? "Unpin" : "Keep open") { act(.pin) }
            IconButton(symbol: "xmark", help: "Close") { act(.close) }
        }
    }

    private var statusNote: String? {
        guard let r = meetings.recording else { return nil }
        if meetings.permissionProblem { return "can't hear the call" }
        if r.paused { return "mic paused" }
        if meetings.teamsMuted == true, settings.data.meetings.teamsMuteDetection { return "muted in Teams" }
        if meetings.teamsMuteUnreadable { return "can't see Teams mute" }
        return nil
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.lines.isEmpty {
                        listening
                    } else {
                        ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                            LiveLine(line: line, latest: index == model.lines.count - 1)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 2).id("end")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Waveform(levels: LiveTranscriptView.rest, tint: Theme.pillText.opacity(0.35),
                         barWidth: 3, spacing: 3, minHeight: 3, maxHeight: 14)
                Text("Listening").font(Theme.body.weight(.medium)).foregroundStyle(Theme.pillText.opacity(0.8))
            }
            Text("Words show up here a few seconds after they're said. You and everyone else are kept apart.")
                .font(Theme.caption).foregroundStyle(Theme.pillText.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private static let rest: [Float] = (0..<10).map { i in 0.15 + 0.5 * abs(sinf(Float(i) * 0.9)) }

    private var footer: some View {
        HStack(spacing: 8) {
            if let r = meetings.recording {
                PillButton(symbol: r.paused ? "mic.fill" : "mic.slash", title: r.paused ? "Resume mic" : "Pause mic") {
                    meetings.togglePauseMic()
                }
                PillButton(symbol: "stop.fill", title: "Stop", tint: Theme.coral) { meetings.stop(discard: false) }
                Spacer()
                PillButton(symbol: "arrow.up.forward.square", title: "Open") { meetings.showMeetings(focus: r.meetingID) }
            }
        }
    }
}

/// One line in the live card: who, when, and what. The newest line is brightest so
/// your eye lands where the words are arriving.
private struct LiveLine: View {
    var line: TranscriptLine
    var latest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SpeakerChip(track: line.track, onDark: true)
                Text(TranscriptFormatter.timestamp(line.startS))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.pillText.opacity(0.4))
            }
            Text(line.text)
                .font(Theme.body)
                .foregroundStyle(Theme.pillText.opacity(latest ? 0.95 : 0.7))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "You" in teal, "Others" in a neutral tone, so the two sides of a call read at a glance.
struct SpeakerChip: View {
    var track: Track
    var onDark = false

    var body: some View {
        let you = track == .you
        Text(you ? "You" : "Others")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(you ? Theme.teal : (onDark ? Theme.pillText.opacity(0.8) : Theme.inkSecondary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(you ? Theme.tealSoft : (onDark ? Color.white.opacity(0.1) : Theme.well)))
            .overlay(Capsule().strokeBorder(you ? Theme.teal.opacity(0.3) : (onDark ? Color.white.opacity(0.08) : Theme.border)))
    }
}

/// The "live" indicator: a dot with a soft breathing ring.
struct LiveDot: View {
    var color: Color
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.3)).frame(width: 14, height: 14)
                .scaleEffect(on ? 1.15 : 0.7).opacity(on ? 0 : 1)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}

private struct IconButton: View {
    var symbol: String
    var active = false
    var help: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Theme.teal : Theme.pillText.opacity(hover ? 0.9 : 0.55))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

private struct PillButton: View {
    var symbol: String
    var title: String
    var tint: Color = Theme.pillText
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(tint.opacity(hover ? 1 : 0.85))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
