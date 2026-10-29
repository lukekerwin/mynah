import AppKit
import Carbon.HIToolbox
import MynahCore

/// Inserts text into the frontmost app by pasting (then restores the clipboard),
/// or by typing it key by key where the clipboard doesn't reach.
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

    /// Pause between typed characters. Remote desktop clients drop keys sent faster.
    private static let keyInterval: UInt64 = 6_000_000

    /// Types `text` as real key presses, for remote desktops and VMs that block the
    /// clipboard. Each character becomes the key that produces it on the current layout:
    /// those clients forward key codes and ignore a key event's Unicode text. Stops if
    /// the user switches away from `bundleID` mid-way. Main actor: the Text Input
    /// Source calls behind `keymap()` trap off the main thread.
    @MainActor
    static func type(_ text: String, into bundleID: String?) async {
        let keys = keymap()
        let source = CGEventSource(stateID: .privateState)
        for ch in PlainText.keyboardFriendly(text) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            if let stroke = keys[ch] {
                await press(stroke, typing: ch, source)
            } else {
                // Not on the keyboard (emoji, accents behind dead keys): fine in local
                // apps, usually lost in a remote session.
                postUnicode(ch, source)
            }
            try? await Task.sleep(nanoseconds: keyInterval)
        }
    }

    private struct Keystroke {
        var key: CGKeyCode
        var shift: Bool
    }

    /// Character → key on the current keyboard layout, unshifted where possible. Option
    /// combinations are left out: in Windows, Option arrives as Alt and opens menus.
    private static func keymap() -> [Character: Keystroke] {
        var map: [Character: Keystroke] = ["\n": Keystroke(key: CGKeyCode(kVK_Return), shift: false),
                                           "\t": Keystroke(key: CGKeyCode(kVK_Tab), shift: false)]
        guard let layout = layoutData() else { return map }
        let bytes = CFDataGetBytePtr(layout)!
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboard in
            for shift in [false, true] {
                let modifiers = UInt32(shift ? (shiftKey >> 8) & 0xFF : 0)
                for key in 0..<128 where !(65...92).contains(key) {  // skip the keypad
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(keyboard, UInt16(key), UInt16(kUCKeyActionDown), modifiers,
                                                UInt32(LMGetKbdType()), 0, &deadKeys, chars.count, &length, &chars)
                    // A dead key produces nothing yet and leaves `deadKeys` set.
                    guard status == noErr, deadKeys == 0, length > 0 else { continue }
                    let string = String(utf16CodeUnits: chars, count: length)
                    guard string.count == 1, let ch = string.first, map[ch] == nil,
                          !ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
                    else { continue }
                    map[ch] = Keystroke(key: CGKeyCode(key), shift: shift)
                }
            }
        }
        return map
    }

    private static func layoutData() -> CFData? {
        for copy in [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource] {
            guard let source = copy()?.takeRetainedValue(),
                  let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        }
        return nil
    }

    /// Shift as a physical left Shift reports it: the generic flag plus the device bits
    /// for which Shift key and "not coalesced". With the generic flag alone, Windows App
    /// typed "/" for "?".
    private static let leftShift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue
        | UInt64(NX_DEVICELSHIFTKEYMASK) | UInt64(NX_NONCOALSESCEDMASK))

    /// Holds Shift as a real key press rather than only a flag: remote clients track
    /// modifier keys themselves. The key events also carry `ch` as their text, for
    /// clients that read that instead.
    private static func press(_ stroke: Keystroke, typing ch: Character, _ source: CGEventSource?) async {
        let flags: CGEventFlags = stroke.shift ? leftShift : []
        let text = ch == "\n" || ch == "\t" ? nil : ch
        if stroke.shift {
            post(CGKeyCode(kVK_Shift), down: true, flags: flags, source)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        post(stroke.key, down: true, flags: flags, text: text, source)
        post(stroke.key, down: false, flags: flags, text: text, source)
        if stroke.shift {
            try? await Task.sleep(nanoseconds: 2_000_000)
            post(CGKeyCode(kVK_Shift), down: false, flags: [], source)
        }
    }

    private static func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, text: Character? = nil,
                             _ source: CGEventSource?) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = flags
        if let text {
            let units = Array(String(text).utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event?.post(tap: .cghidEventTap)
    }

    private static func postUnicode(_ ch: Character, _ source: CGEventSource?) {
        post(0, down: true, flags: [], text: ch, source)
        post(0, down: false, flags: [], text: ch, source)
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
