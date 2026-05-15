import AppKit

final class SwitcherView: NSView {
    private enum Layout {
        static let cornerRadius: CGFloat = 24
        static let margin: CGFloat = 18
        static let titleHeight: CGFloat = 30
        static let cardGap: CGFloat = 14
        static let rowGap: CGFloat = 12
        static let cardCornerRadius: CGFloat = 8
        static let preferredCardWidthWithThumbnail: CGFloat = 232
        static let compactCardWidthWithThumbnail: CGFloat = 204
        static let minCardWidthWithThumbnail: CGFloat = 180
        static let preferredCardWidthWithoutThumbnail: CGFloat = 190
        static let compactCardWidthWithoutThumbnail: CGFloat = 172
        static let minCardWidthWithoutThumbnail: CGFloat = 150
        static let preferredCardHeightWithThumbnail: CGFloat = 202
        static let minCardHeightWithThumbnail: CGFloat = 164
        static let preferredCardHeightWithoutThumbnail: CGFloat = 160
        static let minCardHeightWithoutThumbnail: CGFloat = 136
        static let preferredThumbnailHeight: CGFloat = 126
        static let minThumbnailHeight: CGFloat = 92
        static let thumbnailTextAreaHeight: CGFloat = 72
        static let iconSize: CGFloat = 28
        static let largeIconSize: CGFloat = 54
    }

    private struct GridLayout {
        let contentRect: NSRect
        let columns: Int
        let rows: Int
        let visibleCount: Int
        let cardWidth: CGFloat
        let cardHeight: CGFloat
    }

    private let thumbnailManager = ThumbnailManager.shared
    private var windows: [SwitchableWindow] = []
    private var selectedIndex = 0
    private var hoverIndex: Int?
    private var showsThumbnails = false
    private var visibleStartIndex = 0
    private var trackingArea: NSTrackingArea?
    var onClickWindow: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func update(
        windows: [SwitchableWindow],
        selectedIndex: Int,
        showsThumbnails: Bool,
        preservesVisibleRange: Bool = false
    ) {
        let previousVisibleStartIndex = visibleStartIndex
        self.windows = windows
        self.showsThumbnails = showsThumbnails
        self.selectedIndex = clampedSelectedIndex(selectedIndex)
        hoverIndex = clampedHoverIndex(hoverIndex)
        if preservesVisibleRange {
            visibleStartIndex = clampedVisibleStartIndex(previousVisibleStartIndex)
        } else {
            centerVisibleStartIndex()
        }
        needsDisplay = true
    }

    func update(windows: [SwitchableWindow], selectedIndex: Int) {
        update(
            windows: windows,
            selectedIndex: selectedIndex,
            showsThumbnails: Settings.shared.enableWindowThumbnails
        )
    }

    func update(selectedIndex: Int, preservesVisibleRange: Bool = false) {
        self.selectedIndex = clampedSelectedIndex(selectedIndex)
        if preservesVisibleRange {
            visibleStartIndex = clampedVisibleStartIndex(visibleStartIndex)
        } else {
            centerVisibleStartIndex()
        }
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func preferredOverlaySize(fitting visibleFrame: NSRect) -> NSSize {
        let maxSize = NSSize(
            width: max(1, floor(visibleFrame.width * 0.90)),
            height: max(1, floor(visibleFrame.height * 0.80))
        )
        let plan = layoutPlan(fitting: maxSize)

        return NSSize(
            width: min(maxSize.width, plan.contentRect.width + Layout.margin * 2),
            height: min(maxSize.height, plan.contentRect.height + Layout.margin * 2 + Layout.titleHeight)
        )
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea

        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = cardIndex(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }

        selectedIndex = index
        needsDisplay = true
        onClickWindow?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawBackground()
        drawTitle()
        drawCards()
    }

    private func clampedSelectedIndex(_ index: Int) -> Int {
        guard !windows.isEmpty else {
            return 0
        }

        return min(max(index, 0), windows.count - 1)
    }

    private func clampedHoverIndex(_ index: Int?) -> Int? {
        guard let index, windows.indices.contains(index) else {
            return nil
        }

        return index
    }

    private func drawBackground() {
        let backgroundPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Layout.cornerRadius,
            yRadius: Layout.cornerRadius
        )
        NSColor.white.withAlphaComponent(0.045).setFill()
        backgroundPath.fill()

        NSColor(calibratedWhite: 0.72, alpha: 0.20).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()
    }

