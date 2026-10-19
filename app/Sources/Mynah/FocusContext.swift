import AppKit
import ApplicationServices

/// Where the text is going: the frontmost app, its window title, and what's
/// around the cursor. Captured at hotkey press, before focus can change.
struct FocusContext {
    var appName: String
    var bundleID: String?
    var windowTitle: String?
    var selectedText: String?
    /// Character immediately before the cursor, used to decide on a leading space.
    var precedingCharacter: Character?

    static func capture() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var ctx = FocusContext(appName: app?.localizedName ?? "Unknown", bundleID: app?.bundleIdentifier)
        guard let pid = app?.processIdentifier else { return ctx }

        let appElement = AXUIElementCreateApplication(pid)
        // This runs on the hotkey press; a busy app (Teams mid-call) must not stall it
        // for the default ~6 s per call.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        // Electron apps (Slack, VS Code, Cursor...) only expose their AX tree when asked.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) {
            ctx.windowTitle = attribute(window, kAXTitleAttribute)
        }
        guard let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) else { return ctx }

        if let selected: String = attribute(focused, kAXSelectedTextAttribute), !selected.isEmpty {
            ctx.selectedText = selected
        }
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location > 0 {
                var prev = CFRange(location: range.location - 1, length: 1)
                if let prevValue = AXValueCreate(.cfRange, &prev) {
                    var out: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(
                        focused, kAXStringForRangeParameterizedAttribute as CFString, prevValue, &out) == .success,
                       let s = out as? String {
                        ctx.precedingCharacter = s.last
                    }
                }
            }
        }
        return ctx
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
