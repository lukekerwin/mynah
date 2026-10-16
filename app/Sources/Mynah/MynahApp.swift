import AppKit
import SwiftUI

@main
struct MynahApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller, engine: delegate.controller.engine,
                        history: delegate.controller.history, probe: delegate.controller.probe)
        } label: {
            MenuIcon(controller: delegate.controller, engine: delegate.controller.engine,
                     meetings: delegate.controller.meetings)
        }

        Window("Mynah Settings", id: "settings") {
            SettingsView(controller: delegate.controller, settings: delegate.controller.settings,
                         engine: delegate.controller.engine)
        }
        .windowResizability(.contentSize)
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
}

struct MenuIcon: View {
    @ObservedObject var controller: AppController
    @ObservedObject var engine: EngineClient
    let meetings: MeetingController?

    private static let bird: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }()

    var body: some View {
        if let meetings {
            MeetingAwareIcon(meetings: meetings, dictating: controller.phase != .idle) { base }
        } else {
            base
        }
    }

    @ViewBuilder
    private var base: some View {
        if let symbol {
            Image(systemName: symbol)
        } else if let bird = Self.bird {
            Image(nsImage: bird)
        } else {
            Image(systemName: "waveform")
        }
    }

    /// SF Symbol for transient states; nil means the Mynah bird (idle and ready).
    private var symbol: String? {
        switch controller.phase {
        case .recording: return "record.circle"
        case .processing: return "ellipsis.circle"
        case .idle:
            switch engine.status {
            case .ready: return nil
            case .failed: return "exclamationmark.triangle"
            default: return "arrow.down.circle"
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var engine: EngineClient
    @ObservedObject var history: HistoryStore
    @ObservedObject var probe: MeetingProbe
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if !controller.accessibilityOK || !controller.microphoneOK {
            Button("⚠︎ Permissions needed…") { openSettings() }
        }
        Divider()
        if let meetings = controller.meetings {
            MeetingMenuSection(meetings: meetings, settings: controller.settings)
        }
        if !history.recent.isEmpty {
            Text("Recent — click to copy")
            ForEach(history.recent.prefix(5)) { entry in
                Button(Self.preview(entry.text)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }
            }
            Button("Paste Last Transcript") { controller.pasteLast() }
            Divider()
        }
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Setup Guide…") { controller.showOnboarding() }
        Menu("Help") {
            Button("About Mynah") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Button("Check for Updates…") {
                NSWorkspace.shared.open(AppController.repoURL.appendingPathComponent("releases"))
            }
            Button("Report an Issue…") {
                NSWorkspace.shared.open(AppController.repoURL.appendingPathComponent("issues"))
            }
            Divider()
            Button("Restart Engine") { controller.startEngine() }
            Button("Open Engine Log") { NSWorkspace.shared.open(EngineClient.logFile) }
        }
        if MeetingProbe.enabled {
            Menu("Debug") {
                if !probe.status.isEmpty { Text(probe.status) }
                Button(probe.logging ? "Stop Logging Audio Processes" : "Log Audio Processes") { probe.toggleLogging() }
                Button(probe.recording ? "Stop Recording Teams + Mic" : "Record Teams + Mic") { probe.toggleRecording() }
                Button("Dump Teams Accessibility Tree") { probe.dumpTeamsAccessibility() }
                if let meetings = controller.meetings {
                    Button("Import Probe Recording as Meeting…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                        NSApp.activate(ignoringOtherApps: true)
                        if panel.runModal() == .OK, let url = panel.url { meetings.importProbe(url) }
                    }
                }
                Button("Open Meetings Log") {
                    if !FileManager.default.fileExists(atPath: MeetingProbe.logURL.path) { probe.write("log opened") }
                    NSWorkspace.shared.open(MeetingProbe.logURL)
                }
            }
        }
        Divider()
        Button("Quit Mynah") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        let key = controller.settings.data.hotkey.label
        switch engine.status {
        case .ready: return "Ready — hold \(key) to dictate"
        case let .failed(message): return "Engine error: \(message.prefix(60))"
        default: return engine.status.summary
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
    }
}

/// While a meeting records (and no dictation is in progress): a red dot + timer.
struct MeetingAwareIcon<Base: View>: View {
    @ObservedObject var meetings: MeetingController
    let dictating: Bool
    @ViewBuilder var base: () -> Base

    var body: some View {
        if meetings.isRecording, !dictating {
            HStack(spacing: 3) {
                Image(nsImage: recordingDot)
                Text(meetings.elapsed).monospacedDigit()
            }
        } else {
            base()
        }
    }
}

struct MeetingMenuSection: View {
    @ObservedObject var meetings: MeetingController
    @ObservedObject var settings: SettingsStore

    var body: some View {
        switch meetings.state {
        case let .recording(r):
            Text("● Recording “\(r.title)” — \(meetings.elapsed)")
            if meetings.permissionProblem {
                Button("⚠︎ Can't hear the call — check permission…") {
                    Permissions.openSettings("Privacy_ScreenCapture")
                }
            } else if r.paused {
                Text("Your mic is paused")
            } else if meetings.teamsMuted == true, settings.data.meetings.teamsMuteDetection {
                Text("Muted in Teams — not recording you")
            }
            Button(r.paused ? "Resume My Mic" : "Pause My Mic") { meetings.togglePauseMic() }
            Button("Stop Recording") { meetings.stop(discard: false) }
            Button("Stop & Discard…") { meetings.confirmDiscard() }
            Divider()
        case .asking:
            Text("Teams call in progress")
            Button("Record This Call") { meetings.recordAskedCall() }
            Divider()
        case .idle:
            Menu("Record Meeting") {
                ForEach(meetings.audioApps()) { app in
                    Button(app.name) { meetings.startManual(app) }
                }
            }
        default:
            EmptyView()
        }
        if settings.data.meetings.enabled || (try? meetings.store.allMeetings().isEmpty) == false {
            Button("Meetings & To-dos…") { meetings.showMeetings() }
            Divider()
        }
    }
}

/// Red (non-template, so the menu bar keeps its color) recording dot.
let recordingDot: NSImage = {
    let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
    let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording meeting")?
        .withSymbolConfiguration(config) ?? NSImage()
    image.isTemplate = false
    return image
}()
