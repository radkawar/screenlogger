import Foundation

/// Predefined privacy exclusion categories.
public enum ExclusionCategory: String, CaseIterable, Identifiable, Sendable {
    case passwordManagers
    case banks

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .passwordManagers: return "Password Managers"
        case .banks: return "Banks"
        }
    }

    public var detail: String {
        switch self {
        case .passwordManagers: return "Password manager apps"
        case .banks: return "UK and US banks and financial services"
        }
    }

    public var systemImage: String {
        switch self {
        case .passwordManagers: return "key.fill"
        case .banks: return "building.columns.fill"
        }
    }

    public var defaultsKey: String {
        switch self {
        case .passwordManagers: return ProductPreferenceKey.excludePasswordManagers
        case .banks: return ProductPreferenceKey.excludeBanksCategory
        }
    }

    /// Known bundle IDs for the category (full catalog; UI filters to installed/running).
    public var bundleIDs: [String] {
        switch self {
        case .passwordManagers:
            return ExclusionCatalog.passwordManagerBundleIDs
        case .banks:
            // Banks are domain-pack driven (websites tab); no Mac banking apps required.
            return []
        }
    }

    public var domains: [String] {
        switch self {
        case .passwordManagers:
            return []
        case .banks:
            return ExclusionCatalog.bankDomains
        }
    }
}

/// System UI apps that rarely provide useful searchable history.
public enum SystemExclusionApp: String, CaseIterable, Identifiable, Sendable {
    case notifications = "com.apple.notificationcenterui"
    case controlCenter = "com.apple.controlcenter"
    case spotlight = "com.apple.Spotlight"
    case siri = "com.apple.Siri"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .notifications: return "Notifications"
        case .controlCenter: return "Control Center"
        case .spotlight: return "Spotlight"
        case .siri: return "Siri"
        }
    }

    public var systemImage: String {
        switch self {
        case .notifications: return "bell.fill"
        case .controlCenter: return "switch.2"
        case .spotlight: return "magnifyingglass"
        case .siri: return "waveform"
        }
    }
}
