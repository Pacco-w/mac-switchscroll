import CoreGraphics
import Foundation

final class ScrollEventManager: @unchecked Sendable {
    static let shared = ScrollEventManager()

    private static let eventSourceMarker: Int64 = 0x53575343524C
    private static let fixedPointScale: Int64 = 65_536
    private static let mosStep: Double = 33.6
    private static let mosGain: Double = 2.7
    private static let mosDuration: Double = 4.35
    private static let frameInterval: TimeInterval = 1.0 / 120.0
    private static let deadZone: Double = 1.0
    private static let maxBuffer: Double = 600.0
    private static let accelerationWindow: TimeInterval = 0.12
    private static let accelerationStep: Double = 0.18
    private static let maxAccelerationMultiplier: Double = 2.2
    private static let burstDecay: Double = 0.65
    private static let mosBaseTransition = 1.0 - sqrt(mosDuration / 5.2)
    private static let mosTransition = 1.0 - pow(1.0 - mosBaseTransition, 60.0 * frameInterval)
    private static let smoothFrameDispatchInterval: DispatchTimeInterval = .nanoseconds(
        Int(frameInterval * 1_000_000_000)
    )

    private let settings: Settings
    private let permissionManager: PermissionManager
    private let smoothQueue = DispatchQueue(label: "com.switchscroll.smooth-scroll")
    private let stateLock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHandlingEvent = false
    private var currentAxis1 = 0.0
    private var currentAxis2 = 0.0
    private var bufferAxis1 = 0.0
    private var bufferAxis2 = 0.0
    private var lastInputAxis1 = 0.0
    private var lastInputAxis2 = 0.0
    private var isAnimating = false
    private var filterAxis1 = MosScrollFilter()
    private var filterAxis2 = MosScrollFilter()
    private var lastWheelInputTimeAxis1: TimeInterval = 0
    private var lastWheelInputTimeAxis2: TimeInterval = 0
    private var wheelBurstCountAxis1 = 0.0
    private var wheelBurstCountAxis2 = 0.0
    private var lastInputDirectionAxis1 = 0
    private var lastInputDirectionAxis2 = 0
    private var smoothTimer: DispatchSourceTimer?
    private var scrollDebugBudget = 36

    init(settings: Settings = .shared, permissionManager: PermissionManager = .shared) {
        self.settings = settings
        self.permissionManager = permissionManager
    }

    func applySettings() {
        if !settings.enableSmoothScroll {
            cancelSmoothScroll()
        }

        guard settings.reverseScrollDirection || settings.enableSmoothScroll else {
            stop()
            return
        }

        guard permissionManager.hasAccessibilityPermission() else {
            stop()
            return
        }

        start()
    }

    private func start() {
        guard eventTap == nil else {
            enableTap()
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            DebugLog.write("Scroll event tap create failed")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            DebugLog.write("Scroll event tap run loop source create failed")
            CFMachPortInvalidate(tap)
            return
        }

        eventTap = tap
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.write("Scroll event tap started")
    }

    private func stop() {
        cancelSmoothScroll()

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
    }

    private func enableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func handleScrollEvent(_ event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventSourceMarker else {
            return event
        }

        guard !isHandlingEvent else {
            return event
        }

        let components = ScrollComponents(event: event)
        let isMouseWheel = isMouseWheelEvent(components)
        let isSmoothableMouseWheel = isSmoothableMouseWheelEvent(components)
        let shouldReverse = settings.reverseScrollDirection && isMouseWheel
        let shouldSmooth = settings.enableSmoothScroll && isSmoothableMouseWheel

        guard shouldReverse || shouldSmooth else {
            logScrollDecision("pass", components: components, isMouseWheel: isMouseWheel)
            return event
        }

        isHandlingEvent = true
        defer { isHandlingEvent = false }

        var output = components
        if shouldReverse {
            output.invert()
        }

        if shouldSmooth {
            if enqueueSmoothScroll(from: output) {
                logScrollDecision("smooth", components: components, isMouseWheel: isMouseWheel)
                return nil
            }

            postImmediateScroll(output)
            logScrollDecision("smooth-fallback-immediate", components: components, isMouseWheel: isMouseWheel)
            return nil
        }

        postImmediateScroll(output)
        logScrollDecision("immediate", components: components, isMouseWheel: isMouseWheel)
        return nil
    }

