import CoreGraphics
import Foundation
import AppKit

final class HotKeyManager: @unchecked Sendable {
    static let shared = HotKeyManager()

    private enum KeyCode {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let leftControl: CGKeyCode = 59
        static let rightControl: CGKeyCode = 62
    }

    private let settings: Settings
    private let permissionManager: PermissionManager
    private let windowManager: WindowManager
    private let overlayWindow: SwitcherOverlayWindow

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseEventTap: CFMachPort?
    private var mouseRunLoopSource: CFRunLoopSource?

    private(set) var isSwitcherActive = false
    private(set) var selectedIndex = 0
    private(set) var currentWindows: [SwitchableWindow] = []
    private var isControlPressed = false

    init(
        settings: Settings = .shared,
        permissionManager: PermissionManager = .shared,
        windowManager: WindowManager = .shared,
        overlayWindow: SwitcherOverlayWindow = SwitcherOverlayWindow()
    ) {
        self.settings = settings
        self.permissionManager = permissionManager
        self.windowManager = windowManager
        self.overlayWindow = overlayWindow
        self.overlayWindow.onClickWindow = { [weak self] index in
            self?.activateClickedWindow(at: index)
        }
    }

    func applySettings() {
        guard settings.enableWindowSwitcher else {
            DebugLog.write("HotKey not started: window switcher disabled")
            stop()
            cancelSwitcher()
            return
        }

        guard permissionManager.hasAccessibilityPermission() else {
            DebugLog.write("HotKey not started: missing Accessibility")
            stop()
            cancelSwitcher()
            return
        }

        start()
    }

    private func start() {
        guard eventTap == nil else {
            enableTap()
            return
        }

        let eventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            DebugLog.write("HotKey event tap create failed")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            DebugLog.write("HotKey event tap run loop source create failed")
            CFMachPortInvalidate(tap)
            return
        }

