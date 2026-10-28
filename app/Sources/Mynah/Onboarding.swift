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
            let host = NSHostingController(rootView: view)
            host.safeAreaRegions = []
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome to Mynah"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.moveOnscreenIfNeeded()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 10) {
                step(number: 1, done: controller.microphoneOK, title: "Allow the microphone",
                     detail: "So Mynah can hear you while you hold the key. Audio never leaves your Mac.") {
                    Button("Allow") {
                        Task {
                            if !(await Permissions.requestMicrophone()) { Permissions.openSettings("Privacy_Microphone") }
                        }
                    }
                    .buttonStyle(.accent)
                }
                step(number: 2, done: controller.accessibilityOK, title: "Allow Accessibility",
                     detail: "For the global hotkey and to type into other apps. Turn on Mynah in the list.") {
                    Button("Open System Settings") {
                        Permissions.promptAccessibility()
                        Permissions.openSettings("Privacy_Accessibility")
                    }
                    .buttonStyle(.accent)
                }
                modelsStep
                if settings.data.hotkey == .fn {
                    step(number: 4, done: false, optional: true, title: "Free up the Globe key",
                         detail: "System Settings › Keyboard › “Press 🌐 key to” → Do Nothing, so the emoji picker stays out of the way.") {
                        Button("Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                        .buttonStyle(.quiet)
                    }
                }

                practiceBox.padding(.top, 6)

                HStack {
                    Text(allSet ? "You're all set." : "You can finish the rest later from the menu bar.")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    Button(allSet ? "Start dictating" : "Finish later") {
                        settings.data.onboarded = true
                        onDone()
                    }
                    .buttonStyle(AccentButtonStyle(prominent: allSet))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
        .frame(width: 540)
        .background(Theme.canvas)
        .ignoresSafeArea()
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.tealGradient
            // Soft dark vignette so the type reads over the gradient.
            LinearGradient(colors: [.clear, Color(hex: 0x0B6E66).opacity(0.55)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Mynah").font(Theme.display(26, weight: .bold)).foregroundStyle(.white)
                    HStack(spacing: 7) {
                        Text("Hold").font(Theme.display(15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        HotkeyCap(choice: settings.data.hotkey, size: 12)
                        Text("and talk. Private, on this Mac.")
                            .font(Theme.display(15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .padding(.top, 28)
        }
        .frame(height: 170)
    }

    private var allSet: Bool {
        controller.microphoneOK && controller.accessibilityOK && engine.status == .ready
    }

    @ViewBuilder private var modelsStep: some View {
        let status = engine.status
        step(number: 3, done: status == .ready, title: "Download the speech and language models",
             detail: modelsDetail(status)) {
            if case .failed = status {
                Button("Retry") { controller.startEngine() }.buttonStyle(.accent)
            }
        } extra: {
            if case let .downloading(_, done, total) = status, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(Theme.teal)
            } else if status.isBusy {
                ProgressView().progressViewStyle(.linear).tint(Theme.teal)
            }
        }
    }

    private func modelsDetail(_ status: EngineClient.Status) -> String {
        switch status {
        case .ready: return "Ready. Everything runs locally from now on, no internet needed."
        case .failed: return status.summary
        case .settingUp: return "Installing the engine (one time, about a minute)."
        default: return "\(status.sentence) About 9 GB, one time."
        }
    }

    private var practiceBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Try it").font(Theme.heading).foregroundStyle(Theme.ink)
                Spacer()
                Text("Click in the box, hold").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                HotkeyCap(choice: settings.data.hotkey, size: 9, tint: Theme.inkSecondary)
                Text("say something, let go.").font(Theme.caption).foregroundStyle(Theme.inkSecondary)
            }
            TextEditor(text: $practice)
                .font(Theme.body)
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.borderStrong))
        }
    }

    private func step<Accessory: View>(number: Int, done: Bool, optional: Bool = false, title: String, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        step(number: number, done: done, optional: optional, title: title, detail: detail, accessory: accessory) { EmptyView() }
    }

    private func step<Accessory: View, Extra: View>(number: Int, done: Bool, optional: Bool = false, title: String, detail: String,
                                                    @ViewBuilder accessory: () -> Accessory,
                                                    @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Theme.tealGradient) : AnyShapeStyle(Theme.well))
                    .overlay(Circle().strokeBorder(done ? Color.clear : Theme.borderStrong))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(Theme.display(12, weight: .bold)).foregroundStyle(Theme.inkSecondary)
                }
            }
            .frame(width: 24, height: 24)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                            if optional {
                                Text("optional").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkTertiary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.well))
                            }
                        }
                        Text(detail).font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !done { accessory() }
                }
                extra()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
        .animation(.easeOut(duration: 0.2), value: done)
    }
}
