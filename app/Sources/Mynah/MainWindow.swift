import ServiceManagement
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, history, meetings, todos, dictionary, snippets, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .meetings: return "Meetings"
        case .todos: return "To-dos"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .history: return "clock"
        case .meetings: return "person.2.wave.2"
        case .todos: return "checklist"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

/// Where to land when the window opens: a page, and for Meetings optionally one meeting.
struct PageRequest {
    var page: Page
    var meeting: MeetingFocus?
}

/// Owns the single app window and lets any part of the app open it on a page.
@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func show(_ page: Page, meeting: MeetingFocus? = nil, controller: AppController) {
        if window == nil {
            let view = MainWindow(controller: controller, settings: controller.settings,
                                  engine: controller.engine, history: controller.history)
            let host = NSHostingController(rootView: view)
            host.safeAreaRegions = []
            let window = NSWindow(contentViewController: host)
            window.title = "Mynah"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 620))
            // MYNAH_UI_SIZE=WxH: a taller window for screenshots of long pages.
            if let size = ProcessInfo.processInfo.environment["MYNAH_UI_SIZE"]?.split(separator: "x"), size.count == 2,
               let w = Double(size[0]), let h = Double(size[1]) {
                window.setContentSize(NSSize(width: w, height: h))
            } else {
                window.setFrameAutosaveName("MynahMain")
            }
            window.center()
            self.window = window
        }
        NotificationCenter.default.post(name: .mynahShowPage, object: PageRequest(page: page, meeting: meeting))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The app window: a sidebar on the left, one page on the right. Replaces the
/// tabbed preferences window so Mynah feels like a product, not a System Settings pane.
struct MainWindow: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    @ObservedObject var history: HistoryStore
    @State private var page: Page = .home
    @State private var meeting: MeetingFocus?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page, engine: engine, meetings: controller.meetings)
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                pageView
                    .padding(.horizontal, 32)
                    .padding(.top, 40)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.canvas)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.canvas)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .mynahShowPage)) { note in
            guard let request = note.object as? PageRequest else { return }
            page = request.page
            if request.page == .meetings { meeting = request.meeting }
        }
    }

    @ViewBuilder private var pageView: some View {
        switch page {
        case .home: HomePage(controller: controller, settings: settings, engine: engine, history: history, page: $page)
        case .history: HistoryPage(history: history)
        case .meetings:
            if let meetings = controller.meetings {
                MeetingsPage(meetings: meetings, settings: settings, focus: $meeting, page: $page)
            } else {
                MeetingsUnavailable()
            }
        case .todos:
            if let meetings = controller.meetings {
                ToDosPage(meetings: meetings) { focus in
                    meeting = focus
                    page = .meetings
                }
            } else {
                MeetingsUnavailable()
            }
        case .dictionary: DictionaryPage(settings: settings)
        case .snippets: SnippetsPage(settings: settings)
        case .settings: SettingsPage(controller: controller, settings: settings, engine: engine)
        case .about: AboutPage(updater: controller.updater)
        }
    }
}

private struct MeetingsUnavailable: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Meetings")
            Card {
                EmptyHint(symbol: "exclamationmark.triangle",
                          text: "Mynah couldn't open its meetings database. Check the engine log and restart the app.")
            }
        }
    }
}

extension Notification.Name {
    static let mynahShowPage = Notification.Name("mynah.showPage")
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var page: Page
    @ObservedObject var engine: EngineClient
    let meetings: MeetingController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("Mynah").font(Theme.display(17, weight: .bold)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 18)
            .padding(.top, 44)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(Page.allCases.filter { $0 != .about }) { item in
                    SidebarItem(page: item, selected: page == item, meetings: item == .meetings ? meetings : nil) { page = item }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                SidebarItem(page: .about, selected: page == .about) { page = .about }
                    .padding(.horizontal, 10)
                EngineStatusBadge(engine: engine).padding(.horizontal, 20)
            }
            .padding(.bottom, 16)
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebar)
    }
}

