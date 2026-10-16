import AppKit
import SwiftUI

/// Pure AppKit entry point: Mynah is a menu bar app whose windows are created on
/// demand, so there is no SwiftUI scene to drive.
@main
@MainActor
enum MynahMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        app.run()
    }

    /// Standard menus for when the app is frontmost with a window open: the app
    /// menu, Edit (so copy/paste work in text fields) and Window.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mynah", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mynah", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mynah", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        menu.addItem(windowItem)
        NSApp.windowsMenu = window
        return menu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    @objc func showAbout() { controller.showMain(.about) }
    @objc func showSettings() { controller.showMain(.settings) }

    /// Clicking the Dock icon (shown while a window is open) brings the app window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller.showMain()
        return false
    }
}

/// The menu bar dropdown: a small panel rather than a system menu, so it can show
/// state, the hotkey and recent transcripts the way the rest of the app does.
struct MenuPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)

            if !controller.accessibilityOK || !controller.microphoneOK {
                Rectangle().fill(Theme.border).frame(height: 1)
                MenuAction(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, title: "Permissions needed",
                           detail: "Mynah can't dictate until they're allowed.") {
                    controller.showOnboarding(); dismiss()
                }
            }

            if case .downloading(_, let done, let total) = engine.status, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(Theme.teal).padding(.horizontal, 16).padding(.bottom, 12)
            }

            if let meetings = controller.meetings {
                Rectangle().fill(Theme.border).frame(height: 1)
                MenuMeetingSection(meetings: meetings, settings: settings, open: open, dismiss: dismiss)
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            if history.recent.isEmpty {
                Text("Recent transcripts will appear here.")
                    .font(Theme.caption).foregroundStyle(Theme.inkTertiary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.recent.prefix(4)) { entry in
                        MenuTranscript(entry: entry)
                    }
                }
                .padding(.vertical, 6)
                HStack(spacing: 8) {
                    Button("Paste last") { controller.pasteLast(); dismiss() }.buttonStyle(.quiet)
                    Button("All history") { open(.history) }.buttonStyle(.quiet)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(spacing: 0) {
                MenuAction(symbol: "macwindow", title: "Open Mynah") { open(.home) }
                MenuAction(symbol: "sparkles", title: "Setup guide") { controller.showOnboarding(); dismiss() }
                if case .failed = engine.status {
                    MenuAction(symbol: "arrow.clockwise", title: "Restart engine") { controller.startEngine() }
                }
                if MeetingProbe.enabled { debugActions }
                MenuAction(symbol: "power", title: "Quit Mynah") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 320)
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong))
        .padding(1)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                EngineStatusBadge(engine: engine)
                switch engine.status {
                case .ready:
                    HStack(spacing: 6) {
                        Text("Hold").font(Theme.display(15, weight: .semibold)).foregroundStyle(Theme.ink)
                        HotkeyCap(choice: settings.data.hotkey, size: 11)
                        Text("to dictate").font(Theme.display(15, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                case .failed, .downloading:
                    Text(engine.status.summary).font(Theme.caption).foregroundStyle(Theme.inkSecondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
        }
    }

    /// Phase-0 probe tools, only with `defaults write com.lukekerwin.mynah MynahMeetingProbe -bool YES`.
    @ViewBuilder private var debugActions: some View {
        let probe = controller.probe
        MenuAction(symbol: "ladybug", title: probe.logging ? "Stop logging audio processes" : "Log audio processes") {
            probe.toggleLogging()
        }
        MenuAction(symbol: "ladybug", title: probe.recording ? "Stop recording Teams + mic" : "Record Teams + mic") {
            probe.toggleRecording()
        }
        MenuAction(symbol: "ladybug", title: "Import probe recording as meeting…") {
            dismiss()
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url { controller.meetings?.importProbe(url) }
        }
        MenuAction(symbol: "ladybug", title: "Open meetings log") {
            if !FileManager.default.fileExists(atPath: MeetingProbe.logURL.path) { probe.write("log opened") }
            NSWorkspace.shared.open(MeetingProbe.logURL)
        }
    }

    private func open(_ page: Page) {
        controller.showMain(page)
        dismiss()
    }

    private func dismiss() {
        controller.statusBar?.hide()
    }
}

/// What the call recorder is doing, with the controls that matter right now.
private struct MenuMeetingSection: View {
    @ObservedObject var meetings: MeetingController
    @ObservedObject var settings: SettingsStore
    var open: (Page) -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch meetings.state {
            case let .recording(r):
                recording(r)
            case .asking:
                MenuAction(symbol: "phone.fill", tint: Theme.amber, title: "Teams call in progress",
                           detail: "Record and transcribe it on this Mac?") {
                    meetings.recordAskedCall()
                }
            case .idle:
                Menu {
                    ForEach(meetings.audioApps()) { app in
                        Button(app.name) { meetings.startManual(app); dismiss() }
                    }
                } label: {
                    MenuActionLabel(symbol: "record.circle", title: "Record a meeting",
                                    detail: "Pick the app that's playing the call.", trailing: "chevron.right")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            default:
                EmptyView()
            }
            if settings.data.meetings.enabled || hasMeetings {
                MenuAction(symbol: "person.2.wave.2", title: "Meetings") { open(.meetings) }
                MenuAction(symbol: "checklist", title: "To-dos") { open(.todos) }
            }
        }
        .padding(.vertical, 6)
    }

    private var hasMeetings: Bool { (try? meetings.store.allMeetings().isEmpty) == false }

    private func recording(_ r: MeetingController.Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                LiveDot(color: Theme.coral).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Recording").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text(meetings.elapsed).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                    }
                    Text(r.title).font(Theme.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    if let note = statusNote(r) {
                        Text(note).font(Theme.caption).foregroundStyle(Theme.amber)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(r.paused ? "Resume mic" : "Pause mic") { meetings.togglePauseMic() }.buttonStyle(.quiet)
                Button("Stop") { meetings.stop(discard: false); dismiss() }.buttonStyle(.quiet)
                Button("Open") { meetings.showMeetings(focus: r.meetingID); dismiss() }.buttonStyle(.quiet)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func statusNote(_ r: MeetingController.Recording) -> String? {
        if meetings.permissionProblem { return "Can't hear the call: allow System Audio Recording." }
        if r.paused { return "Your mic is paused." }
        if meetings.teamsMuted == true, settings.data.meetings.teamsMuteDetection { return "Muted in Teams, not recording you." }
        return nil
    }
}

private struct MenuAction: View {
    var symbol: String
    var tint: Color = Theme.inkSecondary
    var title: String
    var detail: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuActionLabel(symbol: symbol, tint: tint, title: title, detail: detail)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct MenuActionLabel: View {
    var symbol: String
    var tint: Color = Theme.inkSecondary
    var title: String
    var detail: String?
    var trailing: String?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.inkSecondary) }
            }
            Spacer()
            if let trailing {
                Image(systemName: trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.card : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct MenuTranscript: View {
    var entry: HistoryEntry
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                    .font(Theme.body).foregroundStyle(Theme.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(copied ? "Copied" : "Copy").font(Theme.caption.weight(.medium))
                    .foregroundStyle(copied ? Theme.mint : Theme.teal).opacity(hover || copied ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.card : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Red (non-template, so the menu bar keeps its colour) recording dot.
let recordingDot: NSImage = {
    let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
    let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording meeting")?
        .withSymbolConfiguration(config) ?? NSImage()
    image.isTemplate = false
    return image
}()
