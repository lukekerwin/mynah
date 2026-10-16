import AppKit
import SwiftUI

@main
struct MynahApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller, engine: delegate.controller.engine,
                        history: delegate.controller.history)
        } label: {
            MenuIcon(controller: delegate.controller, engine: delegate.controller.engine)
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

    private static let bird: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }()

    var body: some View {
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if !controller.accessibilityOK || !controller.microphoneOK {
            Button("⚠︎ Permissions needed…") { controller.showOnboarding() }
        }
        Divider()
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
