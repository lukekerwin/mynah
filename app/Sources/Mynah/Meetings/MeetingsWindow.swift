import AppKit
import GRDB
import MynahCore
import SwiftUI

/// The Meetings window (an NSWindow so notifications and the menu can open it
/// from anywhere): meeting list + search, meeting detail, and the to-do list.
@MainActor
final class MeetingsWindowController {
    weak var controller: MeetingController?
    private var window: NSWindow?
    private var model: MeetingsModel?

    func show(focus meetingID: String? = nil) {
        guard let controller else { return }
        if window == nil {
            let model = MeetingsModel(controller: controller)
            let window = NSWindow(contentViewController: NSHostingController(rootView: MeetingsView(model: model)))
            window.title = "Meetings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 980, height: 660))
            window.minSize = NSSize(width: 720, height: 460)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MynahMeetings")
            window.center()
            self.window = window
            self.model = model
        }
        if let meetingID { model?.selection = .meeting(meetingID) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SidebarItem: Hashable {
    case todos
    case meeting(String)
}

@MainActor
final class MeetingsModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: SidebarItem? = .todos
    @Published var query = "" {
        didSet { runSearch() }
    }
    @Published private(set) var hits: [SearchHit] = []
    /// Transcript time to scroll to after picking a search result or to-do.
    @Published var focusTime: Double?

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

    func open(meetingID: String?, at time: Double?) {
        guard let meetingID else { return }
        focusTime = time
        selection = .meeting(meetingID)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        hits = q.isEmpty ? [] : ((try? store.search(q)) ?? [])
    }
}

struct MeetingsView: View {
    @ObservedObject var model: MeetingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("To-dos", systemImage: "checklist").tag(SidebarItem.todos)
                if model.query.isEmpty {
                    Section("Meetings") {
                        ForEach(model.meetings) { m in
                            MeetingRow(meeting: m).tag(SidebarItem.meeting(m.id))
                        }
                    }
                } else {
                    Section("Results") {
                        if model.hits.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                        ForEach(model.hits) { hit in
                            SearchHitRow(hit: hit, meeting: hit.meetingID.flatMap(model.meeting))
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(meetingID: hit.meetingID, at: hit.timeS) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
            .searchable(text: $model.query, placement: .sidebar, prompt: "Search meetings")
        } detail: {
            switch model.selection {
            case let .meeting(id):
                MeetingDetailView(model: MeetingDetailModel(meetingID: id, controller: model.controller),
                                  focusTime: $model.focusTime)
                    .id(id)
            default:
                ToDosView(model: ToDosModel(controller: model.controller), open: model.open)
            }
        }
    }
}

// MARK: rows

struct StatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .recording: ("Recording", .red)
        case .transcribing: ("Transcribing", .orange)
        case .queued: ("Waiting to summarize", .secondary)
        case .summarizing: ("Summarizing", .blue)
        case .done: ("Done", .green)
        case .failed: ("Failed", .red)
        case .noSpeech: ("No speech", .secondary)
        }
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let d = meeting.duration { Text("· \(Self.duration(d))") }
                Spacer()
                if meeting.status != .done { StatusBadge(status: meeting.status) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(1, m)) min"
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    let meeting: Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(meeting?.title ?? "To-do").font(.callout.weight(.medium)).lineLimit(1)
                if let t = hit.timeS { Text(TranscriptFormatter.timestamp(t)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var icon: String {
        switch hit.kind {
        case .transcript: return "text.quote"
        case .summary: return "doc.text"
        case .actionItem: return "checkmark.circle"
        }
    }
}

// MARK: meeting detail

@MainActor
final class MeetingDetailModel: ObservableObject {
    struct Content {
        var meeting: Meeting?
        var lines: [TranscriptLine] = []
        var summary: MeetingSummary?
        var items: [ActionItem] = []
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
                return Content(meeting: try Meeting.fetchOne(db, key: id),
                               lines: TranscriptFormatter.lines(segs),
                               summary: try MeetingSummary.fetchOne(db, key: id),
                               items: try ActionItem.filter(Column("meetingID") == id && Column("deleted") == false)
                                   .order(Column("status").desc, Column("timeS"), Column("id")).fetchAll(db))
            }
            .start(in: controller.store.db, scheduling: .immediate, onError: { _ in },
                   onChange: { [weak self] in self?.content = $0 })
    }
}

struct MeetingDetailView: View {
    @StateObject var model: MeetingDetailModel
    @Binding var focusTime: Double?
    @State private var title = ""
    @State private var confirmDelete = false

    init(model: MeetingDetailModel, focusTime: Binding<Double?>) {
        _model = StateObject(wrappedValue: model)
        _focusTime = focusTime
    }

    var body: some View {
        if let meeting = model.content.meeting {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(meeting)
                        if let s = model.content.summary { summary(s) }
                        itemsSection(meeting)
                        transcript
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: focusTime) { _, _ in scroll(proxy) }
                .onChange(of: model.content.lines.count) { _, _ in scroll(proxy) }
            }
            .onAppear { title = meeting.title }
            .onChange(of: meeting.title) { _, t in title = t }
            .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmDelete) {
                Button("Delete Meeting", role: .destructive) { model.controller.deleteMeeting(meeting.id) }
            } message: {
                Text("Its transcript, summary, audio and action items will be deleted.")
            }
        } else {
            Text("This meeting was deleted.").foregroundStyle(.secondary)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let t = focusTime, !model.content.lines.isEmpty else { return }
        let line = model.content.lines.last { $0.startS <= t + 0.5 } ?? model.content.lines[0]
        withAnimation { proxy.scrollTo(line.id, anchor: .center) }
        focusTime = nil
    }

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit { model.controller.rename(m.id, to: title) }
                Spacer()
                Menu {
                    Button("Delete Audio Now") { model.controller.deleteAudio(m.id) }
                        .disabled(m.audioDeletedAt != nil || m.status == .recording)
                    Button("Show Audio in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MeetingProcessor.directory(m.id)])
                    }
                    .disabled(m.audioDeletedAt != nil)
                    Divider()
                    Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 8) {
                Text(m.startedAt.formatted(date: .complete, time: .shortened))
                if let d = m.duration { Text("· \(MeetingRow.duration(d))") }
                Text("· \(m.appName)")
                StatusBadge(status: m.status)
                if m.status == .queued || m.status == .failed || m.status == .done {
                    Button(m.status == .done ? "Re-summarize" : m.status == .failed ? "Retry" : "Summarize Now") {
                        model.controller.summaries.summarizeNow(m.id)
                    }
                    .controlSize(.small)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            if m.status == .failed, let error = m.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func summary(_ s: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.tldr).font(.body).textSelection(.enabled)
            bullets("Key points", s.keyPoints)
            bullets("Decisions", s.decisions)
            bullets("Open questions", s.openQuestions)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder
    private func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(item).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func itemsSection(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Action items").font(.headline)
                Spacer()
                AddItemButton(store: model.controller.store, meetingID: m.id)
            }
            if model.content.items.isEmpty {
                Text(m.status == .done ? "No action items." : "Action items appear once the summary is ready.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.content.items) { item in
                ActionItemRow(item: item, store: model.controller.store, meetingTitle: nil) { t in focusTime = t }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcript").font(.headline)
            if model.content.lines.isEmpty {
                Text("No transcript yet.").font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.content.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(TranscriptFormatter.timestamp(line.startS))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                        Text(line.track == .you ? "You" : "Others")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(line.track == .you ? Color.accentColor : Color.primary)
                            .frame(width: 52, alignment: .leading)
                        Text(line.text).textSelection(.enabled)
                    }
                    .id(line.id)
                }
            }
        }
    }
}

