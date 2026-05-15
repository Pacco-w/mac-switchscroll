import AppKit
import ApplicationServices

struct WindowIdentity: Hashable {
    private static let frameQuantum: CGFloat = 20

    let processID: pid_t
    let bundleIdentifier: String
    let frameKey: FrameKey
    let titleKey: String

    init(
        processID: pid_t,
        bundleIdentifier: String,
        title: String,
        frame: CGRect
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        frameKey = FrameKey(frame: frame, quantum: Self.frameQuantum)
        titleKey = Self.normalizedTitle(title)
    }

    func matches(_ other: WindowIdentity) -> Bool {
        guard processID == other.processID,
              bundleIdentifier == other.bundleIdentifier else {
            return false
        }

        if frameKey == other.frameKey, titleKey == other.titleKey {
            return true
        }

        if frameKey == other.frameKey {
            return true
        }

        return !titleKey.isEmpty && titleKey == other.titleKey
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    struct FrameKey: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(frame: CGRect, quantum: CGFloat) {
            x = Self.quantize(frame.origin.x, quantum: quantum)
            y = Self.quantize(frame.origin.y, quantum: quantum)
            width = Self.quantize(frame.width, quantum: quantum)
            height = Self.quantize(frame.height, quantum: quantum)
        }

        private static func quantize(_ value: CGFloat, quantum: CGFloat) -> Int {
            Int((value / quantum).rounded())
        }
    }
}

struct SwitchableWindow {
    let appName: String
    let bundleIdentifier: String
    let processID: pid_t
    let windowTitle: String
    let windowFrame: CGRect
    let identity: WindowIdentity
    let appIcon: NSImage?
    let axWindow: AXUIElement
    let isMinimized: Bool
    let isHidden: Bool
}

final class WindowManager {
    static let shared = WindowManager()

    private let permissionManager: PermissionManager
    private let mruTracker = WindowMRUTracker()
    private var activationObserver: NSObjectProtocol?

    init(permissionManager: PermissionManager = .shared) {
        self.permissionManager = permissionManager
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleActivatedApplication(notification)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func getSwitchableWindows() -> [SwitchableWindow] {
        guard permissionManager.hasAccessibilityPermission() else {
            return []
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let startTime = Date()

        recordCurrentFrontmostWindow()

        let candidateWindows = NSWorkspace.shared.runningApplications.flatMap { app -> [SwitchableWindow] in
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  app.processIdentifier != ownProcessID,
                  app.bundleIdentifier != ownBundleIdentifier else {
                return []
            }

            return windows(for: app)
        }
        let sortedWindows = mruTracker.sort(candidateWindows)
        mruTracker.prune(currentWindows: sortedWindows)

        let duration = Date().timeIntervalSince(startTime) * 1000
        DebugLog.write(
            "Window enumeration duration=\(Int(duration.rounded()))ms, " +
                "candidates=\(sortedWindows.count)"
        )
        return sortedWindows
    }

    @discardableResult
    func activateWindow(_ window: SwitchableWindow) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: window.processID)
        let shouldUnhide = window.isHidden || (runningApp?.isHidden ?? false)
        let unhideResult = shouldUnhide ? runningApp?.unhide() : nil
        let unminimizeResult: AXError? = window.isMinimized
            ? AXUIElementSetAttributeValue(
                window.axWindow,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            : nil
        let appElement = AXUIElementCreateApplication(window.processID)
        let frontmostResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        let mainResult = AXUIElementSetAttributeValue(
            appElement,
            kAXMainWindowAttribute as CFString,
            window.axWindow
        )
        let focusResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            window.axWindow
        )
        let raiseResult = AXUIElementPerformAction(window.axWindow, kAXRaiseAction as CFString)

        let activationOptions: NSApplication.ActivationOptions
        if #available(macOS 14.0, *) {
            activationOptions = [.activateAllWindows]
        } else {
            activationOptions = [.activateAllWindows, .activateIgnoringOtherApps]
        }

        let appActivated = runningApp?.activate(
            options: activationOptions
        ) ?? false

        let didActivate = appActivated ||
            frontmostResult == .success ||
            mainResult == .success ||
            focusResult == .success ||
            raiseResult == .success

        if !didActivate {
            DebugLog.write(
                "Window activate failed: app=\(window.appName), title=\(window.windowTitle), " +
                    "minimized=\(window.isMinimized), hidden=\(window.isHidden), " +
                    "unhide=\(Self.logValue(unhideResult)), " +
                    "unminimize=\(Self.logValue(unminimizeResult)), " +
                    "frontmost=\(frontmostResult.rawValue), main=\(mainResult.rawValue), " +
                    "focus=\(focusResult.rawValue), raise=\(raiseResult.rawValue)"
            )
        }

        if didActivate {
            mruTracker.recordActivated(window.identity)
        }