        eventTap = tap
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.write("HotKey event tap started")
    }

    private func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
        runLoopSource = nil
        stopMouseTracking()
    }

    private func enableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            enableTap()
            return event
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            return handleFlagsChanged(event)
        default:
            return event
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == KeyCode.escape {
            guard isSwitcherActive else {
                return event
            }

            cancelSwitcher()
            return nil
        }

        guard keyCode == KeyCode.tab else {
            return event
        }

        guard isControlTab(event) else {
            return event
        }

        guard settings.enableWindowSwitcher else {
            return event
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return isSwitcherActive ? nil : event
        }

        if isSwitcherActive {
            selectNextWindow()
        } else {
            beginSwitcher()
        }

        return nil
    }

    private func handleFlagsChanged(_ event: CGEvent) -> CGEvent? {
        isControlPressed = event.flags.contains(.maskControl)

        guard isSwitcherActive else {
            return event
        }

        if !isControlPressed {
            activateSelectedWindow()
        }

        return event
    }

    private func beginSwitcher() {
        currentWindows = windowManager.getSwitchableWindows()
        DebugLog.write("HotKey begin switcher: windows=\(currentWindows.count)")
        selectedIndex = initialSelectedIndex(for: currentWindows)
        isSwitcherActive = true
        overlayWindow.show(windows: currentWindows, selectedIndex: selectedIndex)
        startMouseTracking()
    }

    private func selectNextWindow() {
        guard !currentWindows.isEmpty else {
            return
        }

        selectedIndex = (selectedIndex + 1) % currentWindows.count
        overlayWindow.update(selectedIndex: selectedIndex)
    }

    private func activateClickedWindow(at index: Int) {
        defer { resetSwitcherState() }

        guard isSwitcherActive else {
            DebugLog.write("HotKey click activate skipped: switcher inactive")
            return
        }

        selectedIndex = index
        guard currentWindows.indices.contains(selectedIndex) else {
            DebugLog.write("HotKey click activate skipped: selected index out of range")
            return
        }

        let didActivate = windowManager.activateWindow(currentWindows[selectedIndex])
        DebugLog.write("HotKey click activate selected: success=\(didActivate)")
    }

    private func activateSelectedWindow() {
        defer { resetSwitcherState() }

        guard currentWindows.indices.contains(selectedIndex) else {
            DebugLog.write("HotKey activate skipped: selected index out of range")
            return
        }

        let didActivate = windowManager.activateWindow(currentWindows[selectedIndex])
        DebugLog.write("HotKey activate selected: success=\(didActivate)")
    }

    private func cancelSwitcher() {
        resetSwitcherState()
    }

    private func resetSwitcherState() {
        isSwitcherActive = false
        isControlPressed = false
        selectedIndex = 0
        currentWindows.removeAll()
        stopMouseTracking()
        overlayWindow.hide()
    }

    private func startMouseTracking() {
        guard mouseEventTap == nil else {
            enableMouseTracking()
            return
        }

        let eventMask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.mouseEventTapCallback,
            userInfo: userInfo
        ) else {
            DebugLog.write("HotKey mouse event tap create failed")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            DebugLog.write("HotKey mouse event tap run loop source create failed")
            CFMachPortInvalidate(tap)
            return
        }

        mouseEventTap = tap
        mouseRunLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopMouseTracking() {
        if let tap = mouseEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = mouseRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let tap = mouseEventTap {
            CFMachPortInvalidate(tap)
        }

        mouseEventTap = nil
        mouseRunLoopSource = nil
    }

    private func enableMouseTracking() {
        if let mouseEventTap {
            CGEvent.tapEnable(tap: mouseEventTap, enable: true)
        }
    }

    private func handleMouseEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            enableMouseTracking()
            return event
        }

        guard isSwitcherActive else {
            return event
        }

        switch type {
        case .mouseMoved:
            updateSwitcherHover(for: event)
            return event
        case .leftMouseDown:
            guard let index = switcherIndex(for: event) else {
                return event
            }

            DebugLog.write("HotKey mouse click on switcher card: index=\(index)")
            activateClickedWindow(at: index)
            return nil
        default:
            return event
        }
    }

    private func updateSwitcherHover(for event: CGEvent) {
        let quartzPoint = NSPoint(x: event.location.x, y: event.location.y)

        if overlayWindow.updateHover(atScreenPoint: quartzPoint) {
            return
        }

        if overlayWindow.updateHover(atScreenPoint: appKitScreenPoint(fromQuartzPoint: quartzPoint)) {
            return
        }

        overlayWindow.clearHover()
    }

    private func switcherIndex(for event: CGEvent) -> Int? {
        let quartzPoint = NSPoint(x: event.location.x, y: event.location.y)

        if let index = overlayWindow.windowIndex(atScreenPoint: quartzPoint) {
            return index
        }

        return overlayWindow.windowIndex(atScreenPoint: appKitScreenPoint(fromQuartzPoint: quartzPoint))
    }

    private func appKitScreenPoint(fromQuartzPoint quartzPoint: NSPoint) -> NSPoint {
        let screenFrame = NSScreen.screens.reduce(NSRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }

        guard !screenFrame.isNull else {
            return quartzPoint
        }

        return NSPoint(x: quartzPoint.x, y: screenFrame.maxY - quartzPoint.y)
    }

    private func isControlTab(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let hasControl = isControlDown(event) || isControlPressed
        return hasControl &&
            !flags.contains(.maskCommand) &&
            !flags.contains(.maskAlternate) &&
            !flags.contains(.maskShift)
    }

    private func isControlDown(_ event: CGEvent) -> Bool {
        event.flags.contains(.maskControl) ||
            CGEventSource.keyState(.combinedSessionState, key: KeyCode.leftControl) ||
            CGEventSource.keyState(.combinedSessionState, key: KeyCode.rightControl)
    }

    private func initialSelectedIndex(for windows: [SwitchableWindow]) -> Int {
        guard windows.count > 1 else {
            return 0
        }

        if let frontmostIdentity = windowManager.currentFrontmostWindowIdentity(),
           let currentWindowIndex = windows.firstIndex(where: { $0.identity.matches(frontmostIdentity) }) {
            return (currentWindowIndex + 1) % windows.count
        }

        guard let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let currentWindowIndex = windows.firstIndex(where: { $0.processID == frontmostProcessID }) else {
            return 0
        }

        return (currentWindowIndex + 1) % windows.count
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        guard let handledEvent = manager.handleEvent(type: type, event: event) else {
            return nil
        }

        return Unmanaged.passUnretained(handledEvent)
    }

    private static let mouseEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        guard let handledEvent = manager.handleMouseEvent(type: type, event: event) else {
            return nil
        }

        return Unmanaged.passUnretained(handledEvent)
    }
}
