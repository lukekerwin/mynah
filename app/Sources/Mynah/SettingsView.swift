import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsTab(settings: settings, engine: engine)
                .tabItem { Label("Models", systemImage: "cpu") }
            DictionaryTab(settings: settings)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SnippetsTab(settings: settings)
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            PermissionsTab(controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 440)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var microphones = AudioDevices.inputs()

    private var selectedMicConnected: Bool { microphones.contains { $0.uid == settings.data.inputDevice } }

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $settings.data.hotkey) {
                    ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
                }
                Text("""
                Hold to talk, release to insert. Tap once for hands-free, tap again to finish. \
                Hold with Control to edit the selected text by voice. Esc cancels.
                """)
                .font(.callout).foregroundStyle(.secondary)
                if settings.data.hotkey == .fn {
                    Text("Tip: set System Settings › Keyboard › “Press 🌐 key to” → “Do Nothing” so the emoji picker doesn’t pop up.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Microphone", selection: $settings.data.inputDevice) {
                    if settings.data.inputDevice.isEmpty { Text("System default").tag("") }
                    ForEach(microphones) { Text($0.name).tag($0.uid) }
                    if !settings.data.inputDevice.isEmpty, !selectedMicConnected {
                        Text("Disconnected device").tag(settings.data.inputDevice)
                    }
                }
                .onAppear { microphones = AudioDevices.inputs() }
                if !settings.data.inputDevice.isEmpty, !selectedMicConnected {
                    Text("That microphone isn’t connected — using the built-in mic until it’s back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Using a Bluetooth headset’s mic drops its audio to call quality while you dictate.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("AI cleanup (remove filler, fix punctuation, apply corrections)", isOn: $settings.data.cleanupEnabled)
                Toggle("Play sounds", isOn: $settings.data.playSounds)
                Toggle("Restore clipboard after pasting", isOn: $settings.data.restoreClipboard)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    @State private var models: ModelsResponse?
    @State private var loadError: String?

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Engine", value: statusText)
                if let health = engine.health {
                    LabeledContent("Loaded", value: [health.asr, health.llm, health.command_llm]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            }
            if let models {
                Section {
                    picker("Speech recognition", selection: $settings.data.asrModel, options: models.asr, allowNone: false)
                    picker("Cleanup model", selection: $settings.data.llmModel, options: models.llm, allowNone: true)
                    picker("Command-mode model", selection: $settings.data.commandModel,
                           options: models.llm.filter { $0.can_command == true }, allowNone: true)
                } footer: {
                    Text("Models marked ↓ download on first use (a few GB). Changes apply automatically.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(loadError ?? "Waiting for engine…").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: engine.status) { await refresh() }
    }

    private var statusText: String { engine.status.summary }

    private func refresh() async {
        do { models = try await engine.models() } catch { loadError = error.localizedDescription }
    }

    private func picker(_ title: String, selection: Binding<String>, options: [ModelInfo], allowNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if allowNone { Text("None").tag("none") }
            ForEach(options) { m in
                Text("\(m.key) (\(m.params))\(m.downloaded ? "" : "  ↓")").tag(m.key)
            }
        }
    }
}

private struct DictionaryTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Names, jargon and product terms — one per line. Mynah spells these exactly as written.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { settings.data.vocabulary.joined(separator: "\n") },
                set: { settings.data.vocabulary = $0.components(separatedBy: "\n") }
            ))
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding()
    }
}

private struct SnippetsTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say the trigger phrase and Mynah inserts the expansion instead (e.g. “my calendar link”).")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach($settings.data.snippets) { $snippet in
                    HStack {
                        TextField("Trigger phrase", text: $snippet.trigger).frame(width: 170)
                        TextField("Expansion", text: $snippet.text)
                        Button(role: .destructive) {
                            settings.data.snippets.removeAll { $0.id == snippet.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Button("Add Snippet") { settings.data.snippets.append(Snippet(trigger: "", text: "")) }
        }
        .padding()
    }
}

private struct PermissionsTab: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            row("Microphone", granted: controller.microphoneOK,
                detail: "To hear you.", pane: "Privacy_Microphone")
            row("Accessibility", granted: controller.accessibilityOK,
                detail: "For the global hotkey, reading the focused app, and pasting text.",
                pane: "Privacy_Accessibility")
        }
        .formStyle(.grouped)
    }

    private func row(_ name: String, granted: Bool, detail: String, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") { Permissions.openSettings(pane) }
            }
        }
    }
}

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Mynah").font(.title.bold())
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Private, on-device dictation. Speech recognition and text cleanup run locally on Apple Silicon with MLX — nothing you say leaves this Mac.")
                .multilineTextAlignment(.center).frame(maxWidth: 380).font(.callout)
            HStack {
                Link("GitHub", destination: AppController.repoURL)
                Text("·").foregroundStyle(.secondary)
                Link("Releases", destination: AppController.repoURL.appendingPathComponent("releases"))
                Text("·").foregroundStyle(.secondary)
                Link("Report an issue", destination: AppController.repoURL.appendingPathComponent("issues"))
            }
            Text("Models are downloaded from Hugging Face and covered by their own licenses (NVIDIA Parakeet: CC-BY-4.0, Google Gemma: Gemma Terms of Use, and others listed in the README).")
                .multilineTextAlignment(.center).frame(maxWidth: 420).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
