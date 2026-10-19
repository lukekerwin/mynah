import AppKit
import GRDB
import MynahCore
import SwiftUI

// MARK: - Meetings list

@MainActor
final class MeetingsModel: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var query = "" {
        didSet { runSearch() }
    }
    @Published private(set) var hits: [SearchHit] = []

    let controller: MeetingController
    var store: MeetingStore { controller.store }
    private var observation: AnyDatabaseCancellable?

    init(controller: MeetingController) {
        self.controller = controller
        observation = ValueObservation
            .tracking { db in try Meeting.order(Column("startedAt").desc).fetchAll(db) }
            .start(in: controller.store.db, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] in self?.meetings = $0 })
    }

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    /// Meetings grouped by calendar day, newest first.
    var days: [(label: String, meetings: [Meeting])] {
        let cal = Calendar.current
        var out: [(Date, [Meeting])] = []
        for m in meetings {
            let day = cal.startOfDay(for: m.startedAt)
            if let last = out.last, last.0 == day {
                out[out.count - 1].1.append(m)
            } else {
                out.append((day, [m]))
            }
        }
        return out.map { (Self.dayLabel($0.0), $0.1) }
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEE, MMMM d" : "MMMM d, yyyy"
        return f.string(from: day)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        hits = q.isEmpty ? [] : ((try? store.search(q)) ?? [])
    }
}

/// Where a meeting page should land: a meeting, optionally at a moment in its transcript.
struct MeetingFocus: Equatable {
    var meetingID: String
    var time: Double?
}

struct MeetingsPage: View {
    @ObservedObject var meetings: MeetingController
    @ObservedObject var settings: SettingsStore
    @Binding var focus: MeetingFocus?
    @Binding var page: Page
    @StateObject private var model: MeetingsModel

    init(meetings: MeetingController, settings: SettingsStore, focus: Binding<MeetingFocus?>, page: Binding<Page>) {
        self.meetings = meetings
        self.settings = settings
        _focus = focus
        _page = page
        _model = StateObject(wrappedValue: MeetingsModel(controller: meetings))
    }

