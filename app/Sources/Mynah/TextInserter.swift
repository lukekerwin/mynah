import AppKit
import Carbon.HIToolbox

/// Inserts text into the frontmost app by pasting, then restores the clipboard.
enum TextInserter {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func insert(_ text: String, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers not to record this entry.
        pasteboard.setData(Data(), forType: transientType)
        let ourChange = pasteboard.changeCount

        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        guard let saved else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Don't clobber something the user copied in the meantime.
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// Fallback for apps that don't expose selected text via Accessibility:
    /// send ⌘C and read what landed on the clipboard (then put the old contents back).
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        return text
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
