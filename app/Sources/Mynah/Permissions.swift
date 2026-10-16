import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Shows the system "allow Accessibility" prompt (only once per app identity).
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