        return didActivate
    }

    func currentFrontmostWindowIdentity() -> WindowIdentity? {
        frontmostWindow()?.identity
    }

    private func windows(for app: NSRunningApplication) -> [SwitchableWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let axWindows = windowsForSwitcher(for: app, appElement: appElement)

        return axWindows.compactMap { makeSwitchableWindow(for: app, axWindow: $0) }
    }

    private func makeSwitchableWindow(
        for app: NSRunningApplication,
        axWindow: AXUIElement
    ) -> SwitchableWindow? {
        guard let frame = windowFrame(for: axWindow),
              isSwitchableWindow(axWindow, frame: frame, app: app) else {
            return nil
        }

        let title = copyAttribute(kAXTitleAttribute, from: axWindow) as? String ?? ""
        let bundleIdentifier = app.bundleIdentifier ?? ""
        let displayTitle = title.isEmpty ? "未命名窗口" : title
        return SwitchableWindow(
            appName: app.localizedName ?? "Unknown App",
            bundleIdentifier: bundleIdentifier,
            processID: app.processIdentifier,
            windowTitle: displayTitle,
            windowFrame: frame,
            identity: WindowIdentity(
                processID: app.processIdentifier,
                bundleIdentifier: bundleIdentifier,
                title: title,
                frame: frame
            ),
            appIcon: app.icon,
            axWindow: axWindow,
            isMinimized: isMinimized(axWindow),
            isHidden: isHidden(axWindow)
        )
    }

    private func handleActivatedApplication(_ notification: Notification) {
        guard permissionManager.hasAccessibilityPermission(),
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isEligibleApp(app) else {
            return
        }

        guard let window = focusedOrMainWindow(for: app) else {
            return
        }

        mruTracker.recordActivated(window.identity)
    }

    private func recordCurrentFrontmostWindow() {
        guard let window = frontmostWindow() else {
            return
        }

        mruTracker.recordActivated(window.identity)
    }

    private func frontmostWindow() -> SwitchableWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              isEligibleApp(app) else {
            return nil
        }

        return focusedOrMainWindow(for: app)
    }

    private func focusedOrMainWindow(for app: NSRunningApplication) -> SwitchableWindow? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            let (result, axWindow) = copyWindowAttribute(attribute, from: appElement)
            guard result == .success, let axWindow else {
                continue
            }

            if let window = makeSwitchableWindow(for: app, axWindow: axWindow) {
                return window
            }
        }

        return nil
    }

    private func isEligibleApp(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
            !app.isTerminated &&
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            app.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func windowsForSwitcher(
        for app: NSRunningApplication,
        appElement: AXUIElement
    ) -> [AXUIElement] {
        let (result, windows) = copyWindowsAttribute(from: appElement)
        if result == .success, !windows.isEmpty {
            return uniqueWindows(windows)
        }

        let fallback = fallbackWindows(for: app, appElement: appElement)
        if !fallback.windows.isEmpty {
            let sources = fallback.sources.joined(separator: ",")
            DebugLog.write(
                "Window AX fallback used: app=\(appLogName(app)), " +
                    "sources=\(sources), " +
                    "axWindowsResult=\(result.rawValue), axWindowsCount=\(windows.count)"
            )
            return uniqueWindows(fallback.windows)
        }

        DebugLog.write(
            "Window AXWindows empty: app=\(appLogName(app)), " +
                "result=\(result.rawValue), count=\(windows.count)"
        )
        return []
    }

    private func fallbackWindows(
        for app: NSRunningApplication,
        appElement: AXUIElement
    ) -> (windows: [AXUIElement], sources: [String]) {
        let attributes = [
            ("main", kAXMainWindowAttribute),
            ("focused", kAXFocusedWindowAttribute)
        ]
        var windows: [AXUIElement] = []
        var sources: [String] = []

        for (source, attribute) in attributes {
            let (result, window) = copyWindowAttribute(attribute, from: appElement)
            guard result == .success, let window else {
                continue
            }

            windows.append(window)
            sources.append(source)
        }

        return (uniqueWindows(windows), sources)
    }

    private func uniqueWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        var unique: [AXUIElement] = []
        for window in windows where !unique.contains(where: { CFEqual($0, window) }) {
            unique.append(window)
        }
        return unique
    }

    private func isSwitchableWindow(
        _ window: AXUIElement,
        frame: CGRect,
        app: NSRunningApplication
    ) -> Bool {
        guard isWindowRole(window),
              hasUserFacingSubrole(window, frame: frame, app: app),
              hasUsableFrame(frame) else {
            return false
        }

        let title = (copyAttribute(kAXTitleAttribute, from: window) as? String) ?? ""
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           frame.width < 120 || frame.height < 80 {
            return false
        }

        return true
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        copyAttribute(kAXMinimizedAttribute, from: window) as? Bool ?? false
    }

    private func isHidden(_ window: AXUIElement) -> Bool {
        copyAttribute(kAXHiddenAttribute, from: window) as? Bool ?? false
    }

    private func isWindowRole(_ window: AXUIElement) -> Bool {
        let role = copyAttribute(kAXRoleAttribute, from: window) as? String
        return role == nil || role == kAXWindowRole
    }

    private func hasUserFacingSubrole(
        _ window: AXUIElement,
        frame: CGRect,
        app: NSRunningApplication
    ) -> Bool {
        guard let subrole = copyAttribute(kAXSubroleAttribute, from: window) as? String else {
            return true
        }

        let blockedSubroles: Set<String> = [
            kAXSystemDialogSubrole,
            kAXFloatingWindowSubrole,
            "AXMenu",
            "AXMenuBar",
            "AXMenuItem",
            "AXPopover",
            "AXTooltip",
            "AXHelpTag",
            "AXSheet",
            "AXDrawer",
            "AXToolbar"
        ]

        if blockedSubroles.contains(subrole) {
            logSubroleFiltered(window, subrole: subrole, frame: frame, app: app, reason: "blocked")
            return false
        }

        let allowedSubroles: Set<String> = [
            kAXStandardWindowSubrole,
            kAXDialogSubrole,
            "AXDocumentWindow"
        ]

        if allowedSubroles.contains(subrole) {
            return true
        }

        let role = copyAttribute(kAXRoleAttribute, from: window) as? String
        let title = ((copyAttribute(kAXTitleAttribute, from: window) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasReasonableFrame = frame.width >= 120 && frame.height >= 80
        let hasLargeFrame = frame.width >= 300 && frame.height >= 200
        let shouldAllowUnknown = role == kAXWindowRole &&
            hasReasonableFrame &&
            (!title.isEmpty || hasLargeFrame)

        if !shouldAllowUnknown {
            logSubroleFiltered(window, subrole: subrole, frame: frame, app: app, reason: "unknown")
        }

        return shouldAllowUnknown
    }

    private func hasUsableFrame(_ frame: CGRect) -> Bool {
        frame.width >= 40 && frame.height >= 40
    }

    private func windowFrame(for window: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: window),
              let size = sizeAttribute(kAXSizeAttribute, from: window) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint,
              AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize,
              AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private func copyWindowsAttribute(from element: AXUIElement) -> (AXError, [AXUIElement]) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXWindowsAttribute as CFString,
            &value
        )

        guard result == .success else {
            return (result, [])
        }

        return (result, value as? [AXUIElement] ?? [])
    }

    private func copyWindowAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> (AXError, AXUIElement?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (result, nil)
        }

        let window = value as! AXUIElement
        return (result, window)
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )

        guard result == .success else {
            return nil
        }

        return value
    }

    private func logSubroleFiltered(
        _ window: AXUIElement,
        subrole: String,
        frame: CGRect,
        app: NSRunningApplication,
        reason: String
    ) {
        let title = (copyAttribute(kAXTitleAttribute, from: window) as? String) ?? ""
        DebugLog.write(
            "Window subrole filtered: app=\(appLogName(app)), " +
                "subrole=\(subrole), reason=\(reason), " +
                "title=\(title), frame=\(Self.logValue(frame))"
        )
    }

    private func appLogName(_ app: NSRunningApplication) -> String {
        let name = app.localizedName ?? "Unknown App"
        let bundleIdentifier = app.bundleIdentifier ?? "unknown.bundle"
        return "\(name) (\(bundleIdentifier), pid=\(app.processIdentifier))"
    }

    private static func logValue(_ frame: CGRect) -> String {
        "x=\(Int(frame.origin.x)),y=\(Int(frame.origin.y)),w=\(Int(frame.width)),h=\(Int(frame.height))"
    }

    private static func logValue(_ value: Bool?) -> String {
        value.map(String.init) ?? "not-needed"
    }

    private static func logValue(_ value: AXError?) -> String {
        value.map { String($0.rawValue) } ?? "not-needed"
    }
}

private final class WindowMRUTracker {
    private let maxEntries = 100
    private var entries: [WindowIdentity] = []

    func recordActivated(_ identity: WindowIdentity) {
        entries.removeAll { $0.matches(identity) }
        entries.insert(identity, at: 0)
        trim()
    }

    func sort(_ windows: [SwitchableWindow]) -> [SwitchableWindow] {
        windows.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(for: lhs.element.identity)
            let rhsRank = rank(for: rhs.element.identity)

            switch (lhsRank, rhsRank) {
            case let (lhsRank?, rhsRank?):
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.offset < rhs.offset
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    func prune(currentWindows: [SwitchableWindow]) {
        let currentIdentities = currentWindows.map(\.identity)
        entries.removeAll { entry in
            !currentIdentities.contains { $0.matches(entry) }
        }
        trim()
    }

    private func rank(for identity: WindowIdentity) -> Int? {
        entries.firstIndex { $0.matches(identity) }
    }

    private func trim() {
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }
}
