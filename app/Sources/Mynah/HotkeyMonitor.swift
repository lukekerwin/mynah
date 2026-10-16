import AppKit

/// Watches a single modifier key (Fn by default) system-wide.
///
/// Global NSEvent monitors only receive events once the app is trusted for
/// Accessibility, so `start()` is safe to call again after permission is granted.
final class HotkeyMonitor {
    var hotkey: HotkeyChoice = .fn
    /// Called on key down; the Bool is true when Control is also held (command mode).
    var onPress: ((Bool) -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    /// ⌃⌥M (meeting recording: pause/resume my mic).
    var onPauseMic: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in
            self?.handle($0)
            return $0
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.onEscape?() }
            if e.keyCode == 46, e.modifierFlags.contains([.control, .option]),
               !e.modifierFlags.contains(.command) { self?.onPauseMic?() }
        }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let down = event.modifierFlags.contains(hotkey.flag)
        if down, !isDown {
            isDown = true
            onPress?(event.modifierFlags.contains(.control))
        } else if !down, isDown {
            isDown = false
            onRelease?()
        }
    }
}
