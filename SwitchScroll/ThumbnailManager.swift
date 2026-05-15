import AppKit
import CoreVideo
import Darwin
import ScreenCaptureKit

final class ThumbnailManager: @unchecked Sendable {
    static let shared = ThumbnailManager()

    private struct CacheKey: Hashable {
        let bundleIdentifier: String
        let processID: Int
        let title: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        func matchesIdentity(_ other: CacheKey) -> Bool {
            bundleIdentifier == other.bundleIdentifier &&
                processID == other.processID &&
                title == other.title
        }
    }

    private struct ThumbnailEntry {
        var key: CacheKey
        var image: NSImage
        var lastSuccessAt: Date
        var lastRefreshAttemptAt: Date
        var lastSeenAt: Date
        var failureCount: Int
    }

    private struct CacheLookup {
        let image: NSImage
        let isFresh: Bool
    }

    private let permissionManager: PermissionManager
    private let freshCacheLifetime: TimeInterval = 30
    private let unseenEntryLifetime: TimeInterval = 30 * 60
    private let refreshRetryInterval: TimeInterval = 3
    private let maxCacheEntries = 80
    private let frameBucketSize: CGFloat = 10
    private let maxThumbnailDimension: CGFloat = 420
    private let captureTimeout: TimeInterval = 1.2
    private let lock = NSLock()

    private var cache: [CacheKey: ThumbnailEntry] = [:]
    private var refreshesInFlight: Set<CacheKey> = []

    init(permissionManager: PermissionManager = .shared) {
        self.permissionManager = permissionManager
    }

    func getThumbnail(for window: SwitchableWindow, refreshStale: Bool = false) async -> NSImage? {
        DebugLog.write("Thumbnail requested: app=\(window.appName), title=\(window.windowTitle)")

        let key = cacheKey(for: window)
        let cached = cachedLookup(for: window)
        if let cached, cached.isFresh || !refreshStale {
            DebugLog.write("Thumbnail cache hit: app=\(window.appName), title=\(window.windowTitle)")
            return cached.image
        }

        guard beginRefresh(for: key) else {
            DebugLog.write("Thumbnail refresh skipped: already in flight app=\(window.appName), title=\(window.windowTitle)")
            return cached?.image
        }
        defer {
            finishRefresh(for: key)
        }

        let fallbackImage = cachedLookup(for: window)?.image
        if let fresh = cachedLookup(for: window), fresh.isFresh {
            DebugLog.write("Thumbnail cache became fresh while waiting: app=\(window.appName), title=\(window.windowTitle)")
            return fresh.image
        }

        guard permissionManager.hasScreenRecordingPermission() else {
            DebugLog.write("Thumbnail skipped: missing Screen Recording permission")
            return fallbackImage
        }

        guard let shareableWindows = await currentShareableWindows() else {
            recordRefreshFailure(for: key)
            return fallbackImage
        }

        guard let scWindow = bestMatchingWindow(for: window, in: shareableWindows) else {
            DebugLog.write("Thumbnail match failed: app=\(window.appName), title=\(window.windowTitle)")
            recordRefreshFailure(for: key)
            return fallbackImage
        }

        guard let image = await captureThumbnail(for: scWindow) else {
            DebugLog.write("Thumbnail capture returned nil: app=\(window.appName), title=\(window.windowTitle)")
            recordRefreshFailure(for: key)
            return fallbackImage
        }

        store(image, for: window)
        DebugLog.write("Thumbnail captured: app=\(window.appName), title=\(window.windowTitle)")
        return image
    }

    func preloadThumbnails(for windows: [SwitchableWindow]) async {
        guard permissionManager.hasScreenRecordingPermission() else {
            DebugLog.write("Thumbnail preload skipped: missing Screen Recording permission")
            return
        }

        let staleOrMissingWindows = windows.filter { !hasFreshThumbnail(for: $0) }
        guard !staleOrMissingWindows.isEmpty,
              let shareableWindows = await currentShareableWindows() else {
            return
        }

        for window in staleOrMissingWindows {
            let key = cacheKey(for: window)
            guard beginRefresh(for: key) else {
                continue
            }

            guard let scWindow = bestMatchingWindow(for: window, in: shareableWindows),
                  let image = await captureThumbnail(for: scWindow) else {
                recordRefreshFailure(for: key)
                finishRefresh(for: key)
                continue
            }

            store(image, for: window)
            finishRefresh(for: key)
        }
    }