    private func isMouseWheelEvent(_ components: ScrollComponents) -> Bool {
        if !components.isContinuous {
            return true
        }

        guard !components.hasScrollPhase else {
            return false
        }

        return components.hasAnyDelta
    }

    private func isSmoothableMouseWheelEvent(_ components: ScrollComponents) -> Bool {
        guard !components.isContinuous, !components.hasScrollPhase else {
            return false
        }

        return components.deltaAxis1 != 0 || components.deltaAxis2 != 0
    }

    private func enqueueSmoothScroll(from components: ScrollComponents) -> Bool {
        var timerToResume: DispatchSourceTimer?
        var leadingDelta = PixelScrollDelta(axis1: 0, axis2: 0)
        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()

        let targetDelta = scrollTargetDeltaLocked(from: components, now: now)

        guard !targetDelta.isEmpty else {
            stateLock.unlock()
            return false
        }

        // Input delta accumulation: consecutive wheel notches move the same target buffer.
        applyInputLocked(targetDelta.axis1, axis: .axis1)
        applyInputLocked(targetDelta.axis2, axis: .axis2)
        isAnimating = true

        // Low latency: advance the Mos-like curve immediately instead of waiting for the timer.
        leadingDelta = nextMosDeltaLocked()

        if smoothTimer == nil, hasSmoothWorkLocked() {
            let timer = DispatchSource.makeTimerSource(queue: smoothQueue)
            // Timer lifecycle: run at high frequency only while pending scroll work exists.
            timer.schedule(
                deadline: .now() + Self.smoothFrameDispatchInterval,
                repeating: Self.smoothFrameDispatchInterval
            )
            timer.setEventHandler { [weak self] in
                self?.emitSmoothScrollTick()
            }
            smoothTimer = timer
            timerToResume = timer
        }
        stateLock.unlock()

        if !leadingDelta.isBelowThreshold(Self.deadZone) {
            postPixelScroll(leadingDelta)
        }

        timerToResume?.resume()
        return true
    }

    private func emitSmoothScrollTick() {
        var delta = PixelScrollDelta(axis1: 0, axis2: 0)
        var timerToCancel: DispatchSourceTimer?

        stateLock.lock()

        guard settings.enableSmoothScroll else {
            timerToCancel = clearSmoothScrollStateLocked()
            stateLock.unlock()
            timerToCancel?.cancel()
            return
        }

        delta = nextMosDeltaLocked()

        if !hasSmoothWorkLocked() {
            timerToCancel = clearSmoothScrollStateLocked()
        }

        stateLock.unlock()

        if !delta.isBelowThreshold(Self.deadZone) {
            postPixelScroll(delta)
        }

        timerToCancel?.cancel()
    }

    private func applyInputLocked(_ targetDelta: Double, axis: SmoothAxis) {
        guard targetDelta != 0 else {
            return
        }

        switch axis {
        case .axis1:
            Self.applyInput(
                targetDelta,
                current: &currentAxis1,
                buffer: &bufferAxis1,
                lastInput: &lastInputAxis1,
                filter: &filterAxis1
            )
        case .axis2:
            Self.applyInput(
                targetDelta,
                current: &currentAxis2,
                buffer: &bufferAxis2,
                lastInput: &lastInputAxis2,
                filter: &filterAxis2
            )
        }
    }

    private static func applyInput(
        _ targetDelta: Double,
        current: inout Double,
        buffer: inout Double,
        lastInput: inout Double,
        filter: inout MosScrollFilter
    ) {
        let remaining = buffer - current
        let isDirectionChange = signsOppose(remaining, targetDelta) || signsOppose(lastInput, targetDelta)

        if isDirectionChange {
            current = 0
            buffer = targetDelta
            filter.reset()
        } else {
            buffer += targetDelta
        }

        buffer = limitedBuffer(current: current, buffer: buffer)
        lastInput = targetDelta
    }