    var body: some View {
        if let focus {
            MeetingDetailPage(meetingID: focus.meetingID, meetings: meetings, settings: settings, focusTime: focus.time) {
                self.focus = nil
            }
            .id(focus.meetingID)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageHeader(title: "Meetings", subtitle: "Calls Mynah recorded and wrote up, all on this Mac.")
                Spacer()
                if case .idle = meetings.state, settings.data.meetings.enabled {
                    RecordMenu(meetings: meetings)
                }
            }

            if !settings.data.meetings.enabled {
                EnableBanner(page: $page)
            }

            if let r = meetings.recording {
                LiveMeetingCard(meetings: meetings, settings: settings, recording: r) {
                    focus = MeetingFocus(meetingID: r.meetingID)
                }
            } else if case .asking = meetings.state {
                AskingCard(meetings: meetings)
            }

            if !model.meetings.isEmpty {
                SearchField(text: $model.query, prompt: "Search transcripts, notes and to-dos")
            }

            if !model.query.isEmpty {
                results
            } else if model.meetings.isEmpty {
                Card {
                    EmptyHint(symbol: "person.2.wave.2",
                              text: settings.data.meetings.enabled
                                  ? "No meetings yet. Mynah records the next Teams call, or pick an app under Record."
                                  : "Turn on meeting capture in Settings and your calls will show up here.")
                }
            } else {
                ForEach(model.days, id: \.label) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.label).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.inkTertiary)
                            .textCase(.uppercase).padding(.leading, 2)
                        Card(padding: 6) {
                            VStack(spacing: 0) {
                                ForEach(Array(day.meetings.enumerated()), id: \.element.id) { index, m in
                                    if index > 0 { RowDivider().padding(.horizontal, 10) }
                                    MeetingRow(meeting: m, live: meetings.recording?.meetingID == m.id,
                                               elapsed: meetings.elapsed) {
                                        focus = MeetingFocus(meetingID: m.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var results: some View {
        Card(padding: 6) {
            if model.hits.isEmpty {
                EmptyHint(symbol: "magnifyingglass", text: "Nothing matches “\(model.query)”.").padding(10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                        if index > 0 { RowDivider().padding(.horizontal, 10) }
                        SearchHitRow(hit: hit, meeting: hit.meetingID.flatMap(model.meeting)) {
                            if let id = hit.meetingID { focus = MeetingFocus(meetingID: id, time: hit.timeS) }
                        }
                    }
                }
            }
        }
    }
}

/// "Record ▾" with the apps currently playing audio.
private struct RecordMenu: View {
    @ObservedObject var meetings: MeetingController

    var body: some View {
        Menu {
            ForEach(meetings.audioApps()) { app in
                Button(app.name) { meetings.startManual(app) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "record.circle").font(.system(size: 11, weight: .semibold))
                Text("Record")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.accent)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct EnableBanner: View {
    @Binding var page: Page

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting capture is off").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("Mynah can notice Teams calls, record them, and write a transcript, summary and to-dos.")
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button("Turn on") { page = .settings }.buttonStyle(.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.tealSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.teal.opacity(0.3)))
    }
}

/// The card at the top of the list while a call is being recorded.
struct LiveMeetingCard: View {
    @ObservedObject var meetings: MeetingController
    @ObservedObject var settings: SettingsStore
    var recording: MeetingController.Recording
    var open: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LiveDot(color: Theme.coral)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(recording.title).font(Theme.heading).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(meetings.elapsed).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                }
                Text(note).font(Theme.caption).foregroundStyle(noteColor)
            }
            Spacer(minLength: 8)
            Button(recording.paused ? "Resume mic" : "Pause mic") { meetings.togglePauseMic() }.buttonStyle(.quiet)
            Button("Stop") { meetings.stop(discard: false) }.buttonStyle(.quiet)
            if let open { Button("Open") { open() }.buttonStyle(.accent) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.coralSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.coral.opacity(0.3)))
    }

    private var note: String {
        if meetings.permissionProblem { return "Can't hear the call. Allow System Audio Recording in System Settings." }
        if recording.paused { return "Your mic is paused. Everyone else is still being transcribed." }
        if meetings.teamsMuted == true, settings.data.meetings.teamsMuteDetection { return "You're muted in Teams, so only the others are being recorded." }
        if meetings.teamsMuteUnreadable {
            return Permissions.accessibilityGranted
                ? "Can't see Teams' mute button, so your mic is recorded even while you're muted."
                : "Allow Accessibility in System Settings so Mynah can skip your mic while you're muted in Teams."
        }
        return "Recording \(recording.app.name) and your mic. The transcript writes itself as the call goes on."
    }

    private var noteColor: Color { meetings.permissionProblem ? Theme.coral : Theme.inkSecondary }
}

private struct AskingCard: View {
    @ObservedObject var meetings: MeetingController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill").foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("A Teams call is in progress").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("Record and transcribe it on this Mac?").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button("Record this call") { meetings.recordAskedCall() }.buttonStyle(.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.amberSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.amber.opacity(0.35)))
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Theme.body)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

struct MeetingStatusBadge: View {
    var status: MeetingStatus

    var body: some View {
        switch status {
        case .recording: StatusBadge(kind: .warn, text: "Recording")
        case .transcribing: StatusBadge(kind: .busy, text: "Transcribing")
        case .queued: StatusBadge(kind: .busy, text: "Notes coming up")
        case .summarizing: StatusBadge(kind: .busy, text: "Writing notes")
        case .done: StatusBadge(kind: .ok, text: "Notes ready")
        case .failed: StatusBadge(kind: .warn, text: "Notes failed")
        case .noSpeech: StatusBadge(kind: .off, text: "No speech")
        }
    }
}

private struct MeetingRow: View {
    var meeting: Meeting
    var live: Bool
    var elapsed: String
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: live ? "record.circle" : appSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(live ? Theme.coral : Theme.inkTertiary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                        Text("·")
                        Text(live ? elapsed : (meeting.duration.map(Self.duration) ?? "In progress"))
                        Text("·")
                        Text(meeting.appName)
                    }
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 8)
                if meeting.status != .done { MeetingStatusBadge(status: meeting.status) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hover ? Theme.inkSecondary : Theme.inkTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.well : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var appSymbol: String {
        meeting.appBundleID.hasPrefix("com.microsoft.teams") ? "video" : "waveform.circle"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(1, m)) min"
    }
}

