import AppKit

final class SwitcherOverlayWindow: NSPanel {
    private let visualEffectView = NSVisualEffectView()
    private let switcherView = SwitcherView()
    private let settings: Settings
    private let thumbnailManager: ThumbnailManager
    private let initialOverlaySize = NSSize(width: 860, height: 320)
    private var currentWindows: [SwitchableWindow] = []
    private var currentSelectedIndex = 0
    private var thumbnailPreloadTask: Task<Void, Never>?
    private var thumbnailReloadTask: Task<Void, Never>?
    var onClickWindow: ((Int) -> Void)?

    init(
        settings: Settings = .shared,
        thumbnailManager: ThumbnailManager = .shared
    ) {
        self.settings = settings
        self.thumbnailManager = thumbnailManager

        super.init(
            contentRect: NSRect(origin: .zero, size: initialOverlaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .aqua)
        isReleasedWhenClosed = false
        level = .statusBar
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        switcherView.onClickWindow = { [weak self] index in
            self?.handleClickWindow(at: index)
        }

        visualEffectView.frame = NSRect(origin: .zero, size: initialOverlaySize)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .aqua)
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 24
        visualEffectView.layer?.masksToBounds = true

        switcherView.frame = visualEffectView.bounds
        switcherView.autoresizingMask = [.width, .height]
        switcherView.appearance = NSAppearance(named: .aqua)
        visualEffectView.addSubview(switcherView)
        contentView = visualEffectView
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    func show(windows: [SwitchableWindow], selectedIndex: Int) {
        update(windows: windows, selectedIndex: selectedIndex)
        centerOnActiveScreen()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        preloadThumbnailsIfNeeded()
        reloadSelectedThumbnailIfNeeded()
    }

    func update(windows: [SwitchableWindow], selectedIndex: Int) {
        currentWindows = windows
        currentSelectedIndex = selectedIndex
        thumbnailManager.markSeen(windows: windows)
        switcherView.update(
            windows: windows,
            selectedIndex: selectedIndex,
            showsThumbnails: settings.enableWindowThumbnails
        )
        reloadSelectedThumbnailIfNeeded()
    }

    func update(selectedIndex: Int) {
        update(selectedIndex: selectedIndex, preservesVisibleRange: false)
    }

    func update(selectedIndex: Int, preservesVisibleRange: Bool) {
        currentSelectedIndex = selectedIndex
        switcherView.update(selectedIndex: selectedIndex, preservesVisibleRange: preservesVisibleRange)
        reloadSelectedThumbnailIfNeeded()
    }

    func hide() {
        thumbnailPreloadTask?.cancel()
        thumbnailPreloadTask = nil
        thumbnailReloadTask?.cancel()
        thumbnailReloadTask = nil
        currentWindows.removeAll()
        currentSelectedIndex = 0
        switcherView.clearHover()
        orderOut(nil)
    }

    private func centerOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        let preferredSize = switcherView.preferredOverlaySize(fitting: visibleFrame)
        setFrame(
            NSRect(
                x: visibleFrame.midX - preferredSize.width / 2,
                y: visibleFrame.midY - preferredSize.height / 2,
                width: preferredSize.width,
                height: preferredSize.height
            ),
            display: true
        )
        switcherView.update(selectedIndex: currentSelectedIndex)
    }

    private func preloadThumbnailsIfNeeded() {
        thumbnailPreloadTask?.cancel()

        guard settings.enableWindowThumbnails, !currentWindows.isEmpty else {
            return
        }

        let windows = currentWindows
        thumbnailManager.markSeen(windows: windows)
        thumbnailPreloadTask = Task { [weak self, thumbnailManager] in
            DebugLog.write("Thumbnail preload requested: windows=\(windows.count)")

            for window in windows {
                guard !Task.isCancelled else {
                    return
                }

                _ = await thumbnailManager.getThumbnail(for: window, refreshStale: true)

                await MainActor.run {
                    guard let self, self.isVisible else {
                        return
                    }

                    self.switcherView.update(
                        windows: self.currentWindows,
                        selectedIndex: self.currentSelectedIndex,
                        showsThumbnails: self.settings.enableWindowThumbnails,
                        preservesVisibleRange: true
                    )
                }
            }
        }
    }

    private func reloadSelectedThumbnailIfNeeded() {
        thumbnailReloadTask?.cancel()

        guard settings.enableWindowThumbnails,
              isVisible,
              currentWindows.indices.contains(currentSelectedIndex) else {
            return
        }

        let window = currentWindows[currentSelectedIndex]
        guard !thumbnailManager.hasFreshThumbnail(for: window) else {
            return
        }

        thumbnailReloadTask = Task { [weak self, thumbnailManager, window] in
            _ = await thumbnailManager.getThumbnail(for: window, refreshStale: true)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self, self.isVisible else {
                    return
                }

                self.switcherView.update(
                    windows: self.currentWindows,
                    selectedIndex: self.currentSelectedIndex,
                    showsThumbnails: self.settings.enableWindowThumbnails,
                    preservesVisibleRange: true
                )
            }
        }
    }

    private func handleClickWindow(at index: Int) {
        guard currentWindows.indices.contains(index) else {
            DebugLog.write("Switcher click ignored: index out of range \(index)")
            onClickWindow?(index)
            return
        }

        currentSelectedIndex = index
        onClickWindow?(index)
    }

    func windowIndex(atScreenPoint screenPoint: NSPoint) -> Int? {
        guard isVisible else {
            return nil
        }

        let windowPoint = convertPoint(fromScreen: screenPoint)
        return switcherView.windowIndex(at: windowPoint)
    }

    @discardableResult
    func updateHover(atScreenPoint screenPoint: NSPoint) -> Bool {
        guard isVisible else {
            return false
        }

        let windowPoint = convertPoint(fromScreen: screenPoint)
        return switcherView.updateHover(at: windowPoint)
    }

    func clearHover() {
        switcherView.clearHover()
    }
}