    private func nextMosDeltaLocked() -> PixelScrollDelta {
        // Mos-like curve: current follows buffer by transition; a small filter softens frame peaks.
        return PixelScrollDelta(
            axis1: Self.nextMosStep(
                current: &currentAxis1,
                buffer: bufferAxis1,
                filter: &filterAxis1
            ),
            axis2: Self.nextMosStep(
                current: &currentAxis2,
                buffer: bufferAxis2,
                filter: &filterAxis2
            )
        )
    }

    private static func nextMosStep(
        current: inout Double,
        buffer: Double,
        filter: inout MosScrollFilter
    ) -> Double {
        let remaining = buffer - current
        let frame = abs(remaining) > deadZone ? remaining * mosTransition : 0
        current += frame
        return filter.fill(with: frame)
    }

    private func scrollTargetDeltaLocked(from components: ScrollComponents, now: TimeInterval) -> PixelScrollDelta {
        PixelScrollDelta(
            axis1: scrollTargetAxisDeltaLocked(Double(components.deltaAxis1), axis: .axis1, now: now),
            axis2: scrollTargetAxisDeltaLocked(Double(components.deltaAxis2), axis: .axis2, now: now)
        )
    }

    private func scrollTargetAxisDeltaLocked(_ rawDelta: Double, axis: SmoothAxis, now: TimeInterval) -> Double {
        guard rawDelta != 0 else {
            return 0
        }

        let sign = rawDelta >= 0 ? 1.0 : -1.0
        let normalized = max(abs(rawDelta), Self.mosStep) * sign
        let multiplier = accelerationMultiplierLocked(direction: sign > 0 ? 1 : -1, axis: axis, now: now)

        // Dynamic gain: slow wheel input stays at mosGain; short same-direction bursts ramp up.
        return normalized * Self.mosGain * multiplier
    }

    private func accelerationMultiplierLocked(direction: Int, axis: SmoothAxis, now: TimeInterval) -> Double {
        switch axis {
        case .axis1:
            return Self.updateAccelerationMultiplier(
                direction: direction,
                now: now,
                lastInputTime: &lastWheelInputTimeAxis1,
                burstCount: &wheelBurstCountAxis1,
                lastDirection: &lastInputDirectionAxis1
            )
        case .axis2:
            return Self.updateAccelerationMultiplier(
                direction: direction,
                now: now,
                lastInputTime: &lastWheelInputTimeAxis2,
                burstCount: &wheelBurstCountAxis2,
                lastDirection: &lastInputDirectionAxis2
            )
        }
    }

    private static func updateAccelerationMultiplier(
        direction: Int,
        now: TimeInterval,
        lastInputTime: inout TimeInterval,
        burstCount: inout Double,
        lastDirection: inout Int
    ) -> Double {
        let interval = lastInputTime > 0 ? now - lastInputTime : .infinity

        if lastDirection == direction, interval < accelerationWindow {
            // Burst count grows only for quick same-direction wheel input.
            burstCount += 1
        } else if lastDirection == direction {
            // After a pause, decay old acceleration so the next slow notch feels normal.
            burstCount *= burstDecay
            if interval >= accelerationWindow {
                burstCount = 0
            }
        } else {
            // Direction changes must not inherit acceleration from the previous direction.
            burstCount = 0
        }

        lastInputTime = now
        lastDirection = direction
        return min(1.0 + burstCount * accelerationStep, maxAccelerationMultiplier)
    }

