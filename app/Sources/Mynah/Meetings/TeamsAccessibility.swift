import AppKit
import ApplicationServices
import MynahCore

/// Reads the Teams call window through Accessibility (best effort): the meeting
/// title and whether the user is muted. Verified on new Teams (2026-10, English
/// UI): the call toolbar's mic button is "Unmute mic" while muted and "Mute mic"
/// while live; the call window is titled "<meeting> | Microsoft Teams".
enum TeamsAccessibility {
    struct CallState {
        var title: String?
        var muted: Bool?
    }

    static func read() -> CallState {
        guard Permissions.accessibilityGranted,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == MeetingDetector.teamsPrefix })
        else { return CallState() }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Teams' web content only exposes its tree when asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var state = CallState()
        for window in AXDump.children(element, kAXWindowsAttribute) {
            var buttons: [String] = []
            var budget = 2_000
            collectButtons(window, depth: 0, budget: &budget, into: &buttons)
            // The call window is the one with a "Leave" button.
            guard buttons.contains(where: { $0.lowercased().hasPrefix("leave") }) else { continue }
            if let title = AXDump.attr(window, kAXTitleAttribute) as? String {
                state.title = TeamsUI.meetingTitle(windowTitle: title)
            }
            state.muted = TeamsUI.isMuted(buttonDescriptions: buttons)
            break
        }
        return state
    }

    private static func collectButtons(_ e: AXUIElement, depth: Int, budget: inout Int, into out: inout [String]) {
        guard depth <= 30, budget > 0 else { return }
        budget -= 1
        if (AXDump.attr(e, kAXRoleAttribute) as? String) == kAXButtonRole as String {
            if let d = AXDump.attr(e, kAXDescriptionAttribute) as? String, !d.isEmpty { out.append(d) }
            if let t = AXDump.attr(e, kAXTitleAttribute) as? String, !t.isEmpty { out.append(t) }
        }
        for child in AXDump.children(e) {
            collectButtons(child, depth: depth + 1, budget: &budget, into: &out)
        }
    }
}