    func cachedThumbnail(for window: SwitchableWindow) -> NSImage? {
        cachedLookup(for: window)?.image
    }

    func hasFreshThumbnail(for window: SwitchableWindow) -> Bool {
        cachedLookup(for: window)?.isFresh == true
    }

    func markSeen(windows: [SwitchableWindow]) {
        let keys = windows.map(cacheKey(for:))
        let now = Date()

        lock.lock()
        for key in keys {
            markSeenLocked(for: key, now: now)
        }
        cleanupEntries(now: now)
        lock.unlock()
    }

    private func cachedLookup(for window: SwitchableWindow) -> CacheLookup? {
        let key = cacheKey(for: window)
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        cleanupEntries(now: now)
        return cachedLookupLocked(for: key, now: now)
    }

    private func currentShareableWindows() async -> [SCWindow]? {
        DebugLog.write("Thumbnail shareable content requested")

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            DebugLog.write("Thumbnail shareable content loaded: windows=\(content.windows.count)")
            return content.windows
        } catch {
            DebugLog.write("Thumbnail shareable content failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func bestMatchingWindow(for window: SwitchableWindow, in scWindows: [SCWindow]) -> SCWindow? {
        let candidates = scWindows.filter { scWindow in
            scWindow.owningApplication?.processID == window.processID
        }

        guard !candidates.isEmpty else {
            DebugLog.write("Thumbnail match candidates empty: app=\(window.appName), title=\(window.windowTitle)")
            return nil
        }

        let scoredCandidates = candidates.map { scWindow in
            (window: scWindow, score: matchScore(for: window, scWindow: scWindow))
        }

        guard let best = scoredCandidates.max(by: { $0.score < $1.score }) else {
            return nil
        }

        if best.score >= 110 || candidates.count == 1 {
            return best.window
        }

        DebugLog.write(
            "Thumbnail weak match accepted: app=\(window.appName), title=\(window.windowTitle), " +
                "bestScore=\(best.score), candidates=\(candidates.count)"
        )
        return best.window
    }

    private func matchScore(for window: SwitchableWindow, scWindow: SCWindow) -> Double {
        var score = 100.0

        score += titleScore(
            targetTitle: window.windowTitle,
            candidateTitle: scWindow.title ?? ""
        )
        score += frameScore(
            targetFrame: window.windowFrame,
            candidateFrame: scWindow.frame
        )

        if scWindow.windowLayer == 0 {
            score += 10
        }

        return score
    }

    private func titleScore(targetTitle: String, candidateTitle: String) -> Double {
        let target = normalizedTitle(targetTitle)
        let candidate = normalizedTitle(candidateTitle)

        guard !target.isEmpty, !candidate.isEmpty else {
            return 0
        }

        if target == candidate {
            return 100
        }

        if target.contains(candidate) || candidate.contains(target) {
            return 70
        }

        let similarity = stringSimilarity(target, candidate)
        if similarity >= 0.72 {
            return similarity * 60
        }

        return similarity * 25
    }

    private func frameScore(targetFrame: CGRect, candidateFrame: CGRect) -> Double {
        let originDelta = hypot(
            targetFrame.midX - candidateFrame.midX,
            targetFrame.midY - candidateFrame.midY
        )
        let sizeDelta = abs(targetFrame.width - candidateFrame.width) +
            abs(targetFrame.height - candidateFrame.height)
        let totalDelta = originDelta + sizeDelta

        switch totalDelta {
        case 0...20:
            return 50
        case 20...80:
            return 35
        case 80...180:
            return 20
        case 180...320:
            return 8
        default:
            return 0
        }
    }

    private func captureThumbnail(for scWindow: SCWindow) async -> NSImage? {
        DebugLog.write("Thumbnail capture started: title=\(scWindow.title ?? ""), pid=\(scWindow.owningApplication?.processID ?? -1)")

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        let outputSize = thumbnailSize(for: scWindow.frame)

        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.queueDepth = 1

        if let cgImage = await captureImageWithFilter(
            filter,
            configuration: configuration,
            timeout: captureTimeout
        ) {
            return image(from: cgImage)
        }

        DebugLog.write("Thumbnail window capture unavailable; trying rect fallback")

        if #available(macOS 15.2, *),
           let cgImage = await captureImage(
            in: scWindow.frame,
            timeout: captureTimeout
        ) {
            DebugLog.write("Thumbnail rect fallback captured")
            return image(from: cgImage)
        }

        return nil
    }

    private func captureImageWithFilter(
        _ filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        timeout: TimeInterval
    ) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let resumeBox = CaptureResumeBox(continuation)
            let timeoutItem = DispatchWorkItem {
                if resumeBox.resume(with: nil) {
                    DebugLog.write("Thumbnail window capture timed out")
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )

            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { cgImage, error in
                if let error {
                    DebugLog.write("Thumbnail window capture failed: \(error.localizedDescription)")
                }

                _ = resumeBox.resume(with: cgImage)
            }
        }
    }

