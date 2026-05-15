import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let scrollEventManager = ScrollEventManager.shared
    private let hotKeyManager = HotKeyManager.shared
    private let permissionManager = PermissionManager.shared
    private var permissionRefreshTimer: Timer?
    private var lastAccessibilityPermission: Bool?
    private var lastScreenRecordingPermission: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(settings: .shared)
        scrollEventManager.applySettings()
        hotKeyManager.applySettings()
        startPermissionMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = nil
    }

    private func startPermissionMonitor() {
        refreshPermissionDrivenManagers()

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPermissionDrivenManagers()
        }

        permissionRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshPermissionDrivenManagers() {
        let accessibilityPermission = permissionManager.hasAccessibilityPermission()
        let screenRecordingPermission = permissionManager.hasScreenRecordingPermission()
        let accessibilityChanged = lastAccessibilityPermission != accessibilityPermission
        let screenRecordingChanged = lastScreenRecordingPermission != screenRecordingPermission

        lastAccessibilityPermission = accessibilityPermission
        lastScreenRecordingPermission = screenRecordingPermission

        guard accessibilityChanged || screenRecordingChanged else {
            return
        }

        if accessibilityChanged {
            scrollEventManager.applySettings()
            hotKeyManager.applySettings()
        }

        NotificationCenter.default.post(name: .switchScrollPermissionsDidChange, object: nil)
    }
}
