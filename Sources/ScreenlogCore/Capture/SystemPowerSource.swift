import Foundation
import IOKit.ps

public enum SystemPowerSourceState: Sendable, Equatable {
    case externalPower
    case battery
    case unknown
}

/// Small, synchronous IOKit probe used by the maintenance scheduler and the
/// capture-loop battery policy. Live transcription does not depend on this value.
public enum SystemPowerSource {
    public static func current() -> SystemPowerSourceState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sourceList = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unknown }

        var foundBattery = false
        for source in sourceList {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any]
            else { continue }
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            if state == (kIOPSBatteryPowerValue as String) { return .battery }
            if state == (kIOPSACPowerValue as String) { foundBattery = true }
        }
        // Macs without an internal battery commonly return no power-source
        // rows. Treat a recognized AC row as external and stay conservative
        // only when IOKit returned data we could not understand.
        return foundBattery || sourceList.isEmpty ? .externalPower : .unknown
    }
}

public enum MaintenancePowerPolicy {
    /// Automatic compression and retention are the heaviest recurring work in
    /// the app. Thermal pressure and Low Power Mode defer them regardless of
    /// the battery preference: both mean the system has already asked every
    /// process to do less, and neither pass is time critical. User-initiated
    /// maintenance is unaffected and always runs immediately.
    public static func shouldDeferAutomaticWork(
        conditions: CapturePowerConditions,
        deferOnBattery: Bool
    ) -> Bool {
        if conditions.isThermallyPressured { return true }
        if conditions.lowPowerModeEnabled { return true }
        return deferOnBattery && conditions.powerSource == .battery
    }

    public static func shouldDeferAutomaticWork(
        powerSource: SystemPowerSourceState,
        deferOnBattery: Bool
    ) -> Bool {
        shouldDeferAutomaticWork(
            conditions: CapturePowerConditions(powerSource: powerSource),
            deferOnBattery: deferOnBattery
        )
    }
}