private struct SearchHitRow: View {
    var hit: SearchHit
    var meeting: Meeting?
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                    .frame(width: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(meeting?.title ?? "To-do").font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        if let t = hit.timeS {
                            Text(TranscriptFormatter.timestamp(t)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    Text(hit.snippet).font(Theme.caption).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.well : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var icon: String {
        switch hit.kind {
        case .transcript: return "text.quote"
        case .summary: return "doc.text"
        case .actionItem: return "checkmark.circle"
        }
    }
}

// MARK: - Meeting detail

@MainActor
final class MeetingDetailModel: ObservableObject {
    struct Content {
        var meeting: Meeting?
        var lines: [TranscriptLine] = []
        var summary: MeetingSummary?
        var items: [ActionItem] = []
        var speakers: [MeetingSpeaker] = []
        var people: [Person] = []
        var names: [String: String] = [:]
    }

    @Published private(set) var content = Content()
    let meetingID: String
    let controller: MeetingController
    private var observation: AnyDatabaseCancellable?

    init(meetingID: String, controller: MeetingController) {
        self.meetingID = meetingID
        self.controller = controller
        let id = meetingID
        observation = ValueObservation
            .tracking { db -> Content in
                let segs = try Segment.filter(Column("meetingID") == id && Column("hiddenReason") == nil)
                    .order(Column("startS"), Column("id")).fetchAll(db)
                let speakers = try MeetingSpeaker.filter(Column("meetingID") == id).order(Column("number")).fetchAll(db)
                let people = try Person.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
                let names = TranscriptFormatter.speakerNames(speakers, people: people)
                return Content(meeting: try Meeting.fetchOne(db, key: id),
                               lines: TranscriptFormatter.lines(segs, names: names),
                               summary: try MeetingSummary.fetchOne(db, key: id),
                               items: try ActionItem.filter(Column("meetingID") == id && Column("deleted") == false)
                                   .order(Column("status").desc, Column("timeS"), Column("id")).fetchAll(db),
                               speakers: speakers, people: people, names: names)
            }
            .start(in: controller.store.db, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] in self?.content = $0 })
    }

    var transcriptText: String {
        content.lines.map { "[\(TranscriptFormatter.timestamp($0.startS))] \($0.who): \($0.text)" }
            .joined(separator: "\n")
    }
}

struct MeetingDetailPage: View {
    @StateObject private var model: MeetingDetailModel
    @ObservedObject var meetings: MeetingController
    @ObservedObject var settings: SettingsStore
    var back: () -> Void
    @State private var focusTime: Double?
    @State private var title = ""
    @State private var renaming = false
    @FocusState private var titleFocused: Bool
    @State private var confirmDelete = false
    @State private var confirmDeleteAudio = false
    @State private var speakerFilter: Track?
    @State private var copied = false