private struct SidebarItem: View {
    var page: Page
    var selected: Bool
    var meetings: MeetingController?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.teal : Theme.inkSecondary)
                Text(page.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                Spacer()
                if let meetings { SidebarLive(meetings: meetings) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.card : (hover ? Theme.border : Color.clear))
                    .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 1, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A red dot next to "Meetings" while a call is being recorded.
private struct SidebarLive: View {
    @ObservedObject var meetings: MeetingController

    var body: some View {
        if meetings.isRecording { LiveDot(color: Theme.coral) }
    }
}

struct EngineStatusBadge: View {
    @ObservedObject var engine: EngineClient

    var body: some View {
        let (kind, text): (StatusBadge.Kind, String) = {
            switch engine.status {
            case .ready: return (.ok, "Engine ready")
            case .failed: return (.warn, "Engine error")
            case .stopped: return (.off, "Engine stopped")
            case .downloading: return (.busy, "Downloading models")
            case .settingUp: return (.busy, "Installing engine")
            case .starting, .loading: return (.busy, "Starting engine")
            }
        }()
        StatusBadge(kind: kind, text: text)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    @ObservedObject var history: HistoryStore
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: greeting, subtitle: "Private dictation, running on this Mac.")

            if !controller.microphoneOK || !controller.accessibilityOK {
                PermissionsBanner(controller: controller)
            }

            HeroCard(controller: controller, settings: settings, engine: engine)

            HStack(spacing: 12) {
                StatTile(value: history.stats.words.formatted(), label: "words dictated")
                StatTile(value: history.stats.wordsThisWeek.formatted(), label: "this week")
                StatTile(value: "\(history.stats.streakDays)", label: history.stats.streakDays == 1 ? "day streak" : "day streak")
                StatTile(value: latency, label: "avg. turnaround")
            }

            Card(title: "Recent", subtitle: history.recent.isEmpty ? nil : "Click a transcript to copy it.") {
                if history.recent.isEmpty {
                    EmptyHint(symbol: "waveform", text: "Nothing yet. Put your cursor in any text field, hold \(hotkeyName) and say something.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.recent.prefix(5).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider() }
                            TranscriptRow(entry: entry, compact: true)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("See all history") { page = .history }.buttonStyle(.quiet)
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private var hotkeyName: String { settings.data.hotkey.label }

    private var latency: String {
        let ms = history.stats.averageLatencyMs
        return ms == 0 ? "—" : String(format: "%.1f s", Double(ms) / 1000)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Working late"
        }
    }
}

/// The big "hold the key and talk" card with the live waveform.
private struct HeroCard: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient

    var body: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Hold").font(Theme.display(22, weight: .semibold)).foregroundStyle(Theme.ink)
                            HotkeyCap(choice: settings.data.hotkey, size: 16)
                            Text("and talk.").font(Theme.display(22, weight: .semibold)).foregroundStyle(Theme.ink)
                        }
                        Text(instruction)
                            .font(Theme.body).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    LiveWaveform(controller: controller, model: controller.overlay.model)
                }
                HStack(spacing: 18) {
                    hint("tap for hands-free") { HotkeyCap(choice: settings.data.hotkey, size: 10, tint: Theme.inkSecondary) }
                    hint("edit the selection") {
                        KeyCap(label: "⌃", size: 10, tint: Theme.inkSecondary)
                        HotkeyCap(choice: settings.data.hotkey, size: 10, tint: Theme.inkSecondary)
                    }
                    hint("cancel") { KeyCap(label: "esc", size: 10, tint: Theme.inkSecondary) }
                }
            }
        }
    }

    private func hint<Keys: View>(_ text: String, @ViewBuilder keys: () -> Keys) -> some View {
        HStack(spacing: 6) {
            keys()
            Text(text).font(Theme.caption).foregroundStyle(Theme.inkSecondary).fixedSize()
        }
    }

    private var instruction: String {
        switch engine.status {
        case .ready: return "Text appears wherever your cursor is. Filler words go, punctuation and corrections are applied, and nothing leaves this Mac."
        case .failed: return "The engine isn't running. Open Settings to restart it or check the log."
        default: return engine.status.sentence + " You can dictate as soon as it's ready."
        }
    }
}

/// Mirrors the overlay's bars while recording; rests as a quiet baseline otherwise.
private struct LiveWaveform: View {
    @ObservedObject var controller: AppController
    @ObservedObject var model: OverlayModel

    private static let rest: [Float] = (0..<OverlayModel.barCount).map { i in
        let t = Float(i) / Float(OverlayModel.barCount - 1)
        return 0.08 + 0.22 * sinf(t * .pi)
    }

    var body: some View {
        let recording: Bool = { if case .recording = controller.phase { return true } else { return false } }()
        let command: Bool = { if case .recording(true, _) = controller.phase { return true } else { return false } }()
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(recording ? (command ? Theme.amberSoft : Theme.tealSoft) : Theme.well)
            Waveform(levels: recording ? model.levels : Self.rest,
                     tint: recording ? (command ? Theme.amber : Theme.teal) : Theme.inkTertiary,
                     barWidth: 4, spacing: 4, minHeight: 4, maxHeight: 40)
        }
        .frame(width: 150, height: 84)
        .animation(.easeOut(duration: 0.2), value: recording)
    }
}

