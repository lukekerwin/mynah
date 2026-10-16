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
    @Published var levels: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    static let barCount = 14

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

/// Small floating pill near the bottom of the screen, like Wispr Flow's.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
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
        if case .recording = phase, model.phase == .hidden { model.resetLevels() }
        model.phase = phase
        position()
        panel.orderFrontRegardless()
    }

    func flash(_ message: String, seconds: Double = 2.5) {
        show(.message(message))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        model.phase = .hidden
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .animation(.easeOut(duration: 0.12), value: model.phase)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case let .recording(command, handsFree):
            HStack(spacing: 8) {
                if command {
                    Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                } else {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
                Bars(levels: model.levels, tint: command ? .purple : .white)
                if handsFree {
                    Text("hands-free").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
            }
        case let .processing(command):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text(command ? "Editing…" : "Transcribing…")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
        case let .message(text):
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
        }
    }
}

private struct Bars: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 3, height: 4 + CGFloat(level) * 18)
            }
        }
        .animation(.linear(duration: 0.06), value: levels)
    }
}
