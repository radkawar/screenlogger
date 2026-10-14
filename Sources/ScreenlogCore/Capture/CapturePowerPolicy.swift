import Foundation

/// Everything the capture loop knows about this Mac's current energy budget.
/// Kept as plain data so every policy decision below stays pure and testable.
public struct CapturePowerConditions: Sendable, Equatable {
    public var powerSource: SystemPowerSourceState
    /// `ProcessInfo.thermalState`. macOS already throttles the machine at
    /// `.serious`; continuing to screenshot and OCR at full rate makes it worse.
    public var thermalState: ProcessInfo.ThermalState
    /// `ProcessInfo.isLowPowerModeEnabled`. An explicit request from the user
    /// to spend less energy, on battery or not.
    public var lowPowerModeEnabled: Bool

    public init(
        powerSource: SystemPowerSourceState,
        thermalState: ProcessInfo.ThermalState = .nominal,
        lowPowerModeEnabled: Bool = false
    ) {
        self.powerSource = powerSource
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }

    /// Live snapshot. Both process values are cached by Foundation and are
    /// cheap enough to read once per capture cycle; the power source is not,
    /// so callers pass their own throttled reading.
    public static func current(
        powerSource: SystemPowerSourceState,
        processInfo: ProcessInfo = .processInfo
    ) -> CapturePowerConditions {
        CapturePowerConditions(
            powerSource: powerSource,
            thermalState: processInfo.thermalState,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
    }

    /// True once macOS reports that this Mac is hot enough to be throttled.
    /// `.fair` is normal under sustained work and is deliberately not included.
    public var isThermallyPressured: Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// True when any signal asks capture to spend less energy per cycle.
    public var isConstrained: Bool {
        powerSource == .battery || lowPowerModeEnabled || isThermallyPressured
    }
}

/// Why capture is deliberately running cheaper than the user configured.
/// Capture never stops for an energy reason: it slows down and keeps going.
public enum CaptureEnergySaverReason: String, CaseIterable, Codable, Sendable, Equatable {
    case battery
    case lowPowerMode
    case thermalPressure

    /// Most severe active reason, or nil when nothing is being degraded.
    public static func reason(for conditions: CapturePowerConditions) -> CaptureEnergySaverReason? {
        if conditions.isThermallyPressured { return .thermalPressure }
        if conditions.lowPowerModeEnabled { return .lowPowerMode }
        if conditions.powerSource == .battery { return .battery }
        return nil
    }

    /// Compact copy for status badges and menu-bar tooltips.
    public var statusTitle: String {
        switch self {
        case .battery:
            return "Capture - Battery Saver"
        case .lowPowerMode:
            return "Capture - Low Power Mode"
        case .thermalPressure:
            return "Capture - Cooling Down"
        }
    }

    /// Plain-language explanation suitable for a settings row or help popover.
    public var userDescription: String {
        switch self {
        case .battery:
            return "Screenlogger captures less often and at a smaller size while this Mac runs on battery."
        case .lowPowerMode:
            return "Low Power Mode is on. Screenlogger captures less often and delays background compression."
        case .thermalPressure:
            return "This Mac is hot. Screenlogger captures less often until its temperature decreases."
        }
    }

    /// SF Symbol shared by AppKit and SwiftUI status surfaces.
    public var systemImageName: String {
        switch self {
        case .battery:
            return "battery.50percent"
        case .lowPowerMode:
            return "leaf"
        case .thermalPressure:
            return "thermometer.high"
        }
    }
}

/// Energy-aware capture defaults. Live recording stays on; the expensive parts
/// of each cycle get cheaper while this Mac is unplugged, hot, or in Low Power
/// Mode.
public enum CapturePowerPolicy {
    /// Floor applied to the configured interval while on battery.
    public static let batteryMinimumInterval: TimeInterval = 5
    /// Floor applied while Low Power Mode is on, plugged in or not.
    public static let lowPowerMinimumInterval: TimeInterval = 10
    /// Floor applied once macOS reports serious thermal pressure.
    public static let seriousThermalMinimumInterval: TimeInterval = 15
    /// Floor applied at critical thermal pressure. Deliberately still a
    /// recording interval: capture degrades, it never silently stops.
    public static let criticalThermalMinimumInterval: TimeInterval = 30
    /// Longest stored / recognized edge used on battery, even for Ultra.
    public static let batteryMaxDimension = 1_920
    /// Longest stored / recognized edge while this Mac is throttling itself.
    public static let criticalThermalMaxDimension = 1_280
    /// Keep sessions from splitting during a long unchanged screen.
    public static let unchangedHeartbeatSeconds: TimeInterval = 60

