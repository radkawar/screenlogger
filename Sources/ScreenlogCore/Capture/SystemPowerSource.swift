import Foundation
import IOKit.ps

public enum SystemPowerSourceState: Sendable, Equatable {
    case externalPower
    case battery
    case unknown
}

/// Small, synchronous IOKit probe used only by the low-frequency maintenance
/// scheduler. Capture and live transcription never depend on this value.
public enum SystemPowerSource {
    public static func current() -> SystemPowerSourceState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sourceList = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unknown }

        var foundBattery = false
        for source in sourceList {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
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
    public static func shouldDeferAutomaticWork(
        powerSource: SystemPowerSourceState,
        deferOnBattery: Bool
    ) -> Bool {
        deferOnBattery && powerSource == .battery
    }
}
