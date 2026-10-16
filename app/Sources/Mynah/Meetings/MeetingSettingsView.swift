import MynahCore
import SwiftUI

struct MeetingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    let meetings: MeetingController?
    @State private var showSetup = false
    @State private var llms: [ModelInfo] = []

    private var m: Binding<MeetingSettings> { $settings.data.meetings }

    var body: some View {
        Form {
            Section {
                Toggle("Record and transcribe calls", isOn: Binding(
                    get: { settings.data.meetings.enabled },
                    set: { on in
                        if on, !settings.data.meetings.consentAcknowledged { showSetup = true } else { m.wrappedValue.enabled = on }
                    }))
                .disabled(!MeetingController.isSupported || meetings == nil)
                Text("""
                Mynah notices when a Microsoft Teams call starts, records the call's audio and your mic \
                separately, and writes a transcript, summary and to-do list — all on this Mac. Other apps \
                can be recorded from the menu bar (Record Meeting).
                """)
                .font(.callout).foregroundStyle(.secondary)
                if !MeetingController.isSupported {
                    Text("Meeting capture needs macOS 14.2 or later.").foregroundStyle(.red)
                }
            }
            if settings.data.meetings.enabled {
                Section("Recording") {
                    Picker("When a Teams call starts", selection: m.autoRecord) {
                        Text("Record automatically").tag(true)
                        Text("Ask me").tag(false)
                    }
                    Toggle("Pause my mic with ⌃⌥M while recording", isOn: m.pauseMicShortcut)
                    Toggle("Don't record me while I'm muted in Teams", isOn: m.teamsMuteDetection)
                    Text("Tip: headphones give the cleanest transcript. On speakers, Mynah removes lines your mic picked up from the call.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Notes") {
                    Picker("Summary model", selection: m.summaryModel) {
                        Text("Same as cleanup model").tag("default")
                        ForEach(llms) { model in
                            Text("\(model.key) (\(model.params))\(model.downloaded ? "" : "  ↓")").tag(model.key)
                        }
                    }
                    TextField("Your name (optional)", text: m.myName, prompt: Text("Helps assign action items to you"))
                }
                Section {
                    Picker("Keep meeting audio", selection: m.audioRetention) {
                        ForEach(AudioRetention.allCases) { Text($0.label).tag($0) }
                    }
                    if let meetings {
                        Button("Open Meetings & To-dos…") { meetings.showMeetings() }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Transcripts, summaries and to-dos are kept until you delete them. Audio takes about 30 MB per hour.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let meetings { PermissionSection(meetings: meetings) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSetup) {
            if let meetings {
                MeetingSetupView(settings: settings, meetings: meetings) { showSetup = false }
            }
        }
        .task(id: engine.status) {
            if let models = try? await engine.models() {
                llms = models.llm.filter { $0.can_command == true }  // general-purpose models only
            }
        }
    }
}

private struct PermissionSection: View {
    @ObservedObject var meetings: MeetingController

    var body: some View {
        Section("System audio") {
            HStack {
                if meetings.permissionProblem {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("Mynah couldn't hear the last call. Allow it under Screen & System Audio Recording.")
                } else if meetings.systemAudioVerified {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("System Audio Recording is allowed.")
                } else {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text("Checked automatically on your first call.")
                }
                Spacer()
                Button("Open Settings") { Permissions.openSettings("Privacy_ScreenCapture") }
            }
        }
    }
}

/// First-time setup when turning meeting capture on.
struct MeetingSetupView: View {
    @ObservedObject var settings: SettingsStore
    let meetings: MeetingController
    var done: () -> Void
    @State private var understood = false
    @State private var notificationsAsked = false
    @State private var audioAsked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up meeting capture").font(.title2.bold())

            step(1, "Recording calls", done: understood) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("""
                    Recording laws differ by place — in some, everyone on a call must agree to be recorded. \
                    Unlike Teams' own recording, other participants are not notified. Only record calls you're \
                    allowed to. Audio, transcripts and notes stay on this Mac.
                    """)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("I understand", isOn: $understood)
                }
            }
            step(2, "Notifications", done: notificationsAsked) {
                HStack {
                    Text("So Mynah can tell you when it starts recording and when notes are ready.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") {
                        Task {
                            _ = await meetings.notifications.requestAuthorization()
                            notificationsAsked = true
                        }
                    }
                }
            }
            step(3, "System audio", done: audioAsked) {
                HStack {
                    Text("Lets Mynah hear the other people on the call (not your screen). macOS will ask once.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") {
                        Task {
                            await meetings.requestSystemAudioPermission()
                            audioAsked = true
                        }
                    }
                }
            }
            Text("A small voice-detection model (about 2 MB) downloads when you finish.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done() }
                Button("Turn On") {
                    settings.data.meetings.consentAcknowledged = true
                    settings.data.meetings.enabled = true
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!understood)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2).foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