    private static func signsOppose(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs) > deadZone && abs(rhs) > deadZone && (lhs > 0) != (rhs > 0)
    }

    private static func limitedBuffer(current: Double, buffer: Double) -> Double {
        let remaining = buffer - current
        let limitedRemaining = max(-maxBuffer, min(maxBuffer, remaining))
        return current + limitedRemaining
    }

    private func cancelSmoothScroll() {
        stateLock.lock()
        let timerToCancel = clearSmoothScrollStateLocked()
        stateLock.unlock()
        timerToCancel?.cancel()
    }

    private func clearSmoothScrollStateLocked() -> DispatchSourceTimer? {
        let timer = smoothTimer
        smoothTimer = nil
        currentAxis1 = 0
        currentAxis2 = 0
        bufferAxis1 = 0
        bufferAxis2 = 0
        lastInputAxis1 = 0
        lastInputAxis2 = 0
        lastWheelInputTimeAxis1 = 0
        lastWheelInputTimeAxis2 = 0
        wheelBurstCountAxis1 = 0
        wheelBurstCountAxis2 = 0
        lastInputDirectionAxis1 = 0
        lastInputDirectionAxis2 = 0
        isAnimating = false
        filterAxis1.reset()
        filterAxis2.reset()
        return timer
    }

    private func hasSmoothWorkLocked() -> Bool {
        isAnimating &&
            (
                abs(bufferAxis1 - currentAxis1) > Self.deadZone ||
                    abs(bufferAxis2 - currentAxis2) > Self.deadZone ||
                    filterAxis1.hasWork(threshold: Self.deadZone) ||
                    filterAxis2.hasWork(threshold: Self.deadZone)
            )
    }

    private func postImmediateScroll(_ components: ScrollComponents) {
        let units = components.usesPixelUnits ? CGScrollEventUnit.pixel : .line

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 2,
            wheel1: components.primaryWheelValue(units: units),
            wheel2: components.secondaryWheelValue(units: units),
            wheel3: 0
        ) else {
            return
        }

        components.apply(to: event)
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventSourceMarker)
        event.post(tap: .cghidEventTap)
    }

    private func postPixelScroll(_ delta: PixelScrollDelta) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: delta.primaryWheelValue,
            wheel2: delta.secondaryWheelValue,
            wheel3: 0
        ) else {
            return
        }

        // Synthetic event guard: mark generated events so the tap never smooths its own output.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: delta.pointAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: delta.pointAxis2)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta.fixedPointAxis1(scale: Self.fixedPointScale))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: delta.fixedPointAxis2(scale: Self.fixedPointScale))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventSourceMarker)
        event.post(tap: .cghidEventTap)
    }

    private func logScrollDecision(
        _ action: String,
        components: ScrollComponents,
        isMouseWheel: Bool
    ) {
        #if DEBUG
        guard scrollDebugBudget > 0 else {
            return
        }

        scrollDebugBudget -= 1
        DebugLog.write(
            "Scroll event action=\(action), mouse=\(isMouseWheel), " +
                "reverse=\(settings.reverseScrollDirection), smooth=\(settings.enableSmoothScroll), " +
                "continuous=\(components.isContinuous), phase=\(components.scrollPhase), " +
                "momentum=\(components.momentumPhase), " +
                "delta=(\(components.deltaAxis1),\(components.deltaAxis2)), " +
                "point=(\(components.pointDeltaAxis1),\(components.pointDeltaAxis2)), " +
                "fixed=(\(components.fixedPtDeltaAxis1),\(components.fixedPtDeltaAxis2))"
        )
        #endif
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let manager = Unmanaged<ScrollEventManager>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            manager.enableTap()
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        guard let handledEvent = manager.handleScrollEvent(event) else {
            return nil
        }

        return Unmanaged.passUnretained(handledEvent)
    }
}

private enum SmoothAxis {
    case axis1
    case axis2
}

private struct MosScrollFilter {
    private var window = [0.0, 0.0]

    mutating func fill(with nextValue: Double) -> Double {
        let first = window.count > 1 ? window[1] : 0
        let diff = nextValue - first
        window = [
            first,
            first + 0.23 * diff,
            first + 0.5 * diff,
            first + 0.77 * diff,
            nextValue
        ]
        return first
    }

    func hasWork(threshold: Double) -> Bool {
        window.contains { abs($0) > threshold }
    }

    mutating func reset() {
        window = [0.0, 0.0]
    }
}

private struct ScrollComponents {
    private static let fixedPointScale: Int64 = 65_536

    var deltaAxis1: Int64
    var deltaAxis2: Int64
    var pointDeltaAxis1: Int64
    var pointDeltaAxis2: Int64
    var fixedPtDeltaAxis1: Int64
    var fixedPtDeltaAxis2: Int64
    var isContinuous: Bool
    var scrollPhase: Int64
    var momentumPhase: Int64

    init(event: CGEvent) {
        self.deltaAxis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        self.deltaAxis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        self.pointDeltaAxis1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        self.pointDeltaAxis2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        self.fixedPtDeltaAxis1 = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
        self.fixedPtDeltaAxis2 = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
        self.isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        self.scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        self.momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    }