/// Draws the configured hotkey as a key cap, with the globe glyph for Fn.
struct HotkeyCap: View {
    var choice: HotkeyChoice
    var size: CGFloat = 15
    var tint: Color = Theme.ink

    var body: some View {
        switch choice {
        case .fn: KeyCap(label: "fn", symbol: "globe", size: size, tint: tint)
        case .rightOption: KeyCap(label: "⌥", size: size, tint: tint)
        case .rightCommand: KeyCap(label: "⌘", size: size, tint: tint)
        }
    }
}

private struct StatTile: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.stat).foregroundStyle(Theme.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct PermissionsBanner: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mynah needs permission to work").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(missing).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button("Set up") { controller.showOnboarding() }.buttonStyle(.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.amberSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.amber.opacity(0.35)))
    }

    private var missing: String {
        switch (controller.microphoneOK, controller.accessibilityOK) {
        case (false, false): return "Allow Microphone and Accessibility access to dictate into other apps."
        case (false, true): return "Allow Microphone access so Mynah can hear you."
        default: return "Allow Accessibility access for the hotkey and to type into other apps."
        }
    }
}

struct EmptyHint: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.inkTertiary)
            Text(text).font(Theme.body).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - History

struct TranscriptRow: View {
    var entry: HistoryEntry
    var compact = false
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(Theme.body).foregroundStyle(Theme.ink)
                        .lineLimit(compact ? 2 : 6)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if entry.kind == "command" {
                            Text("Edit").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.amber)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.amberSoft))
                        }
                        Text(entry.app).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        Text(Self.when(entry.date)).font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                        if !compact {
                            Text("\(entry.wordCount) words").font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(copied ? "Copied" : "Copy")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(copied ? Theme.mint : Theme.teal)
                    .opacity(hover || copied ? 1 : 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private static func when(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct HistoryPage: View {
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageHeader(title: "History", subtitle: "Everything you've dictated, stored only on this Mac.")
                Spacer()
                if !history.recent.isEmpty {
                    Button("Clear history") { confirmClear = true }.buttonStyle(.quiet)
                        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear) {
                            Button("Delete", role: .destructive) { history.clear() }
                        }
                }
            }
            Card {
                if history.recent.isEmpty {
                    EmptyHint(symbol: "clock", text: "Transcripts show up here after you dictate.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.recent.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider() }
                            TranscriptRow(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @ObservedObject var settings: SettingsStore
    @State private var draft = ""

    private var terms: [String] { settings.data.vocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Dictionary",
                       subtitle: "Names, jargon and product terms. Mynah spells these exactly as you write them, even when the recognizer mishears.")
            Card {
                HStack(spacing: 10) {
                    TextField("Add a word or name, e.g. Kubernetes", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.well))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.border))
                        .onSubmit(add)
                    Button("Add") { add() }.buttonStyle(.accent).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if terms.isEmpty {
                    EmptyHint(symbol: "character.book.closed", text: "No words yet. Add the names people mishear and Mynah will get them right.")
                        .padding(.top, 4)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(terms, id: \.self) { term in
                            Chip(text: term) { settings.data.vocabulary.removeAll { $0 == term } }
                        }
                    }
                    .padding(.top, 14)
                }
            }
        }
    }

    private func add() {
        let word = draft.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        if !settings.data.vocabulary.contains(word) { settings.data.vocabulary.append(word) }
        draft = ""
    }
}

private struct Chip: View {
    var text: String
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hover ? Theme.ink : Theme.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11).padding(.trailing, 8).padding(.vertical, 6)
        .background(Capsule().fill(Theme.well))
        .overlay(Capsule().strokeBorder(hover ? Theme.borderStrong : Theme.border))
        .onHover { hover = $0 }
    }
}

/// Wraps children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Snippets

private struct SnippetsPage: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageHeader(title: "Snippets",
                           subtitle: "Say the trigger phrase and Mynah inserts the expansion instead.")
                Spacer()
                Button("New snippet") { settings.data.snippets.insert(Snippet(trigger: "", text: ""), at: 0) }
                    .buttonStyle(.accent)
            }
            if settings.data.snippets.isEmpty {
                Card {
                    EmptyHint(symbol: "text.badge.plus",
                              text: "No snippets yet. Try “my calendar link” → your scheduling URL, or “my address” → your full address.")
                }
            } else {
                VStack(spacing: 12) {
                    ForEach($settings.data.snippets) { $snippet in
                        SnippetCard(snippet: $snippet) {
                            settings.data.snippets.removeAll { $0.id == snippet.id }
                        }
                    }
                }
            }
        }
    }
}