// MARK: to-dos

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

struct ToDosView: View {
    @StateObject var model: ToDosModel
    let open: (String?, Double?) -> Void

    init(model: ToDosModel, open: @escaping (String?, Double?) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("To-dos").font(.title2.bold())
                Spacer()
                Picker("", selection: $model.mineOnly) {
                    Text("Mine").tag(true)
                    Text("All").tag(false)
                }
                .pickerStyle(.segmented).fixedSize()
                Picker("", selection: $model.showCompleted) {
                    Text("Open").tag(false)
                    Text("Completed").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                AddItemButton(store: model.controller.store, meetingID: nil)
            }
            if model.items.isEmpty {
                Spacer()
                Text(model.showCompleted ? "Nothing completed yet." : "Nothing to do. Action items from your meetings show up here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.items) { item in
                    ActionItemRow(item: item, store: model.controller.store,
                                  meetingTitle: item.meetingID.flatMap { model.titles[$0] }) { t in
                        open(item.meetingID, t)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
    }
}

struct ActionItemRow: View {
    let item: ActionItem
    let store: MeetingStore
    let meetingTitle: String?
    var jump: (Double?) -> Void
    @State private var editing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                try? store.setActionItem(id: item.id!, done: item.status != .done)
            } label: {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.status == .done ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .strikethrough(item.status == .done)
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                HStack(spacing: 8) {
                    Label(item.ownerLabel, systemImage: item.ownerKind == .me ? "person.fill" : "person")
                    if let due = item.dueDate { Label(due, systemImage: "calendar") }
                    if let meetingTitle {
                        Button {
                            jump(item.timeS)
                        } label: {
                            Text("\(meetingTitle)\(item.timeS.map { " @ " + TranscriptFormatter.timestamp($0) } ?? "")")
                                .lineLimit(1)
                        }
                        .buttonStyle(.link)
                    } else if let t = item.timeS {
                        Button(TranscriptFormatter.timestamp(t)) { jump(t) }.buttonStyle(.link)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .popover(isPresented: $editing) { EditItemView(item: item, store: store) { editing = false } }
        }
        .padding(.vertical, 3)
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
        Form {
            TextField("To-do", text: $text, axis: .vertical).lineLimit(1...4)
            Picker("Owner", selection: $owner) {
                Text("Me").tag(OwnerKind.me)
                Text("Someone else").tag(OwnerKind.person)
                Text("Unassigned").tag(OwnerKind.unassigned)
            }
            if owner == .person { TextField("Name", text: $ownerName) }
            Toggle("Due date", isOn: $hasDue)
            if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
            HStack {
                Button("Delete", role: .destructive) {
                    try? store.deleteActionItem(id: item.id!)
                    done()
                }
                Spacer()
                Button("Cancel") { done() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
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
    @State private var adding = false
    @State private var text = ""

    var body: some View {
        Button { adding = true } label: { Label("Add To-do", systemImage: "plus") }
            .popover(isPresented: $adding) {
                HStack {
                    TextField("New to-do", text: $text).frame(width: 260).onSubmit(add)
                    Button("Add", action: add).keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
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