    init(meetingID: String, meetings: MeetingController, settings: SettingsStore, focusTime: Double?,
         back: @escaping () -> Void) {
        // Built inside the autoclosure so it happens once per page, not on every parent
        // redraw (each model starts its observation with a full synchronous fetch, and
        // the parent redraws every second while a call is recording).
        _model = StateObject(wrappedValue: MeetingDetailModel(meetingID: meetingID, controller: meetings))
        self.meetings = meetings
        self.settings = settings
        _focusTime = State(initialValue: focusTime)
        self.back = back
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BackButton(title: "Meetings", action: back)
            if let m = model.content.meeting {
                header(m)
                if let r = meetings.recording, r.meetingID == m.id {
                    LiveMeetingCard(meetings: meetings, settings: settings, recording: r)
                } else if m.status != .done, m.status != .noSpeech {
                    progress(m)
                }
                if let s = model.content.summary { summary(s) }
                items(m)
                if meetings.findingSpeakers.contains(m.id) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Finding who spoke when…").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
                } else if !model.content.speakers.isEmpty {
                    SpeakersCard(meeting: m, content: model.content, meetings: meetings)
                }
                transcript(m)
            } else {
                Card { EmptyHint(symbol: "trash", text: "This meeting was deleted.") }
            }
        }
        .onAppear { title = model.content.meeting?.title ?? "" }
        .confirmationDialog("Delete “\(model.content.meeting?.title ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete meeting", role: .destructive) {
                meetings.deleteMeeting(model.meetingID)
                back()
            }
        } message: {
            Text("Its transcript, notes, audio and to-dos will be deleted.")
        }
        .confirmationDialog("Delete the audio of “\(model.content.meeting?.title ?? "")”?", isPresented: $confirmDeleteAudio) {
            Button("Delete audio", role: .destructive) { meetings.deleteAudio(model.meetingID) }
        } message: {
            Text("The transcript, notes and to-dos stay. Without the audio, Mynah can't find speakers in this meeting again.")
        }
    }

    private func beginRename(_ m: Meeting) {
        title = m.title
        renaming = true
    }

    private func commitRename(_ m: Meeting) {
        guard renaming else { return }
        renaming = false
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != m.title { meetings.rename(m.id, to: t) }
    }

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return f
    }()

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if renaming {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(Theme.title).foregroundStyle(Theme.ink)
                        .focused($titleFocused)
                        .onSubmit { commitRename(m) }
                        .onExitCommand { renaming = false }
                        .onChange(of: titleFocused) { _, focused in if !focused { commitRename(m) } }
                        .onAppear { titleFocused = true }
                } else {
                    Text(m.title).font(Theme.title).foregroundStyle(Theme.ink).lineLimit(2)
                        .onTapGesture { beginRename(m) }
                        .help("Click to rename")
                }
                Spacer()
                Menu {
                    Button("Rename") { beginRename(m) }
                    if m.status == .queued || m.status == .failed || m.status == .done {
                        Button(m.status == .done ? "Write notes again" : m.status == .failed ? "Retry notes" : "Write notes now") {
                            meetings.summaries.summarizeNow(m.id)
                        }
                    }
                    Button("Copy transcript") { copy() }.disabled(model.content.lines.isEmpty)
                    Button(model.content.speakers.isEmpty ? "Find speakers" : "Find speakers again") { meetings.findSpeakers(m.id) }
                        .disabled(m.audioDeletedAt != nil || m.status == .recording || m.status == .transcribing
                            || meetings.findingSpeakers.contains(m.id))
                    Divider()
                    Button("Show audio in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MeetingProcessor.directory(m.id)])
                    }
                    .disabled(m.audioDeletedAt != nil)
                    Button("Delete audio now…") { confirmDeleteAudio = true }
                        .disabled(m.audioDeletedAt != nil || m.status == .recording)
                    Divider()
                    Button("Delete meeting…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().strokeBorder(Theme.border))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            HStack(spacing: 8) {
                Text(Self.longDate.string(from: m.startedAt))
                if let d = m.duration {
                    Text("·")
                    Text(MeetingRow.duration(d))
                }
                Text("·")
                Text(m.appName)
                MeetingStatusBadge(status: m.status).padding(.leading, 4)
            }
            .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
        }
    }

    @ViewBuilder private func progress(_ m: Meeting) -> some View {
        let (text, detail): (String, String) = {
            switch m.status {
            case .transcribing: return ("Finishing the transcript", "The last few minutes are still being written down.")
            case .queued: return ("Notes are on the way", "Mynah writes the summary once the engine is free. It won't interrupt you while you dictate.")
            case .summarizing: return ("Writing the notes", "Reading the whole transcript to pick out decisions and to-dos.")
            case .failed: return ("Couldn't write the notes", m.error ?? "Something went wrong.")
            default: return ("Working", "")
            }
        }()
        HStack(spacing: 12) {
            if m.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.caption).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if m.status == .queued || m.status == .failed {
                Button(m.status == .failed ? "Retry" : "Write now") { meetings.summaries.summarizeNow(m.id) }.buttonStyle(.quiet)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }

    private func summary(_ s: MeetingSummary) -> some View {
        Card(title: "Notes", subtitle: "Written by \(s.model) on this Mac.") {
            VStack(alignment: .leading, spacing: 16) {
                Text(s.tldr).font(Theme.display(15, weight: .medium)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                bullets("Key points", s.keyPoints, symbol: "circle.fill", size: 6)
                bullets("Decisions", s.decisions, symbol: "checkmark.circle.fill", size: 11)
                bullets("Open questions", s.openQuestions, symbol: "questionmark.circle.fill", size: 11)
            }
        }
    }

    @ViewBuilder private func bullets(_ title: String, _ items: [String], symbol: String, size: CGFloat) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.inkTertiary).textCase(.uppercase)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol).font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.teal)
                            .frame(width: 12)
                        Text(item).font(Theme.body).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func items(_ m: Meeting) -> some View {
        Card(title: "To-dos") {
            VStack(spacing: 0) {
                if model.content.items.isEmpty {
                    EmptyHint(symbol: "checklist",
                              text: m.status == .done ? "No to-dos came out of this one." : "To-dos appear once the notes are written.")
                }
                ForEach(Array(model.content.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    ActionItemRow(item: item, store: meetings.store, meetingTitle: nil) { t in focusTime = t }
                }
                HStack {
                    Spacer()
                    AddItemButton(store: meetings.store, meetingID: m.id)
                }
                .padding(.top, 10)
            }
        }
    }

    private func transcript(_ m: Meeting) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Transcript").font(Theme.heading).foregroundStyle(Theme.ink)
                    Spacer()
                    if !model.content.lines.isEmpty {
                        SpeakerFilter(selection: $speakerFilter)
                        Button(copied ? "Copied" : "Copy") { copy() }.buttonStyle(.quiet)
                    }
                }
                if model.content.lines.isEmpty {
                    EmptyHint(symbol: "text.quote", text: m.status == .recording ? "Nothing said yet." : "No transcript for this meeting.")
                } else {
                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(visibleLines) { line in
                                TranscriptLineRow(line: line, highlighted: isFocused(line), meetingID: m.id,
                                                  personID: model.content.speakers.first { $0.label == line.speakerLabel }?.personID,
                                                  people: model.content.people, meetings: meetings).id(line.id)
                            }
                        }
                        .onAppear { scroll(proxy) }
                        .onChange(of: focusTime) { _, _ in scroll(proxy) }
                    }
                }
            }
        }
    }

    private var visibleLines: [TranscriptLine] {
        guard let speakerFilter else { return model.content.lines }
        return model.content.lines.filter { $0.track == speakerFilter }
    }

    private func isFocused(_ line: TranscriptLine) -> Bool {
        guard let t = focusTime else { return false }
        return focusedLine(for: t)?.id == line.id
    }

    private func focusedLine(for t: Double) -> TranscriptLine? {
        model.content.lines.last { $0.startS <= t + 0.5 } ?? model.content.lines.first
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let t = focusTime, let line = focusedLine(for: t) else { return }
        speakerFilter = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation { proxy.scrollTo(line.id, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { focusTime = nil }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.transcriptText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

struct BackButton: View {
    var title: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                Text(title).font(Theme.caption.weight(.semibold))
            }
            .foregroundStyle(hover ? Theme.ink : Theme.inkSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SpeakerFilter: View {
    @Binding var selection: Track?

    var body: some View {
        HStack(spacing: 2) {
            option(nil, "All")
            option(.you, "You")
            option(.others, "Others")
        }
        .padding(2)
        .background(Capsule().fill(Theme.well))
        .overlay(Capsule().strokeBorder(Theme.border))
    }

    private func option(_ track: Track?, _ label: String) -> some View {
        let on = selection == track
        return Button { withAnimation(.easeOut(duration: 0.15)) { selection = track } } label: {
            Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Theme.ink : Theme.inkSecondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(on ? Theme.card : .clear).shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TranscriptLineRow: View {
    var line: TranscriptLine
    var highlighted: Bool
    var meetingID: String
    var personID: String?
    var people: [Person]
    let meetings: MeetingController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                if let label = line.speakerLabel {
                    SpeakerNameMenu(meetingID: meetingID, label: label, current: line.speakerName ?? "",
                                    personID: personID, people: people, meetings: meetings) {
                        SpeakerChip(track: line.track, name: line.speakerName)
                    }
                    .help("Who is this?")
                } else {
                    SpeakerChip(track: line.track, name: line.speakerName)
                }
                Text(TranscriptFormatter.timestamp(line.startS))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.inkTertiary)
            }
            .frame(width: 84, alignment: .trailing)
            Text(line.text).font(Theme.body).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(highlighted ? Theme.tealSoft : .clear))
        .animation(.easeOut(duration: 0.3), value: highlighted)
    }
}

// MARK: - Speakers

/// The voices found in "Others", each with a menu to say who it is.
private struct SpeakersCard: View {
    var meeting: Meeting
    var content: MeetingDetailModel.Content
    @ObservedObject var meetings: MeetingController

    var body: some View {
        Card(title: "Speakers", subtitle: "Name a voice once and Mynah recognizes it in later calls.") {
            VStack(spacing: 0) {
                ForEach(Array(content.speakers.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { RowDivider() }
                    row(s)
                }
                if notesOutdated {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.teal)
                        Text("Names changed after the notes were written.").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Button("Write notes again") { meetings.summaries.summarizeNow(meeting.id) }.buttonStyle(.quiet)
                    }
                    .padding(.top, 10)
                }
            }
        }
    }

    private func row(_ s: MeetingSpeaker) -> some View {
        let name = content.names[s.label] ?? s.placeholderName
        let known = s.personID != nil
        return HStack(spacing: 12) {
            Text(known ? String(name.prefix(1)).uppercased() : "\(s.number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(known ? Theme.teal : Theme.inkSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(known ? Theme.tealSoft : Theme.well))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail(s)).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            SpeakerNameMenu(meetingID: meeting.id, label: s.label, current: name, personID: s.personID,
                            people: content.people, meetings: meetings) {
                Text(known ? "Change" : "Name…").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.teal)
            }
        }
        .padding(.vertical, 8)
    }

    private func detail(_ s: MeetingSpeaker) -> String {
        let talk = s.speechS < 60 ? "\(Int(s.speechS)) s" : "\(Int((s.speechS / 60).rounded())) min"
        let how: String
        if s.personID != nil {
            how = s.matchScore != nil ? "recognized by voice" : "named by you"
        } else if s.speechS < SpeakerMatching.minSpeechS {
            how = "too little speech to learn their voice"
        } else {
            how = s.namedAt != nil ? "unnamed" : "not recognized"
        }
        return "\(talk) of speech · \(how)"
    }

    private var notesOutdated: Bool {
        guard let summary = content.summary, meeting.status == .done else { return false }
        return content.speakers.contains { ($0.namedAt ?? .distantPast) > summary.createdAt }
    }
}

/// "Who is Speaker 2?": pick someone already named, add a new person, or clear the name.
struct SpeakerNameMenu<Label: View>: View {
    var meetingID: String
    var label: String
    var current: String
    var personID: String?
    var people: [Person]
    let meetings: MeetingController
    @ViewBuilder var content: () -> Label
    @State private var asking = false
    @State private var newName = ""

    var body: some View {
        Menu {
            ForEach(people) { p in
                Button { meetings.nameSpeaker(meetingID: meetingID, label: label, personID: p.id) } label: {
                    if p.id == personID { SwiftUI.Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            if !people.isEmpty { Divider() }
            Button("New person…") {
                newName = ""
                asking = true
            }
            if personID != nil {
                Button("Clear name") { meetings.nameSpeaker(meetingID: meetingID, label: label, personID: nil) }
            }
        } label: {
            content()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .alert("Who is \(current)?", isPresented: $asking) {
            TextField("Name", text: $newName)
            Button("Save") { meetings.nameSpeaker(meetingID: meetingID, label: label, newName: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mynah will recognize their voice in later calls.")
        }
    }
}

// MARK: - To-dos

@MainActor
final class ToDosModel: ObservableObject {
    @Published var mineOnly = true { didSet { observe() } }
    @Published var showCompleted = false { didSet { observe() } }
    @Published private(set) var items: [ActionItem] = []
    @Published private(set) var titles: [String: String] = [:]

    let controller: MeetingController
    private var observation: AnyDatabaseCancellable?

    init(controller: MeetingController) {
        self.controller = controller
        observe()
    }

    private func observe() {
        let mine = mineOnly
        let status = showCompleted ? ItemStatus.done : .open
        observation = ValueObservation
            .tracking { db -> ([ActionItem], [String: String]) in
                var r = ActionItem.filter(Column("deleted") == false && Column("status") == status.rawValue)
                if mine { r = r.filter(Column("ownerKind") == OwnerKind.me.rawValue) }
                let items = try r.order(Column("dueDate") == nil, Column("dueDate"), Column("createdAt").desc).fetchAll(db)
                let rows = try Row.fetchAll(db, sql: "SELECT id, title FROM meeting")
                return (items, Dictionary(rows.map { ($0["id"], $0["title"]) }, uniquingKeysWith: { a, _ in a }))
            }
            .start(in: controller.store.db, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] in
                       self?.items = $0.0
                       self?.titles = $0.1
                   })
    }
}

struct ToDosPage: View {
    @StateObject private var model: ToDosModel
    var open: (MeetingFocus) -> Void

    init(meetings: MeetingController, open: @escaping (MeetingFocus) -> Void) {
        _model = StateObject(wrappedValue: ToDosModel(controller: meetings))
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageHeader(title: "To-dos", subtitle: "Pulled out of your meeting notes, plus anything you add yourself.")
                Spacer()
                AddItemButton(store: model.controller.store, meetingID: nil, prominent: true)
            }
            HStack(spacing: 10) {
                Segmented(options: [(true, "Mine"), (false, "Everyone's")], selection: $model.mineOnly)
                Segmented(options: [(false, "Open"), (true, "Done")], selection: $model.showCompleted)
                Spacer()
            }
            Card(padding: 10) {
                if model.items.isEmpty {
                    EmptyHint(symbol: "checklist",
                              text: model.showCompleted ? "Nothing ticked off yet." : "Nothing to do. To-dos from your meetings land here.")
                        .padding(6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { RowDivider() }
                            ActionItemRow(item: item, store: model.controller.store,
                                          meetingTitle: item.meetingID.flatMap { model.titles[$0] }) { t in
                                if let id = item.meetingID { open(MeetingFocus(meetingID: id, time: t)) }
                            }
                            .padding(.horizontal, 6)
                        }
                    }
                }
            }
        }
    }
}

/// Two or three options in a pill, like the speaker filter.
struct Segmented<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = selection == value
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = value } } label: {
                    Text(label).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(on ? Theme.ink : Theme.inkSecondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(on ? Theme.card : .clear).shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.well))
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