private struct SnippetCard: View {
    @Binding var snippet: Snippet
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("When I say").font(Theme.caption).foregroundStyle(Theme.inkSecondary).frame(width: 72, alignment: .leading)
                    TextField("my calendar link", text: $snippet.trigger)
                        .textFieldStyle(.plain).font(Theme.body.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.well))
                    Button(action: remove) {
                        Image(systemName: "trash").font(.system(size: 12))
                            .foregroundStyle(hover ? Theme.coral : Theme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete snippet")
                }
                HStack(alignment: .top, spacing: 8) {
                    Text("insert").font(Theme.caption).foregroundStyle(Theme.inkSecondary).frame(width: 72, alignment: .leading)
                        .padding(.top, 7)
                    TextField("https://cal.com/you", text: $snippet.text, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain).font(Theme.body)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.well))
                    Color.clear.frame(width: 14)
                }
            }
        }
        .onHover { hover = $0 }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var microphones = AudioDevices.inputs()
    @State private var models: ModelsResponse?
    @State private var loadError: String?

    private var selectedMicConnected: Bool { microphones.contains { $0.uid == settings.data.inputDevice } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Settings")

            Card(title: "Dictation") {
                VStack(spacing: 0) {
                    SettingRow(title: "Hotkey", detail: hotkeyDetail) {
                        PickerField(selection: $settings.data.hotkey) {
                            ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    RowDivider()
                    SettingRow(title: "AI cleanup", detail: "Remove filler, fix punctuation, apply spoken corrections.") {
                        Toggle("", isOn: $settings.data.cleanupEnabled).labelsHidden().toggleStyle(TealToggleStyle())
                    }
                    RowDivider()
                    SettingRow(title: "Sounds", detail: "A soft tick when recording starts and stops.") {
                        Toggle("", isOn: $settings.data.playSounds).labelsHidden().toggleStyle(TealToggleStyle())
                    }
                    RowDivider()
                    SettingRow(title: "Restore clipboard", detail: "Put whatever you had copied back after pasting.") {
                        Toggle("", isOn: $settings.data.restoreClipboard).labelsHidden().toggleStyle(TealToggleStyle())
                    }
                    RowDivider()
                    SettingRow(title: "Launch at login") {
                        Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(TealToggleStyle())
                            .onChange(of: launchAtLogin) { _, enabled in
                                do {
                                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                }
            }

            Card(title: "Microphone") {
                VStack(spacing: 0) {
                    SettingRow(title: "Input", detail: micDetail) {
                        PickerField(selection: $settings.data.inputDevice) {
                            if settings.data.inputDevice.isEmpty { Text("System default").tag("") }
                            ForEach(microphones) { Text($0.name).tag($0.uid) }
                            if !settings.data.inputDevice.isEmpty, !selectedMicConnected {
                                Text("Disconnected device").tag(settings.data.inputDevice)
                            }
                        }
                        .onAppear { microphones = AudioDevices.inputs() }
                    }
                }
            }

            MeetingsSettingsCard(settings: settings, engine: engine, meetings: controller.meetings)

            Card(title: "Models", subtitle: "Models marked ↓ download on first use (a few GB). Changes apply automatically.") {
                VStack(spacing: 0) {
                    SettingRow(title: "Engine", detail: loadedDetail) {
                        HStack(spacing: 10) {
                            EngineStatusBadge(engine: engine)
                            Button("Restart") { controller.startEngine() }.buttonStyle(.quiet)
                        }
                    }
                    if let models {
                        RowDivider()
                        SettingRow(title: "Speech recognition") {
                            modelPicker(selection: $settings.data.asrModel, options: models.asr, allowNone: false)
                        }
                        RowDivider()
                        SettingRow(title: "Cleanup model") {
                            modelPicker(selection: $settings.data.llmModel, options: models.llm, allowNone: true)
                        }
                        RowDivider()
                        SettingRow(title: "Command-mode model", detail: "Rewrites selected text when you hold Control too.") {
                            modelPicker(selection: $settings.data.commandModel,
                                        options: models.llm.filter { $0.can_command == true }, allowNone: true)
                        }
                    } else {
                        RowDivider()
                        Text(loadError ?? "Model list appears once the engine is running.")
                            .font(Theme.caption).foregroundStyle(Theme.inkSecondary).padding(.vertical, 10)
                    }
                    RowDivider()
                    SettingRow(title: "Engine log", detail: "For bug reports.") {
                        Button("Open log") { NSWorkspace.shared.open(EngineClient.logFile) }.buttonStyle(.quiet)
                    }
                }
            }
            .task(id: engine.status) { await refreshModels() }

            UpdatesCard(updater: controller.updater)

            Card(title: "Permissions") {
                VStack(spacing: 0) {
                    permissionRow("Microphone", granted: controller.microphoneOK, detail: "To hear you.", pane: "Privacy_Microphone")
                    RowDivider()
                    permissionRow("Accessibility", granted: controller.accessibilityOK,
                                  detail: "For the global hotkey, reading the focused app, and pasting text.",
                                  pane: "Privacy_Accessibility")
                }
            }
        }
    }

    private var hotkeyDetail: String {
        var text = "Hold to talk, tap for hands-free, hold with Control to edit the selection. Esc cancels."
        if settings.data.hotkey == .fn {
            text += " In System Settings › Keyboard, set “Press 🌐 key to” → Do Nothing so the emoji picker stays away."
        }
        return text
    }

    private var micDetail: String {
        if !settings.data.inputDevice.isEmpty, !selectedMicConnected {
            return "That microphone isn't connected. Mynah uses the built-in mic until it's back."
        }
        return "A Bluetooth headset's mic drops its audio to call quality while you dictate."
    }

    private var loadedDetail: String? {
        guard let health = engine.health else { return nil }
        let names = [health.asr, health.llm, health.command_llm].compactMap { $0 }
        return names.isEmpty ? nil : "Loaded: " + names.joined(separator: ", ")
    }

    private func refreshModels() async {
        do { models = try await engine.models() } catch { loadError = error.localizedDescription }
    }

    private func modelPicker(selection: Binding<String>, options: [ModelInfo], allowNone: Bool) -> some View {
        PickerField(selection: selection) {
            if allowNone { Text("None").tag("none") }
            ForEach(options) { m in
                Text("\(m.key) (\(m.params))\(m.downloaded ? "" : "  ↓")").tag(m.key)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool, detail: String, pane: String) -> some View {
        SettingRow(title: name, detail: detail) {
            if granted {
                StatusBadge(kind: .ok, text: "Allowed")
            } else {
                HStack(spacing: 10) {
                    StatusBadge(kind: .warn, text: "Not allowed")
                    Button("Open System Settings") { Permissions.openSettings(pane) }.buttonStyle(.accent)
                }
            }
        }
    }
}

private struct UpdatesCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Card(title: "Updates") {
            VStack(spacing: 0) {
                SettingRow(title: "Version \(Updater.currentVersion)") {
                    Button("Check now") { updater.checkForUpdates() }.buttonStyle(.quiet).disabled(!updater.canCheck)
                }
                RowDivider()
                SettingRow(title: "Check automatically", detail: "Once a day. Mynah asks before installing.") {
                    Toggle("", isOn: $updater.automaticallyChecks).labelsHidden().toggleStyle(TealToggleStyle())
                }
                RowDivider()
                SettingRow(title: "Install automatically", detail: "Download updates in the background and install them when Mynah quits.") {
                    Toggle("", isOn: $updater.automaticallyInstalls).labelsHidden().toggleStyle(TealToggleStyle())
                }
                RowDivider()
                SettingRow(title: "Beta versions", detail: "Get pre-releases with new features before they're stable.") {
                    Toggle("", isOn: $updater.includeBetas).labelsHidden().toggleStyle(TealToggleStyle())
                }
            }
        }
        .disabled(!Updater.available)
    }
}

// MARK: - About

private struct AboutPage: View {
    @ObservedObject var updater: Updater
    private var version: String { Updater.currentVersion }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "About")
            Card(padding: 22) {
                HStack(alignment: .top, spacing: 20) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mynah").font(Theme.display(22, weight: .bold)).foregroundStyle(Theme.ink)
                        Text("Version \(version)").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        Text("Private, on-device dictation. Speech recognition and text cleanup run locally on Apple Silicon with MLX. Nothing you say leaves this Mac.")
                            .font(Theme.body).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        Text("Named after the mynah bird, famous for repeating human speech.")
                            .font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                        HStack(spacing: 10) {
                            Button("GitHub") { NSWorkspace.shared.open(AppController.repoURL) }.buttonStyle(.quiet)
                            Button("Check for updates") { updater.checkForUpdates() }.buttonStyle(.quiet).disabled(!updater.canCheck)
                            Button("Report an issue") { NSWorkspace.shared.open(AppController.repoURL.appendingPathComponent("issues")) }.buttonStyle(.quiet)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            Card(title: "Models and licenses") {
                Text("Models are downloaded from Hugging Face and covered by their own licenses: NVIDIA Parakeet (CC-BY-4.0), Google Gemma (Gemma Terms of Use), and others listed in the README. Mynah itself is MIT licensed.")
                    .font(Theme.caption).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