    public static func captureInterval(
        configured: TimeInterval,
        conditions: CapturePowerConditions
    ) -> TimeInterval {
        var interval = max(0.5, configured)
        if conditions.powerSource == .battery {
            interval = max(interval, batteryMinimumInterval)
        }
        if conditions.lowPowerModeEnabled {
            interval = max(interval, lowPowerMinimumInterval)
        }
        switch conditions.thermalState {
        case .serious:
            interval = max(interval, seriousThermalMinimumInterval)
        case .critical:
            interval = max(interval, criticalThermalMinimumInterval)
        default:
            break
        }
        return interval
    }

    public static func captureInterval(
        configured: TimeInterval,
        powerSource: SystemPowerSourceState
    ) -> TimeInterval {
        captureInterval(
            configured: configured,
            conditions: CapturePowerConditions(powerSource: powerSource)
        )
    }

    public static func captureMaxDimension(
        configured: Int,
        conditions: CapturePowerConditions
    ) -> Int {
        let cap: Int
        if conditions.thermalState == .critical {
            cap = criticalThermalMaxDimension
        } else if conditions.isConstrained {
            cap = batteryMaxDimension
        } else {
            return configured
        }
        if configured == 0 { return cap }
        return min(configured, cap)
    }

    public static func captureMaxDimension(
        configured: Int,
        powerSource: SystemPowerSourceState
    ) -> Int {
        captureMaxDimension(
            configured: configured,
            conditions: CapturePowerConditions(powerSource: powerSource)
        )
    }

    public static func prefersFastRecognition(conditions: CapturePowerConditions) -> Bool {
        conditions.isConstrained
    }

    public static func prefersFastRecognition(powerSource: SystemPowerSourceState) -> Bool {
        prefersFastRecognition(conditions: CapturePowerConditions(powerSource: powerSource))
    }

    /// The accessibility tree is the most expensive optional part of a cycle:
    /// it walks another process's UI hierarchy over IPC.
    public static func skipAccessibilityTree(conditions: CapturePowerConditions) -> Bool {
        conditions.isConstrained
    }

    public static func skipAccessibilityTree(powerSource: SystemPowerSourceState) -> Bool {
        skipAccessibilityTree(conditions: CapturePowerConditions(powerSource: powerSource))
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
        conditions: CapturePowerConditions
    ) -> CaptureEnergyProfile {
        CaptureEnergyProfile(
            maxDimension: CapturePowerPolicy.captureMaxDimension(
                configured: configuredMaxDimension,
                conditions: conditions
            ),
            stillQuality: stillQuality,
            fastRecognition: CapturePowerPolicy.prefersFastRecognition(conditions: conditions),
            collectAccessibilityTree: captureAXTree
                && !CapturePowerPolicy.skipAccessibilityTree(conditions: conditions)
        )
    }

    public static func make(
        configuredMaxDimension: Int,
        stillQuality: Double,
        captureAXTree: Bool,
        powerSource: SystemPowerSourceState
    ) -> CaptureEnergyProfile {
        make(
            configuredMaxDimension: configuredMaxDimension,
            stillQuality: stillQuality,
            captureAXTree: captureAXTree,
            conditions: CapturePowerConditions(powerSource: powerSource)
        )
    }
}
