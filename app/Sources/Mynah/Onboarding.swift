import AppKit
import SwiftUI

/// First-run setup: permissions, model download progress, the Globe-key tip,
/// and a box to try dictation in. Reopen any time from the menu bar.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show(controller: AppController) {
        if window == nil {
            let view = OnboardingView(controller: controller, settings: controller.settings, engine: controller.engine) {
                [weak self] in self?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Mynah"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    var onDone: () -> Void
    @State private var practice = ""

    private var hotkey: String { settings.data.hotkey.label }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Mynah").font(.title.bold())
                    Text("Talk instead of type — privately, on this Mac.").foregroundStyle(.secondary)
                }
            }

            step(done: controller.microphoneOK, title: "Allow microphone access",
                 detail: "So Mynah can hear you while you hold the hotkey. Audio never leaves your Mac.") {
                Button("Allow…") {
                    Task {
                        if !(await Permissions.requestMicrophone()) { Permissions.openSettings("Privacy_Microphone") }
                    }
                }
            }
            step(done: controller.accessibilityOK, title: "Allow Accessibility",
                 detail: "Needed for the global hotkey and to type into other apps. Turn on Mynah in the list.") {
                Button("Open Settings…") {
                    Permissions.promptAccessibility()
                    Permissions.openSettings("Privacy_Accessibility")
                }
            }
            modelsStep
            step(done: false, optional: true, title: "Free up the \(hotkey) key",
                 detail: "System Settings › Keyboard › “Press 🌐 key to” → Do Nothing, so the emoji picker doesn’t pop up.") {
                Button("Keyboard Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Try it").font(.headline)
                Text("Click in the box, hold \(hotkey), say something, and let go. Tap \(hotkey) once for hands-free.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $practice)
                    .font(.body)
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            }

            HStack {
                Spacer()
                Button(allSet ? "Done" : "Finish Later") {
                    settings.data.onboarded = true
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    private var allSet: Bool {
        controller.microphoneOK && controller.accessibilityOK && engine.status == .ready
    }

    @ViewBuilder private var modelsStep: some View {
        let status = engine.status
        step(done: status == .ready, title: "Download the speech and language models",
             detail: modelsDetail(status)) {
            if case .failed = status {
                Button("Retry") { controller.startEngine() }
            }
        }
        if case let .downloading(_, done, total) = status, total > 0 {
            ProgressView(value: Double(done), total: Double(total)).padding(.leading, 34)
        } else if status.isBusy {
            ProgressView().progressViewStyle(.linear).padding(.leading, 34)
        }
    }

    private func modelsDetail(_ status: EngineClient.Status) -> String {
        switch status {
        case .ready: return "Ready. Everything runs locally from now on — no internet needed."
        case .failed: return status.summary
        case .settingUp: return "Installing the engine (one time, about a minute)…"
        default: return "\(status.summary) About 9 GB, one time."
        }
    }

    private func step<Accessory: View>(done: Bool, optional: Bool = false, title: String, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "lightbulb" : "circle"))
                .font(.title2)
                .foregroundStyle(done ? Color.green : (optional ? Color.orange : Color.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { accessory() }
        }
    }
}
