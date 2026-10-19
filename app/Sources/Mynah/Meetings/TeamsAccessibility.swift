import AppKit
import ApplicationServices
import MynahCore

/// Reads the Teams call window through Accessibility (best effort): the meeting
/// title and whether the user is muted. Verified on new Teams (2026-10, English
/// UI): the call toolbar's mic button is "Unmute mic" while muted and "Mute mic"
/// while live; the call window is titled "<meeting> | Microsoft Teams".
///
/// A big meeting's tree (video tiles, chat) is large, so the call window and its
/// mic button are found once and then re-read directly; the search only runs
/// again when they go away.
enum TeamsAccessibility {
    struct CallState {
        var title: String?
        var muted: Bool?
        /// The call window (one with a "Leave" button) is open; nil if it can't be checked.
        var windowOpen: Bool?
        /// Accessibility is granted (otherwise nothing above can be read).
        var accessible = true
        /// From a fresh search that found the call window but no recognizable mic
        /// button: labels of the buttons that look mic-related, for the log.
        var micCandidates: [String]?
        /// From a search that found no call window: what the Teams windows held, for the log.
        var searchNote: String?
    }

    private struct Found {
        var pid: pid_t
        var window: AXUIElement
        var mic: AXUIElement?
        var at: Date
        var candidates: [String]
    }

    private static let lock = NSLock()
    private static var found: Found?
    /// A call window without a recognizable mic button is searched again after this.
    private static let researchAfter: TimeInterval = 10
    private static var lastMiss: String?

    static func read() -> CallState {
        guard Permissions.accessibilityGranted else { return CallState(accessible: false) }
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.bundleIdentifier == MeetingDetector.teamsPrefix })
            ?? apps.first(where: { $0.activationPolicy == .regular && $0.bundleIdentifier?.hasPrefix(MeetingDetector.teamsPrefix) == true })
        else { return CallState(windowOpen: false, searchNote: "Teams app not running") }
        lock.lock()
        defer { lock.unlock() }
        if let f = found, f.pid == app.processIdentifier,
           let title = AXDump.attr(f.window, kAXTitleAttribute) as? String {
            let muted = f.mic.flatMap(micState)
            if muted != nil || Date().timeIntervalSince(f.at) < researchAfter {
                return CallState(title: TeamsUI.meetingTitle(windowTitle: title), muted: muted, windowOpen: true)
            }
        }
        found = search(app.processIdentifier)
        guard let f = found else { return CallState(windowOpen: false, searchNote: lastMiss) }
        let title = AXDump.attr(f.window, kAXTitleAttribute) as? String
        return CallState(title: title.flatMap(TeamsUI.meetingTitle), muted: f.mic.flatMap(micState), windowOpen: true,
                         micCandidates: f.mic == nil ? f.candidates : nil)
    }

    private static func micState(_ button: AXUIElement) -> Bool? {
        TeamsUI.isMuted(buttonDescriptions: labels(button))
    }

    private static func labels(_ e: AXUIElement) -> [String] {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap { AXDump.attr(e, $0) as? String }.filter { !$0.isEmpty }
    }

    private static func search(_ pid: pid_t) -> Found? {
        let element = AXUIElementCreateApplication(pid)
        // Teams' web content only exposes its tree when asked: Electron listens for the
        // first attribute, Chromium web views (new Teams) for the second.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var seen: [String] = []
        for window in AXDump.children(element, kAXWindowsAttribute) {
            var budget = 20_000
            var leave = false
            var mic: AXUIElement?
            var candidates: [String] = []
            findButtons(window, depth: 0, budget: &budget, leave: &leave, mic: &mic, candidates: &candidates)
            // The call window is the one with a "Leave" button.
            if leave { return Found(pid: pid, window: window, mic: mic, at: Date(), candidates: candidates) }
            let title = AXDump.attr(window, kAXTitleAttribute) as? String ?? "?"
            seen.append("\"\(title)\" (\(20_000 - budget) elements\(candidates.isEmpty ? "" : ", buttons: " + candidates.joined(separator: " | ")))")
        }
        lastMiss = seen.isEmpty ? "no Teams windows" : seen.joined(separator: "; ")
        return nil
    }

    private static func findButtons(_ e: AXUIElement, depth: Int, budget: inout Int, leave: inout Bool,
                                    mic: inout AXUIElement?, candidates: inout [String]) {
        guard depth <= 50, budget > 0, !(leave && mic != nil) else { return }
        budget -= 1
        if (AXDump.attr(e, kAXRoleAttribute) as? String) == kAXButtonRole as String {
            let l = labels(e)
            if l.contains(where: { $0.lowercased().hasPrefix("leave") }) { leave = true }
            if mic == nil, TeamsUI.isMuted(buttonDescriptions: l) != nil { mic = e }
            let joined = l.joined(separator: " / ")
            if candidates.count < 8, ["mic", "mute", "audio", "leave", "hang up"].contains(where: joined.lowercased().contains) {
                candidates.append(joined)
            }
        }
        for child in AXDump.children(e) {
            findButtons(child, depth: depth + 1, budget: &budget, leave: &leave, mic: &mic, candidates: &candidates)
        }
    }
}
