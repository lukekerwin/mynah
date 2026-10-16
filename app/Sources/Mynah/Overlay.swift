import AppKit
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording(command: Bool, handsFree: Bool)
        case processing(command: Bool)
        case message(String)
    }

    @Published var phase: Phase = .hidden
    /// Drives the appear/disappear animation separately from `phase`, so the pill
    /// can shrink away before the panel is ordered out.
    @Published var visible = false
    @Published var levels: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    static let barCount = 16

    func push(level: Float) {
        // Speech RMS sits around 0.01-0.1; map to 0...1 on a log-ish curve.
        let scaled = min(1, max(0, (log10(max(level, 1e-4)) + 3.2) / 2.2))
        levels.removeFirst()
        levels.append(scaled)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// Small floating pill near the bottom of the screen that shows what Mynah is doing.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func show(_ phase: OverlayModel.Phase) {
        hideWork?.cancel()
        orderOutWork?.cancel()
        if case .recording = phase, model.phase == .hidden { model.resetLevels() }
        let appearing = model.phase == .hidden || !model.visible
        model.phase = phase
        if appearing { position() }
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { model.visible = true }
    }

    func flash(_ message: String, seconds: Double = 2.5) {
        show(.message(message))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        orderOutWork?.cancel()
        withAnimation(.easeIn(duration: 0.16)) { model.visible = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            self.model.phase = .hidden
            self.panel.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 18))
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    private var live: Bool {
        if case .recording = model.phase { return true }
        return false
    }

    private var command: Bool {
        switch model.phase {
        case .recording(true, _), .processing(true): return true
        default: return false
        }
    }

    private var glow: Color { command ? Theme.amber : Theme.teal }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(
                    Capsule()
                        .fill(Theme.pill)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .shadow(color: glow.opacity(live ? 0.35 : 0), radius: 14)
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
                .scaleEffect(model.visible ? 1 : 0.85, anchor: .bottom)
                .opacity(model.visible ? 1 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.phase)
            Spacer(minLength: 0).frame(height: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case let .recording(command, handsFree):
            HStack(spacing: 10) {
                if command {
                    Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                } else {
                    PulsingDot(color: Theme.teal)
                }
                Waveform(levels: model.levels, tint: command ? Theme.amber : Theme.pillText,
                         barWidth: 3, spacing: 3, minHeight: 3, maxHeight: 22)
                if handsFree {
                    Text("hands-free")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.pillText.opacity(0.55))
                        .padding(.leading, 2)
                }
            }
        case let .processing(command):
            HStack(spacing: 10) {
                ThinkingDots(color: command ? Theme.amber : Theme.teal)
                Text(command ? "Editing" : "Transcribing")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.pillText.opacity(0.9))
            }
        case let .message(text):
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.pillText.opacity(0.92))
                .lineLimit(1)
        }
    }
}

/// The "live" indicator: a dot with a soft breathing ring.
private struct PulsingDot: View {
    var color: Color
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.3)).frame(width: 14, height: 14)
                .scaleEffect(on ? 1.15 : 0.7).opacity(on ? 0 : 1)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Three dots rising in sequence, for the processing state.
private struct ThinkingDots: View {
    var color: Color
    @State private var step = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(color).frame(width: 5, height: 5)
                    .offset(y: step == i ? -3 : 0)
                    .opacity(step == i ? 1 : 0.55)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .onReceive(timer) { _ in step = (step + 1) % 3 }
    }
}
