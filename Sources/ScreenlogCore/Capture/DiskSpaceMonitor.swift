import Foundation
import OSLog

private let log = Logger(subsystem: "dev.screenlog", category: "disk")

/// Monitors free space on the volume holding Screenlogger data.
/// When free space drops below the threshold (default 1 GB), sets a pause flag
/// that `RecordingEngine` checks before each capture cycle.
public final class DiskSpaceMonitor: @unchecked Sendable {
    public static let shared = DiskSpaceMonitor()

    /// Default: 1 GB.
    public var minimumFreeBytes: Int64 = 1_000_000_000
    /// Reuse the last capacity reading so the capture loop does not invoke
    /// CacheDelete on every interval.
    public var cacheTTL: TimeInterval = 45

    private let lock = NSLock()
    private var _isPaused = false
    private var _lastFreeBytes: Int64?
    private var lastRefreshAt: Date?
    private var lastRefreshPath: String?
    var now: () -> Date = Date.init
    var capacityProvider: (URL) -> Int64? = { DiskSpaceMonitor.volumeAvailableBytes(at: $0) }

    public init() {}

    /// True when the last check found free space below `minimumFreeBytes`.
    public var isPausedForDiskSpace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isPaused
    }

    public var lastFreeBytes: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return _lastFreeBytes
    }

    /// Query free space for the volume containing `path` and update the pause flag.
    /// - Returns: `true` when recording may continue (enough free space).
    @discardableResult
    public func refresh(at path: URL, force: Bool = false) -> Bool {
        let currentPath = path.path
        lock.lock()
        if !force,
            let lastRefreshAt,
            let lastRefreshPath,
            lastRefreshPath == currentPath,
            now().timeIntervalSince(lastRefreshAt) < cacheTTL,
            _lastFreeBytes != nil
        {
            let paused = _isPaused
            lock.unlock()
            return !paused
        }
        lock.unlock()

        let free = capacityProvider(path)
        lock.lock()
        _lastFreeBytes = free
        lastRefreshAt = now()
        lastRefreshPath = currentPath
        let wasPaused = _isPaused
        if let free {
            _isPaused = free < minimumFreeBytes
        } else {
            // Fail open if we cannot measure.
            _isPaused = false
        }
        let paused = _isPaused
        lock.unlock()

        if paused && !wasPaused {
            let mb = (free ?? 0) / (1_024 * 1_024)
            log.warning(
                "low disk space (\(mb) MB free < \(self.minimumFreeBytes / (1_024 * 1_024)) MB); pausing capture"
            )
        } else if !paused && wasPaused {
            log.info("disk space recovered; resuming capture eligibility")
        }
        return !paused
    }

    /// Convenience used by `RecordingEngine`: true when capture should pause.
    public func shouldPauseRecording(dataRoot: URL) -> Bool {
        !refresh(at: dataRoot)
    }

    /// Static helper: critically low free space (< 1 GB by default). Also updates shared pause flag.
    public static func isCriticallyLow(
        at path: URL,
        thresholdBytes: Int64 = 1_000_000_000
    ) -> Bool {
        shared.minimumFreeBytes = thresholdBytes
        return shared.shouldPauseRecording(dataRoot: path)
    }

    public func clearPause() {
        lock.lock()
        _isPaused = false
        _lastFreeBytes = nil
        lastRefreshAt = nil
        lastRefreshPath = nil
        lock.unlock()
    }

    public static func freeBytes(at path: URL) -> Int64? {
        volumeAvailableBytes(at: path)
    }

    /// Uses ordinary available capacity. `volumeAvailableCapacityForImportantUsage`
    /// asks CacheDelete to inventory every client and is too expensive for the
    /// capture loop.
    public static func volumeAvailableBytes(at path: URL) -> Int64? {
        let filePath = path.path
        do {
            let values = try URL(fileURLWithPath: filePath).resourceValues(forKeys: [
                .volumeAvailableCapacityKey
            ])
            if let available = values.volumeAvailableCapacity {
                return Int64(available)
            }
        } catch {
            log.debug("volume capacity query failed: \(error.localizedDescription)")
        }

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: filePath),
            let free = attrs[.systemFreeSize] as? NSNumber
        {
            return free.int64Value
        }
        return nil
    }
}