struct ActionItemRow: View {
    let item: ActionItem
    let store: MeetingStore
    let meetingTitle: String?
    var jump: (Double?) -> Void
    @State private var editing = false
    @State private var hover = false

    private var done: Bool { item.status == .done }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                try? store.setActionItem(id: item.id!, done: !done)
            } label: {
                ZStack {
                    Circle().fill(done ? AnyShapeStyle(Theme.tealGradient) : AnyShapeStyle(Color.clear))
                        .overlay(Circle().strokeBorder(done ? Color.clear : Theme.borderStrong, lineWidth: 1.5))
                    if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(Theme.body).strikethrough(done)
                    .foregroundStyle(done ? Theme.inkTertiary : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(item.ownerLabel, systemImage: item.ownerKind == .me ? "person.fill" : "person")
                    if let due = item.dueDate.flatMap(DueDate.init) {
                        Label(due.label, systemImage: "calendar")
                            .foregroundStyle(due.overdue && !done ? Theme.coral : Theme.inkSecondary)
                    }
                    if let meetingTitle {
                        Button { jump(item.timeS) } label: {
                            Label(meetingTitle, systemImage: "person.2.wave.2").lineLimit(1)
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.teal)
                    } else if let t = item.timeS {
                        Button { jump(t) } label: { Label(TranscriptFormatter.timestamp(t), systemImage: "text.quote") }
                            .buttonStyle(.plain).foregroundStyle(Theme.teal)
                    }
                }
                .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer(minLength: 0)
            Button { editing = true } label: {
                Image(systemName: "pencil").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.well))
            }
            .buttonStyle(.plain)
            .opacity(hover || editing ? 1 : 0)
            .popover(isPresented: $editing) { EditItemView(item: item, store: store) { editing = false } }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit…") { editing = true }
            Button("Delete", role: .destructive) { try? store.deleteActionItem(id: item.id!) }
        }
    }
}

