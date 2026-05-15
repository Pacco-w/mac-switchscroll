import AppKit

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let settings: Settings
    private let permissionManager: PermissionManager
    private let scrollEventManager: ScrollEventManager
    private let hotKeyManager: HotKeyManager

    private var smoothScrollItem: NSMenuItem?
    private var reverseScrollItem: NSMenuItem?
    private var windowSwitcherItem: NSMenuItem?
    private var windowThumbnailsItem: NSMenuItem?
    private var accessibilityStatusItem: NSMenuItem?
    private var screenRecordingStatusItem: NSMenuItem?

    init(
        settings: Settings = .shared,
        permissionManager: PermissionManager = .shared,
        scrollEventManager: ScrollEventManager = .shared,
        hotKeyManager: HotKeyManager = .shared
    ) {
        self.settings = settings
        self.permissionManager = permissionManager
        self.scrollEventManager = scrollEventManager
        self.hotKeyManager = hotKeyManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionsDidChange),
            name: .switchScrollPermissionsDidChange,
            object: nil
        )
        configureStatusItem()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            if let image = NSImage(named: "StatusBarIcon") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.title = ""
            } else {
                button.title = "切换滚动"
                button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            }
            button.toolTip = "SwitchScroll"
            statusItem.isVisible = true
        }

        statusItem.menu = makeMenu()
        updateMenuStates()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        smoothScrollItem = menuItem(title: "启用平滑滚动", action: #selector(toggleSmoothScroll))
        reverseScrollItem = menuItem(title: "反转鼠标滚轮方向", action: #selector(toggleReverseScrollDirection))
        windowSwitcherItem = menuItem(title: "启用窗口切换", action: #selector(toggleWindowSwitcher))
        windowThumbnailsItem = menuItem(title: "启用窗口缩略图", action: #selector(toggleWindowThumbnails))

        [
            smoothScrollItem,
            reverseScrollItem,
            windowSwitcherItem,
            windowThumbnailsItem
        ].compactMap { $0 }.forEach(menu.addItem)

        menu.addItem(.separator())
        accessibilityStatusItem = statusMenuItem(title: "辅助功能：未授权")
        screenRecordingStatusItem = statusMenuItem(title: "屏幕录制：未授权")
        [
            accessibilityStatusItem,
            screenRecordingStatusItem
        ].compactMap { $0 }.forEach(menu.addItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "打开辅助功能设置", action: #selector(openAccessibilitySettings)))
        menu.addItem(menuItem(title: "打开屏幕录制设置", action: #selector(openScreenRecordingSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "退出", action: #selector(quit)))

        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func statusMenuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func updateMenuStates() {
        smoothScrollItem?.state = settings.enableSmoothScroll ? .on : .off
        reverseScrollItem?.state = settings.reverseScrollDirection ? .on : .off
        windowSwitcherItem?.state = settings.enableWindowSwitcher ? .on : .off
        windowThumbnailsItem?.state = settings.enableWindowThumbnails ? .on : .off
        updatePermissionStates()
    }

    private func updatePermissionStates() {
        let accessibilityStatus = permissionManager.hasAccessibilityPermission() ? "已授权" : "未授权"
        let screenRecordingStatus = permissionManager.hasScreenRecordingPermission() ? "已授权" : "未授权"

        accessibilityStatusItem?.title = "辅助功能：\(accessibilityStatus)"
        screenRecordingStatusItem?.title = "屏幕录制：\(screenRecordingStatus)"
    }

    @objc private func toggleSmoothScroll() {
        settings.enableSmoothScroll.toggle()
        scrollEventManager.applySettings()
        updateMenuStates()
    }

    @objc private func toggleReverseScrollDirection() {
        settings.reverseScrollDirection.toggle()
        scrollEventManager.applySettings()
        updateMenuStates()
    }

    @objc private func toggleWindowSwitcher() {
        settings.enableWindowSwitcher.toggle()
        hotKeyManager.applySettings()
        updateMenuStates()
    }

    @objc private func toggleWindowThumbnails() {
        settings.enableWindowThumbnails.toggle()
        updateMenuStates()
    }

    @objc private func openAccessibilitySettings() {
        permissionManager.openAccessibilitySettings()
    }

    @objc private func openScreenRecordingSettings() {
        permissionManager.openScreenRecordingSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func permissionsDidChange() {
        updateMenuStates()
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuStates()
        scrollEventManager.applySettings()
        hotKeyManager.applySettings()
        permissionManager.refreshScreenRecordingPermission(force: true) { [weak self] _ in
            self?.updatePermissionStates()
        }
    }
}
