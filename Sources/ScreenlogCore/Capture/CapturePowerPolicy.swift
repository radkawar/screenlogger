import Foundation

/// Battery-aware capture defaults. Live recording stays on; the expensive
/// parts of each cycle get cheaper while this Mac is unplugged.
public enum CapturePowerPolicy {
    /// Floor applied to the configured interval while on battery.
    public static let batteryMinimumInterval: TimeInterval = 5
    /// Longest stored / recognized edge used on battery, even for Ultra.
    public static let batteryMaxDimension = 1_920
    /// Keep sessions from splitting during a long unchanged screen.
    public static let unchangedHeartbeatSeconds: TimeInterval = 60

    public static func captureInterval(
        configured: TimeInterval,
        powerSource: SystemPowerSourceState
    ) -> TimeInterval {
        let interval = max(0.5, configured)
        guard powerSource == .battery else { return interval }
        return max(interval, batteryMinimumInterval)
    }

    public static func captureMaxDimension(
        configured: Int,
        powerSource: SystemPowerSourceState
    ) -> Int {
        guard powerSource == .battery else { return configured }
        if configured == 0 { return batteryMaxDimension }
        return min(configured, batteryMaxDimension)
    }

    public static func prefersFastRecognition(powerSource: SystemPowerSourceState) -> Bool {
        powerSource == .battery
    }

    public static func skipAccessibilityTree(powerSource: SystemPowerSourceState) -> Bool {
        powerSource == .battery
    }

    /// Skip encode/store/AX when the screen did not change, except for a
    /// periodic heartbeat that keeps usage sessions from splitting.
    public static func shouldSkipUnchangedStore(
        reused: Bool,
        lastStoredAtMs: Int64?,
        nowMs: Int64,
        heartbeatSeconds: TimeInterval
    ) -> Bool {
        guard reused, let lastStoredAtMs else { return false }
        let heartbeatMs = Int64(heartbeatSeconds * 1_000)
        return nowMs - lastStoredAtMs < heartbeatMs
    }

    /// An all-display interval must store every display or none. If any screen
    /// changed or a heartbeat is due, keep the moment complete.
    public static func shouldStoreInterval(
        displays: [(reused: Bool, lastStoredAtMs: Int64?)],
        nowMs: Int64,
        heartbeatSeconds: TimeInterval
    ) -> Bool {
        guard !displays.isEmpty else { return false }
        return displays.contains { display in
            !shouldSkipUnchangedStore(
                reused: display.reused,
                lastStoredAtMs: display.lastStoredAtMs,
                nowMs: nowMs,
                heartbeatSeconds: heartbeatSeconds
            )
        }
    }
}

/// Per-cycle capture knobs derived from user settings and power state.
public struct CaptureEnergyProfile: Sendable, Equatable {
    public var maxDimension: Int
    public var stillQuality: Double
    public var fastRecognition: Bool
    public var collectAccessibilityTree: Bool
    public var unchangedHeartbeatSeconds: TimeInterval

    public init(
        maxDimension: Int,
        stillQuality: Double,
        fastRecognition: Bool,
        collectAccessibilityTree: Bool,
        unchangedHeartbeatSeconds: TimeInterval = CapturePowerPolicy.unchangedHeartbeatSeconds
    ) {
        self.maxDimension = maxDimension
        self.stillQuality = stillQuality
        self.fastRecognition = fastRecognition
        self.collectAccessibilityTree = collectAccessibilityTree
        self.unchangedHeartbeatSeconds = unchangedHeartbeatSeconds
    }

    public static func make(
        configuredMaxDimension: Int,
        stillQuality: Double,
        captureAXTree: Bool,
        powerSource: SystemPowerSourceState
    ) -> CaptureEnergyProfile {
        CaptureEnergyProfile(
            maxDimension: CapturePowerPolicy.captureMaxDimension(
                configured: configuredMaxDimension,
                powerSource: powerSource
            ),
            stillQuality: stillQuality,
            fastRecognition: CapturePowerPolicy.prefersFastRecognition(powerSource: powerSource),
            collectAccessibilityTree: captureAXTree
                && !CapturePowerPolicy.skipAccessibilityTree(powerSource: powerSource)
        )
    }
}