struct EditItemView: View {
    let item: ActionItem
    let store: MeetingStore
    var done: () -> Void
    @State private var text = ""
    @State private var owner = OwnerKind.me
    @State private var ownerName = ""
    @State private var hasDue = false
    @State private var due = Date()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit to-do").font(Theme.heading).foregroundStyle(Theme.ink)
            TextField("To-do", text: $text, axis: .vertical).lineLimit(1...4)
                .textFieldStyle(.plain).font(Theme.body)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.border))
            HStack(spacing: 10) {
                Text("Owner").font(Theme.caption).foregroundStyle(Theme.inkSecondary).frame(width: 60, alignment: .leading)
                PickerField(selection: $owner) {
                    Text("Me").tag(OwnerKind.me)
                    Text("Someone else").tag(OwnerKind.person)
                    Text("Unassigned").tag(OwnerKind.unassigned)
                }
            }
            if owner == .person {
                HStack(spacing: 10) {
                    Text("Name").font(Theme.caption).foregroundStyle(Theme.inkSecondary).frame(width: 60, alignment: .leading)
                    TextField("Name", text: $ownerName).textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 10) {
                Toggle("Due date", isOn: $hasDue).toggleStyle(TealToggleStyle()).font(Theme.caption).frame(width: 110)
                if hasDue { DatePicker("", selection: $due, displayedComponents: .date).labelsHidden() }
                Spacer()
            }
            HStack {
                Button("Delete") {
                    try? store.deleteActionItem(id: item.id!)
                    done()
                }
                .buttonStyle(.quiet).foregroundStyle(Theme.coral)
                Spacer()
                Button("Cancel") { done() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.accent).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(Theme.canvas)
        .onAppear {
            text = item.text
            owner = item.ownerKind
            ownerName = item.ownerName ?? ""
            if let d = item.dueDate, let date = Self.dayFormat.date(from: d) {
                hasDue = true
                due = date
            }
        }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = owner == .person && ownerName.trimmingCharacters(in: .whitespaces).isEmpty ? .unassigned : owner
        let name = kind == .person ? ownerName.trimmingCharacters(in: .whitespaces) : nil
        let dueText = hasDue ? Self.dayFormat.string(from: due) : nil
        try? store.editActionItem(id: item.id!) {
            $0.text = t
            $0.ownerKind = kind
            $0.ownerName = name
            $0.dueDate = dueText
        }
        done()
    }
}