    @available(macOS 15.2, *)
    private func captureImage(in rect: CGRect, timeout: TimeInterval) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let resumeBox = CaptureResumeBox(continuation)
            let timeoutItem = DispatchWorkItem {
                if resumeBox.resume(with: nil) {
                    DebugLog.write("Thumbnail rect fallback timed out")
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )

            SCScreenshotManager.captureImage(in: rect) { cgImage, error in
                if let error {
                    DebugLog.write("Thumbnail rect fallback failed: \(error.localizedDescription)")
                }

                _ = resumeBox.resume(with: cgImage)
            }
        }
    }

    private func image(from cgImage: CGImage) -> NSImage {
        NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private func thumbnailSize(for frame: CGRect) -> (width: Int, height: Int) {
        let sourceWidth = max(frame.width, 1)
        let sourceHeight = max(frame.height, 1)
        let scale = min(maxThumbnailDimension / max(sourceWidth, sourceHeight), 1)
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2

        let width = Int((sourceWidth * scale * backingScale).rounded())
        let height = Int((sourceHeight * scale * backingScale).rounded())

        return (max(width, 1), max(height, 1))
    }

    private func store(_ image: NSImage, for window: SwitchableWindow) {
        let key = cacheKey(for: window)
        let now = Date()
        let entry = ThumbnailEntry(
            key: key,
            image: image,
            lastSuccessAt: now,
            lastRefreshAttemptAt: now,
            lastSeenAt: now,
            failureCount: 0
        )

        lock.lock()
        cache[key] = entry
        cleanupEntries(now: now)
        lock.unlock()
    }

    private func cachedLookupLocked(for key: CacheKey, now: Date) -> CacheLookup? {
        if var entry = cache[key] {
            entry.lastSeenAt = now
            cache[key] = entry
            return CacheLookup(image: entry.image, isFresh: isFresh(entry, now: now))
        }

        guard let fallback = nearestFallbackEntryLocked(for: key, now: now) else {
            return nil
        }

        var aliasedEntry = fallback.entry
        aliasedEntry.key = key
        aliasedEntry.lastSeenAt = now
        cache[fallback.key]?.lastSeenAt = now
        cache[key] = aliasedEntry
        DebugLog.write("Thumbnail cache fallback alias created: processID=\(key.processID), title=\(key.title)")
        return CacheLookup(image: aliasedEntry.image, isFresh: isFresh(aliasedEntry, now: now))
    }

    private func nearestFallbackEntryLocked(
        for key: CacheKey,
        now: Date
    ) -> (key: CacheKey, entry: ThumbnailEntry, distance: CGFloat)? {
        cache
            .filter { cachedKey, entry in
                cachedKey.matchesIdentity(key) && processExists(entry.key.processID)
            }
            .map { cachedKey, entry in
                (key: cachedKey, entry: entry, distance: frameDistance(from: cachedKey, to: key))
            }
            .min { $0.distance < $1.distance }
    }

    private func frameDistance(from lhs: CacheKey, to rhs: CacheKey) -> CGFloat {
        CGFloat(abs(lhs.x - rhs.x) + abs(lhs.y - rhs.y) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height))
    }

    private func beginRefresh(for key: CacheKey) -> Bool {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        guard !refreshesInFlight.contains(key) else {
            return false
        }

        if let matchingKey = matchingEntryKeyLocked(for: key, now: now),
           var entry = cache[matchingKey] {
            guard isFresh(entry, now: now) == false else {
                return false
            }

            guard now.timeIntervalSince(entry.lastRefreshAttemptAt) >= refreshRetryInterval else {
                return false
            }

            entry.lastRefreshAttemptAt = now
            entry.lastSeenAt = now
            cache[matchingKey] = entry
        }

        refreshesInFlight.insert(key)
        return true
    }

    private func finishRefresh(for key: CacheKey) {
        lock.lock()
        refreshesInFlight.remove(key)
        lock.unlock()
    }

    private func recordRefreshFailure(for key: CacheKey) {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        guard let matchingKey = matchingEntryKeyLocked(for: key, now: now),
              var entry = cache[matchingKey] else {
            return
        }

        entry.lastRefreshAttemptAt = now
        entry.lastSeenAt = now
        entry.failureCount += 1
        cache[matchingKey] = entry
    }

    private func markSeenLocked(for key: CacheKey, now: Date) {
        let matchingKeys = cache.keys.filter { $0.matchesIdentity(key) }
        for matchingKey in matchingKeys {
            cache[matchingKey]?.lastSeenAt = now
        }

        guard cache[key] == nil,
              let fallback = nearestFallbackEntryLocked(for: key, now: now) else {
            return
        }

        var aliasedEntry = fallback.entry
        aliasedEntry.key = key
        aliasedEntry.lastSeenAt = now
        cache[key] = aliasedEntry
    }

    private func matchingEntryKeyLocked(for key: CacheKey, now: Date) -> CacheKey? {
        if cache[key] != nil {
            return key
        }

        return nearestFallbackEntryLocked(for: key, now: now)?.key
    }

    private func isFresh(_ entry: ThumbnailEntry, now: Date) -> Bool {
        now.timeIntervalSince(entry.lastSuccessAt) <= freshCacheLifetime
    }

    private func cleanupEntries(now: Date) {
        cache = cache.filter { key, entry in
            now.timeIntervalSince(entry.lastSeenAt) <= unseenEntryLifetime &&
                processExists(key.processID)
        }

        guard cache.count > maxCacheEntries else {
            return
        }

        let removalCount = cache.count - maxCacheEntries
        let keysToRemove = cache
            .sorted { $0.value.lastSeenAt < $1.value.lastSeenAt }
            .prefix(removalCount)
            .map(\.key)

        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
    }

    private func processExists(_ processID: Int) -> Bool {
        errno = 0
        return kill(pid_t(processID), 0) == 0 || errno == EPERM
    }

    private func cacheKey(for window: SwitchableWindow) -> CacheKey {
        CacheKey(
            bundleIdentifier: window.bundleIdentifier,
            processID: Int(window.processID),
            title: normalizedTitle(window.windowTitle),
            x: frameBucket(window.windowFrame.origin.x),
            y: frameBucket(window.windowFrame.origin.y),
            width: frameBucket(window.windowFrame.width),
            height: frameBucket(window.windowFrame.height)
        )
    }

    private func frameBucket(_ value: CGFloat) -> Int {
        Int((value / frameBucketSize).rounded())
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func stringSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else {
            return 1
        }

        let distance = levenshteinDistance(Array(lhs), Array(rhs))
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else {
            return 1
        }

        return 1 - (Double(distance) / Double(maxLength))
    }

    private func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else {
            return rhs.count
        }

        guard !rhs.isEmpty else {
            return lhs.count
        }

        var previousRow = Array(0...rhs.count)
        var currentRow = Array(repeating: 0, count: rhs.count + 1)

        for lhsIndex in 1...lhs.count {
            currentRow[0] = lhsIndex

            for rhsIndex in 1...rhs.count {
                let substitutionCost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                currentRow[rhsIndex] = min(
                    previousRow[rhsIndex] + 1,
                    currentRow[rhsIndex - 1] + 1,
                    previousRow[rhsIndex - 1] + substitutionCost
                )
            }

            swap(&previousRow, &currentRow)
        }

        return previousRow[rhs.count]
    }
}

private final class CaptureResumeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with value: Value) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }

        self.continuation = nil
        lock.unlock()

        continuation.resume(returning: value)
        return true
    }
}
