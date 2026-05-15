import AppKit
import ApplicationServices
import CoreGraphics

extension Notification.Name {
    static let switchScrollPermissionsDidChange = Notification.Name("SwitchScrollPermissionsDidChange")
}

final class PermissionManager: @unchecked Sendable {
    static let shared = PermissionManager()

    func hasAccessibilityPermission() -> Bool {
        let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptOption: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func refreshScreenRecordingPermission(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        callOnMain(completion, with: hasScreenRecordingPermission())
    }

    func requestAccessibilityPermission() {
        let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptOption: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecordingPermission() {
        guard !hasScreenRecordingPermission() else {
            return
        }

        _ = CGRequestScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        requestAccessibilityPermission()
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        requestScreenRecordingPermission()
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func callOnMain(_ completion: ((Bool) -> Void)?, with value: Bool) {
        guard let completion else {
            return
        }

        DispatchQueue.main.async {
            completion(value)
        }
    }
}