    var hasScrollPhase: Bool {
        scrollPhase != 0 || momentumPhase != 0
    }

    var hasAnyDelta: Bool {
        deltaAxis1 != 0 ||
            deltaAxis2 != 0 ||
            pointDeltaAxis1 != 0 ||
            pointDeltaAxis2 != 0 ||
            fixedPtDeltaAxis1 != 0 ||
            fixedPtDeltaAxis2 != 0
    }

    var usesPixelUnits: Bool {
        isContinuous ||
            pointDeltaAxis1 != 0 ||
            pointDeltaAxis2 != 0 ||
            fixedPtDeltaAxis1 != 0 ||
            fixedPtDeltaAxis2 != 0
    }

    mutating func invert() {
        deltaAxis1 = -deltaAxis1
        deltaAxis2 = -deltaAxis2
        pointDeltaAxis1 = -pointDeltaAxis1
        pointDeltaAxis2 = -pointDeltaAxis2
        fixedPtDeltaAxis1 = -fixedPtDeltaAxis1
        fixedPtDeltaAxis2 = -fixedPtDeltaAxis2
    }

    func apply(to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: deltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: deltaAxis2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pointDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pointDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedPtDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: isContinuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    }

    func primaryWheelValue(units: CGScrollEventUnit) -> Int32 {
        switch units {
        case .pixel:
            return clampedInt32(pixelWheelValue(
                pointDelta: pointDeltaAxis1,
                fixedPointDelta: fixedPtDeltaAxis1,
                lineDelta: deltaAxis1
            ))
        case .line:
            return clampedInt32(deltaAxis1)
        @unknown default:
            return clampedInt32(deltaAxis1)
        }
    }

    func secondaryWheelValue(units: CGScrollEventUnit) -> Int32 {
        switch units {
        case .pixel:
            return clampedInt32(pixelWheelValue(
                pointDelta: pointDeltaAxis2,
                fixedPointDelta: fixedPtDeltaAxis2,
                lineDelta: deltaAxis2
            ))
        case .line:
            return clampedInt32(deltaAxis2)
        @unknown default:
            return clampedInt32(deltaAxis2)
        }
    }

    private func pixelWheelValue(
        pointDelta: Int64,
        fixedPointDelta: Int64,
        lineDelta: Int64
    ) -> Int64 {
        if pointDelta != 0 {
            return pointDelta
        }

        let fixedPointPixels = fixedPointDelta / Self.fixedPointScale
        if fixedPointPixels != 0 {
            return fixedPointPixels
        }

        return lineDelta
    }

    private func clampedInt32(_ value: Int64) -> Int32 {
        Int32(max(Int64(Int32.min), min(Int64(Int32.max), value)))
    }
}

private struct PixelScrollDelta: Sendable {
    let axis1: Double
    let axis2: Double

    var isEmpty: Bool {
        axis1 == 0 && axis2 == 0
    }

    func isBelowThreshold(_ threshold: Double) -> Bool {
        abs(axis1) <= threshold && abs(axis2) <= threshold
    }

    var primaryWheelValue: Int32 {
        clampedInt32(axis1)
    }

    var secondaryWheelValue: Int32 {
        clampedInt32(axis2)
    }

    var pointAxis1: Int64 {
        Int64(axis1.rounded())
    }

    var pointAxis2: Int64 {
        Int64(axis2.rounded())
    }

    func fixedPointAxis1(scale: Int64) -> Int64 {
        fixedPointValue(axis1, scale: scale)
    }

    func fixedPointAxis2(scale: Int64) -> Int64 {
        fixedPointValue(axis2, scale: scale)
    }

    private func fixedPointValue(_ value: Double, scale: Int64) -> Int64 {
        let scaledValue = value * Double(scale)
        return Int64(max(Double(Int64.min), min(Double(Int64.max), scaledValue)).rounded())
    }

    private func clampedInt32(_ value: Double) -> Int32 {
        let roundedValue = Int64(value.rounded())
        return Int32(max(Int64(Int32.min), min(Int64(Int32.max), roundedValue)))
    }
}
