import AppKit
import Combine
import SwiftUI

/// The menu bar item and the panel that drops down from it. Done in AppKit rather
/// than SwiftUI's MenuBarExtra so opening, closing and the icon are fully under
/// our control.
@MainActor
final class StatusBarController {
    private let item: NSStatusItem
    private let panel: StatusPanel
    private let host: NSHostingView<MenuPanel>
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [Any] = []
    /// The window that was key before the panel took it, given back when it closes.
    private weak var previousKey: NSWindow?
    private weak var controller: AppController?

    private static let bird: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }()

    init(controller: AppController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200))

        let root = MenuPanel(controller: controller, settings: controller.settings,
                             engine: controller.engine, history: controller.history)
        host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Mynah"
            button.setAccessibilityLabel("Mynah")
        }

        var changes = controller.$phase.map { _ in () }.merge(with: controller.engine.$status.map { _ in () }).eraseToAnyPublisher()
        if let meetings = controller.meetings {
            changes = changes.merge(with: meetings.$state.map { _ in () }, meetings.$elapsed.map { _ in () }).eraseToAnyPublisher()
        }
        changes.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshIcon() }
            .store(in: &subscriptions)
        refreshIcon()
        panel.onCancel = { [weak self] in self?.hide() }

        // Focus moving to one of our own windows (the app window, onboarding) closes the panel too.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .compactMap { $0.object as? NSWindow }
            .filter { [weak self] window in window !== self?.panel }
            .sink { [weak self] _ in self?.hide() }
            .store(in: &subscriptions)
    }

    @objc private func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        guard let button = item.button, let screen = button.window?.screen ?? NSScreen.main else { return }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 10 || size.height < 10 { size = host.intrinsicContentSize }
        let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        previousKey = NSApp.keyWindow === panel ? nil : NSApp.keyWindow
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        // Any click outside the panel closes it: in other apps (global monitor) or
        // in our own windows (local monitor). The status item itself is excluded so
        // clicking it toggles instead of hide-then-show.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, event.window !== self.item.button?.window { self.hide() }
            return event
        }) { monitors.append(local) }
    }

    func hide() {
        guard panel.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        item.button?.highlight(false)
        panel.orderOut(nil)
        // Closed with Escape or an action: otherwise no window is left key and typing
        // goes nowhere. (A click in another app deactivates Mynah, so nothing to do.)
        if let w = previousKey, w.isVisible, NSApp.isActive, NSApp.keyWindow == nil { w.makeKey() }
        previousKey = nil
    }

    private func refreshIcon() {
        guard let button = item.button, let controller else { return }
        // A meeting being recorded shows as a red dot and the call timer (dictation wins while it runs).
        if let meetings = controller.meetings, meetings.isRecording, controller.phase == .idle {
            button.image = recordingDot
            button.imagePosition = .imageLeading
            button.title = " " + meetings.elapsed
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            item.length = NSStatusItem.variableLength
            return
        }
        if !button.title.isEmpty {
            button.title = ""
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
        }
        let symbol: String?
        switch controller.phase {
        case .recording: symbol = "record.circle"
        case .processing: symbol = "ellipsis.circle"
        case .idle:
            switch controller.engine.status {
            case .ready: symbol = nil
            case .failed: symbol = "exclamationmark.triangle"
            default: symbol = "arrow.down.circle"
            }
        }
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mynah")
        } else {
            button.image = Self.bird ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Mynah")
        }
    }
}

/// Borderless, non-activating panel that can still take keyboard focus so the
/// buttons inside it work without bringing the whole app forward.
private final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
