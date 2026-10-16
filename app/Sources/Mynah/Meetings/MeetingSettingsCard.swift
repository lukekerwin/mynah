import MynahCore
import SwiftUI

/// The Meetings card on the Settings page.
struct MeetingsSettingsCard: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var engine: EngineClient
    let meetings: MeetingController?
    @State private var showSetup = false
    @State private var llms: [ModelInfo] = []

    private var m: Binding<MeetingSettings> { $settings.data.meetings }
    private var enabled: Bool { settings.data.meetings.enabled }

    var body: some View {
        Card(title: "Meetings",
             subtitle: "Mynah notices Microsoft Teams calls, records the call and your mic as separate tracks, and writes a transcript, notes and to-dos. Other apps can be recorded from the menu bar. Nothing leaves this Mac.") {
            VStack(spacing: 0) {
                SettingRow(title: "Record and transcribe calls", detail: unsupported) {
                    Toggle("", isOn: Binding(
                        get: { enabled },
                        set: { on in
                            if on, !settings.data.meetings.consentAcknowledged { showSetup = true } else { m.wrappedValue.enabled = on }
                        }))
                    .labelsHidden().toggleStyle(TealToggleStyle())
                    .disabled(!MeetingController.isSupported || meetings == nil)
                }
                if enabled {
                    RowDivider()
                    SettingRow(title: "When a Teams call starts") {
                        PickerField(selection: m.autoRecord) {
                            Text("Record automatically").tag(true)
                            Text("Ask me first").tag(false)
                        }
                    }
                    RowDivider()
                    SettingRow(title: "Live transcript",
                               detail: "A small pill at the right edge of the screen while a call is recorded. Hover over it to read along.") {
                        Toggle("", isOn: m.liveTranscript).labelsHidden().toggleStyle(TealToggleStyle())
                    }
                    RowDivider()
                    SettingRow(title: "Pause my mic with ⌃⌥M", detail: "Everyone else keeps being transcribed.") {
                        Toggle("", isOn: m.pauseMicShortcut).labelsHidden().toggleStyle(TealToggleStyle())
                    }
                    RowDivider()
                    SettingRow(title: "Skip me while muted in Teams",
                               detail: "Headphones give the cleanest transcript. On speakers, Mynah drops lines your mic picked up from the call.") {
                        Toggle("", isOn: m.teamsMuteDetection).labelsHidden().toggleStyle(TealToggleStyle())
                    }
                    RowDivider()
                    SettingRow(title: "Notes model") {
                        PickerField(selection: m.summaryModel) {
                            Text("Same as cleanup model").tag("default")
                            ForEach(llms) { model in
                                Text("\(model.key) (\(model.params))\(model.downloaded ? "" : "  ↓")").tag(model.key)
                            }
                        }
                    }
                    RowDivider()
                    SettingRow(title: "Your name", detail: "Helps the notes assign to-dos to you.") {
                        TextField("Optional", text: m.myName)
                            .textFieldStyle(.plain).font(Theme.body)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(width: 200)
                            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.well))
                            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.border))
                    }
                    RowDivider()
                    SettingRow(title: "Keep meeting audio",
                               detail: "Transcripts, notes and to-dos stay until you delete them. Audio is about 30 MB an hour.") {
                        PickerField(selection: m.audioRetention) {
                            ForEach(AudioRetention.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    if let meetings {
                        RowDivider()
                        SystemAudioRow(meetings: meetings)
                    }
                }
            }
        }
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

    private var unsupported: String? {
        MeetingController.isSupported ? nil : "Needs macOS 14.2 or later."
    }
}

private struct SystemAudioRow: View {
    @ObservedObject var meetings: MeetingController

    var body: some View {
        SettingRow(title: "System audio", detail: "Lets Mynah hear the other people on the call, not your screen.") {
            HStack(spacing: 10) {
                if meetings.permissionProblem {
                    StatusBadge(kind: .warn, text: "Couldn't hear the last call")
                } else if meetings.systemAudioVerified {
                    StatusBadge(kind: .ok, text: "Allowed")
                } else {
                    StatusBadge(kind: .off, text: "Checked on your first call")
                }
                Button("Open System Settings") { Permissions.openSettings("Privacy_ScreenCapture") }.buttonStyle(.quiet)
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
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Theme.tealGradient
                LinearGradient(colors: [.clear, Color(hex: 0x0B6E66).opacity(0.55)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up meeting capture").font(Theme.display(22, weight: .bold)).foregroundStyle(.white)
                    Text("Three quick things before Mynah records a call.")
                        .font(Theme.body).foregroundStyle(.white.opacity(0.9))
                }
                .padding(22)
            }
            .frame(height: 104)

            VStack(alignment: .leading, spacing: 10) {
                step(1, done: understood, title: "Recording calls",
                     detail: "Recording laws differ by place; in some, everyone on a call must agree. Unlike Teams' own recording, other participants are not told. Only record calls you're allowed to. Audio, transcripts and notes stay on this Mac.") {
                    Toggle("I understand", isOn: $understood).toggleStyle(TealToggleStyle()).font(Theme.body).frame(width: 130)
                }
                step(2, done: notificationsAsked, title: "Notifications",
                     detail: "So Mynah can tell you when it starts recording and when the notes are ready.") {
                    Button("Allow") {
                        Task {
                            _ = await meetings.notifications.requestAuthorization()
                            notificationsAsked = true
                        }
                    }
                    .buttonStyle(.accent)
                }
                step(3, done: audioAsked, title: "System audio",
                     detail: "Lets Mynah hear the other people on the call, not your screen. macOS asks once.") {
                    Button("Allow") {
                        Task {
                            await meetings.requestSystemAudioPermission()
                            audioAsked = true
                        }
                    }
                    .buttonStyle(.accent)
                }
                HStack {
                    Text("A small voice-detection model (about 2 MB) downloads when you finish.")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    Button("Cancel") { done() }.buttonStyle(.quiet)
                    Button("Turn on") {
                        settings.data.meetings.consentAcknowledged = true
                        settings.data.meetings.enabled = true
                        done()
                    }
                    .buttonStyle(.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!understood)
                }
                .padding(.top, 8)
            }
            .padding(22)
        }
        .frame(width: 540)
        .background(Theme.canvas)
    }

    private func step<Accessory: View>(_ number: Int, done: Bool, title: String, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.caption).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
        .animation(.easeOut(duration: 0.2), value: done)
    }
}