    private func drawTitle() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]

        "窗口切换".draw(
            in: NSRect(
                x: Layout.margin,
                y: bounds.height - Layout.margin - 22,
                width: bounds.width - Layout.margin * 2,
                height: 22
            ),
            withAttributes: attributes
        )
    }

    private func drawCards() {
        guard !windows.isEmpty else {
            drawEmptyState()
            return
        }

        for (index, cardRect) in visibleCardRects() {
            drawCard(windows[index], index: index, in: cardRect)
        }
    }

    private func contentRect() -> NSRect {
        NSRect(
            x: Layout.margin,
            y: Layout.margin,
            width: max(1, bounds.width - Layout.margin * 2),
            height: max(1, bounds.height - Layout.margin * 2 - Layout.titleHeight)
        )
    }

    private func visibleCardRects() -> [(index: Int, rect: NSRect)] {
        guard !windows.isEmpty else {
            return []
        }

        let layout = currentLayout()
        let visibleCount = layout.visibleCount
        let startIndex = clampedVisibleStartIndex(visibleStartIndex, visibleCount: visibleCount)
        let endIndex = min(windows.count, startIndex + visibleCount)
        var cardRects: [(index: Int, rect: NSRect)] = []

        for index in startIndex..<endIndex {
            let relativeIndex = index - startIndex
            let row = relativeIndex / layout.columns
            let column = relativeIndex % layout.columns
            let itemsInRow = min(layout.columns, endIndex - (startIndex + row * layout.columns))
            let rowWidth = CGFloat(itemsInRow) * layout.cardWidth +
                CGFloat(max(itemsInRow - 1, 0)) * Layout.cardGap
            let rowX = layout.contentRect.midX - rowWidth / 2
            let cardRect = NSRect(
                x: rowX + CGFloat(column) * (layout.cardWidth + Layout.cardGap),
                y: layout.contentRect.maxY - layout.cardHeight - CGFloat(row) * (layout.cardHeight + Layout.rowGap),
                width: layout.cardWidth,
                height: layout.cardHeight
            )
            cardRects.append((index: index, rect: cardRect))
        }

        return cardRects
    }

    private func centeredVisibleStartIndex(visibleCount: Int) -> Int {
        guard windows.count > visibleCount else {
            return 0
        }

        let centeredStart = selectedIndex - visibleCount / 2
        return min(max(centeredStart, 0), windows.count - visibleCount)
    }

    private func centerVisibleStartIndex() {
        visibleStartIndex = centeredVisibleStartIndex(visibleCount: currentLayout().visibleCount)
    }

    private func clampedVisibleStartIndex(_ startIndex: Int) -> Int {
        clampedVisibleStartIndex(startIndex, visibleCount: currentLayout().visibleCount)
    }

    private func clampedVisibleStartIndex(_ startIndex: Int, visibleCount: Int) -> Int {
        guard windows.count > visibleCount else {
            return 0
        }

        return min(max(startIndex, 0), windows.count - visibleCount)
    }

    func windowIndex(at point: NSPoint) -> Int? {
        cardIndex(at: point)
    }

    @discardableResult
    func updateHover(at point: NSPoint) -> Bool {
        let newHoverIndex = cardIndex(at: point)
        guard newHoverIndex != hoverIndex else {
            return newHoverIndex != nil
        }

        hoverIndex = newHoverIndex
        needsDisplay = true
        return newHoverIndex != nil
    }

    func clearHover() {
        guard hoverIndex != nil else {
            return
        }

        hoverIndex = nil
        needsDisplay = true
    }

    private func cardIndex(at point: NSPoint) -> Int? {
        visibleCardRects().first { _, rect in
            rect.contains(point)
        }?.index
    }

    private func currentLayout() -> GridLayout {
        layoutPlan(fitting: bounds.size)
    }

    private func layoutPlan(fitting maxSize: NSSize) -> GridLayout {
        let count = max(windows.count, 1)
        let maxContentWidth = max(1, maxSize.width - Layout.margin * 2)
        let maxContentHeight = max(1, maxSize.height - Layout.margin * 2 - Layout.titleHeight)
        let minCardWidth = showsThumbnails ? Layout.minCardWidthWithThumbnail : Layout.minCardWidthWithoutThumbnail
        let minCardHeight = showsThumbnails ? Layout.minCardHeightWithThumbnail : Layout.minCardHeightWithoutThumbnail
        let maxColumnsByWidth = max(1, Int((maxContentWidth + Layout.cardGap) / (minCardWidth + Layout.cardGap)))
        let maxRowsByHeight = max(1, min(3, Int((maxContentHeight + Layout.rowGap) / (minCardHeight + Layout.rowGap))))
        let rows = rowCount(
            forWindowCount: count,
            maxColumnsByWidth: maxColumnsByWidth,
            maxRowsByHeight: maxRowsByHeight,
            maxContentWidth: maxContentWidth,
            minCardWidth: minCardWidth
        )
        let neededColumns = Int(ceil(Double(count) / Double(rows)))
        let columns = max(1, min(neededColumns, maxColumnsByWidth))
        let visibleCount = min(count, columns * rows)
        let cardWidth = fittedCardWidth(
            windowCount: count,
            columns: columns,
            maxContentWidth: maxContentWidth,
            minCardWidth: minCardWidth
        )
        let cardHeight = fittedCardHeight(
            rows: rows,
            maxContentHeight: maxContentHeight,
            minCardHeight: minCardHeight
        )
        let contentWidth = CGFloat(columns) * cardWidth + CGFloat(max(columns - 1, 0)) * Layout.cardGap
        let contentHeight = CGFloat(rows) * cardHeight + CGFloat(max(rows - 1, 0)) * Layout.rowGap
        let contentRect = NSRect(
            x: Layout.margin,
            y: Layout.margin,
            width: min(maxContentWidth, contentWidth),
            height: min(maxContentHeight, contentHeight)
        )

        return GridLayout(
            contentRect: contentRect,
            columns: columns,
            rows: rows,
            visibleCount: visibleCount,
            cardWidth: cardWidth,
            cardHeight: cardHeight
        )
    }

    private func rowCount(
        forWindowCount count: Int,
        maxColumnsByWidth: Int,
        maxRowsByHeight: Int,
        maxContentWidth: CGFloat,
        minCardWidth: CGFloat
    ) -> Int {
        guard count > 6 else {
            let oneRowMinimumWidth = totalWidth(cardCount: count, cardWidth: minCardWidth)
            if oneRowMinimumWidth <= maxContentWidth {
                return 1
            }

            let rowsNeeded = Int(ceil(Double(count) / Double(maxColumnsByWidth)))
            return max(1, min(maxRowsByHeight, rowsNeeded))
        }

        let twoRowColumns = Int(ceil(Double(count) / 2.0))
        if maxRowsByHeight >= 2 && totalWidth(cardCount: twoRowColumns, cardWidth: minCardWidth) <= maxContentWidth {
            return 2
        }

        return max(1, min(3, maxRowsByHeight))
    }

    private func fittedCardWidth(
        windowCount count: Int,
        columns: Int,
        maxContentWidth: CGFloat,
        minCardWidth: CGFloat
    ) -> CGFloat {
        let preferredWidth: CGFloat
        if showsThumbnails {
            preferredWidth = count <= 6 ? Layout.preferredCardWidthWithThumbnail : Layout.compactCardWidthWithThumbnail
        } else {
            preferredWidth = count <= 6 ? Layout.preferredCardWidthWithoutThumbnail : Layout.compactCardWidthWithoutThumbnail
        }

        let gapWidth = CGFloat(max(columns - 1, 0)) * Layout.cardGap
        let availableWidth = max(minCardWidth, (maxContentWidth - gapWidth) / CGFloat(columns))
        return min(preferredWidth, availableWidth)
    }

    private func fittedCardHeight(
        rows: Int,
        maxContentHeight: CGFloat,
        minCardHeight: CGFloat
    ) -> CGFloat {
        let preferredHeight = showsThumbnails ?
            Layout.preferredCardHeightWithThumbnail :
            Layout.preferredCardHeightWithoutThumbnail
        let gapHeight = CGFloat(max(rows - 1, 0)) * Layout.rowGap
        let availableHeight = max(minCardHeight, (maxContentHeight - gapHeight) / CGFloat(rows))
        return min(preferredHeight, availableHeight)
    }

    private func totalWidth(cardCount: Int, cardWidth: CGFloat) -> CGFloat {
        CGFloat(cardCount) * cardWidth + CGFloat(max(cardCount - 1, 0)) * Layout.cardGap
    }

    private func drawCard(_ window: SwitchableWindow, index: Int, in cardRect: NSRect) {
        let isSelected = index == selectedIndex
        let isHovered = index == hoverIndex
        let cardPath = NSBezierPath(
            roundedRect: cardRect,
            xRadius: Layout.cardCornerRadius,
            yRadius: Layout.cardCornerRadius
        )

        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            cardPath.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.78).setStroke()
            cardPath.lineWidth = 2
            cardPath.stroke()
        } else if isHovered {
            NSColor.white.withAlphaComponent(0.20).setFill()
            cardPath.fill()
            NSColor(calibratedWhite: 0.72, alpha: 0.32).setStroke()
            cardPath.lineWidth = 1
            cardPath.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.14).setFill()
            cardPath.fill()
            NSColor(calibratedWhite: 0.72, alpha: 0.35).setStroke()
            cardPath.lineWidth = 1
            cardPath.stroke()
        }

        if showsThumbnails {
            drawThumbnailArea(for: window, in: thumbnailRect(in: cardRect))
            drawCardTextWithSmallIcon(for: window, in: cardRect)
        } else {
            drawIconOnlyCard(for: window, in: cardRect)
        }
    }

    private func thumbnailRect(in cardRect: NSRect) -> NSRect {
        let thumbnailHeight = min(
            Layout.preferredThumbnailHeight,
            max(Layout.minThumbnailHeight, cardRect.height - Layout.thumbnailTextAreaHeight)
        )
        return NSRect(
            x: cardRect.minX + 10,
            y: cardRect.maxY - 10 - thumbnailHeight,
            width: cardRect.width - 20,
            height: thumbnailHeight
        )
    }

    private func drawThumbnailArea(for window: SwitchableWindow, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)

        guard let thumbnail = thumbnailManager.cachedThumbnail(for: window) else {
            drawThumbnailPlaceholder(for: window, in: rect, path: path)
            return
        }

        NSColor.white.withAlphaComponent(0.16).setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawImage(thumbnail, aspectFitIn: rect)
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 0.70, alpha: 0.32).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawThumbnailPlaceholder(for window: SwitchableWindow, in rect: NSRect, path: NSBezierPath) {
        NSColor.white.withAlphaComponent(0.20).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.70, alpha: 0.30).setStroke()
        path.lineWidth = 1
        path.stroke()

        let iconRect = NSRect(
            x: rect.midX - Layout.largeIconSize / 2,
            y: rect.midY - Layout.largeIconSize / 2,
            width: Layout.largeIconSize,
            height: Layout.largeIconSize
        )
        drawIcon(window.appIcon, fallbackTitle: window.appName, in: iconRect, cornerRadius: 12)
    }

    private func drawCardTextWithSmallIcon(for window: SwitchableWindow, in cardRect: NSRect) {
        let iconRect = NSRect(
            x: cardRect.minX + 12,
            y: cardRect.minY + 28,
            width: Layout.iconSize,
            height: Layout.iconSize
        )
        drawIcon(window.appIcon, fallbackTitle: window.appName, in: iconRect, cornerRadius: 7)

        let textX = iconRect.maxX + 8
        let textWidth = cardRect.maxX - textX - 12
        drawText(
            window.appName,
            in: NSRect(x: textX, y: cardRect.minY + 38, width: textWidth, height: 18),
            font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            color: NSColor.labelColor
        )
        drawText(
            window.windowTitle,
            in: NSRect(x: textX, y: cardRect.minY + 17, width: textWidth, height: 18),
            font: NSFont.systemFont(ofSize: 11),
            color: NSColor.secondaryLabelColor
        )
    }

    private func drawIconOnlyCard(for window: SwitchableWindow, in cardRect: NSRect) {
        let iconRect = NSRect(
            x: cardRect.midX - Layout.largeIconSize / 2,
            y: cardRect.midY - Layout.largeIconSize / 2 + 34,
            width: Layout.largeIconSize,
            height: Layout.largeIconSize
        )
        drawIcon(window.appIcon, fallbackTitle: window.appName, in: iconRect, cornerRadius: 12)

        drawCenteredText(
            window.appName,
            in: NSRect(x: cardRect.minX + 12, y: cardRect.minY + 52, width: cardRect.width - 24, height: 20),
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            color: NSColor.labelColor
        )
        drawCenteredText(
            window.windowTitle,
            in: NSRect(x: cardRect.minX + 12, y: cardRect.minY + 28, width: cardRect.width - 24, height: 18),
            font: NSFont.systemFont(ofSize: 11),
            color: NSColor.secondaryLabelColor
        )
    }

    private func drawEmptyState() {
        drawCenteredText(
            "没有可切换窗口",
            in: NSRect(x: Layout.margin, y: bounds.midY - 12, width: bounds.width - Layout.margin * 2, height: 24),
            font: NSFont.systemFont(ofSize: 15, weight: .medium),
            color: NSColor.secondaryLabelColor
        )
    }

    private func drawIcon(_ image: NSImage?, fallbackTitle: String, in rect: NSRect, cornerRadius: CGFloat) {
        if let image {
            image.draw(in: rect)
            return
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.white.withAlphaComponent(0.26).setFill()
        path.fill()

        let initial = String(fallbackTitle.prefix(1)).uppercased()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(13, rect.height * 0.44), weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.72)
        ]
        let size = initial.size(withAttributes: attributes)
        initial.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawImage(_ image: NSImage, aspectFitIn rect: NSRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return
        }

        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        image.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        text.draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private func drawCenteredText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        text.draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
    }
}