struct AddItemButton: View {
    let store: MeetingStore
    let meetingID: String?
    var prominent = false
    @State private var adding = false
    @State private var text = ""

    var body: some View {
        Button { adding = true } label: { Label("New to-do", systemImage: "plus") }
            .buttonStyle(AccentButtonStyle(prominent: prominent))
            .popover(isPresented: $adding) {
                HStack(spacing: 8) {
                    TextField("What needs doing?", text: $text)
                        .textFieldStyle(.plain).font(Theme.body).frame(width: 260)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.well))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.border))
                        .onSubmit(add)
                    Button("Add", action: add).buttonStyle(.accent).keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(14)
                .background(Theme.canvas)
            }
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        _ = try? store.addActionItem(text: t, meetingID: meetingID)
        text = ""
        adding = false
    }
}

/// A to-do's "YYYY-MM-DD" due date as people read it: "Today", "Tomorrow",
/// "Yesterday", else "Mon, Oct 20" (with the year when it isn't this year).
struct DueDate {
    var label: String
    var overdue: Bool

    init?(_ iso: String) {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? 0
        overdue = days < 0
        switch days {
        case 0: label = "Today"
        case 1: label = "Tomorrow"
        case -1: label = "Yesterday"
        default:
            let sameYear = cal.component(.year, from: date) == cal.component(.year, from: today)
            label = sameYear ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
                : date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}
