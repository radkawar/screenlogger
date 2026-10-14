import AppKit
import Foundation
import UniformTypeIdentifiers

public enum ScreenlogPermission: String, CaseIterable, Sendable, Equatable {
    case screenRecording
    case accessibility

    public var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    public var settingsPaneName: String {
        "Privacy & Security > \(title)"
    }
}

/// A truthful permission state for UI and automation.
///
/// macOS does not expose a reliable public distinction between an initial
/// denial and a later denial for these permissions. `needsRequest` therefore
/// means that the app may make one supported request after an explicit click;
/// it never implies that a prompt can be shown programmatically.
public enum PermissionJourneyState: String, Sendable, Equatable {
    case needsRequest
    case requesting
    case awaitingSystemSettings
    case restartRequired
    case ready
    case verificationFailed
}

public enum PermissionJourneyAction: Sendable, Equatable {
    case request
    case openSettings
    case none
}

public struct PermissionJourney: Sendable, Equatable {
    public private(set) var screenRecording: PermissionJourneyState
    public private(set) var accessibility: PermissionJourneyState

    public init(snapshot: PermissionsSnapshot) {
        screenRecording = snapshot.screenRecording ? .ready : .needsRequest
        accessibility = snapshot.accessibility ? .ready : .needsRequest
    }

    public var isCaptureReady: Bool {
        screenRecording == .ready && accessibility == .ready
    }

    public func state(for permission: ScreenlogPermission) -> PermissionJourneyState {
        switch permission {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        }
    }

    /// The next safe user-initiated action. A permission request is made at
    /// most once per journey; later clicks only revisit System Settings.
    public func action(for permission: ScreenlogPermission) -> PermissionJourneyAction {
        switch state(for: permission) {
        case .needsRequest:
            .request
        case .requesting, .awaitingSystemSettings, .restartRequired, .verificationFailed:
            .openSettings
        case .ready:
            .none
        }
    }

    public mutating func beginRequest(for permission: ScreenlogPermission) {
        set(.requesting, for: permission)
    }

    public mutating func completeRequest(
        for permission: ScreenlogPermission,
        requestAccepted: Bool,
        verified: Bool,
        settingsOpened: Bool
    ) {
        if verified {
            set(.ready, for: permission)
        } else if requestAccepted, permission == .screenRecording {
            // Some macOS releases require the requesting process to restart
            // before Core Graphics preflight reflects a new screen-capture grant.
            set(.restartRequired, for: permission)
        } else if settingsOpened {
            set(.awaitingSystemSettings, for: permission)
        } else {
            set(.verificationFailed, for: permission)
        }
    }

    public mutating func markSettingsOpened(for permission: ScreenlogPermission, opened: Bool) {
        set(opened ? .awaitingSystemSettings : .verificationFailed, for: permission)
    }

    public mutating func refresh(with snapshot: PermissionsSnapshot) {
        refresh(.screenRecording, granted: snapshot.screenRecording)
        refresh(.accessibility, granted: snapshot.accessibility)
    }

    private mutating func refresh(_ permission: ScreenlogPermission, granted: Bool) {
        if granted {
            set(.ready, for: permission)
            return
        }
        switch state(for: permission) {
        case .requesting, .awaitingSystemSettings, .restartRequired, .verificationFailed:
            break
        case .needsRequest, .ready:
            set(.needsRequest, for: permission)
        }
    }

    private mutating func set(
        _ state: PermissionJourneyState,
        for permission: ScreenlogPermission
    ) {
        switch permission {
        case .screenRecording: screenRecording = state
        case .accessibility: accessibility = state
        }
    }
}

/// Injectable wrapper around the only supported permission request APIs.
/// Calling `status` never prompts; calling `request` is reserved for an
/// explicit user action.
public struct PermissionRequestClient {
    private let statusHandler: (ScreenlogPermission) -> Bool
    private let requestHandler: (ScreenlogPermission) -> Bool

    public init(
        status: @escaping (ScreenlogPermission) -> Bool,
        request: @escaping (ScreenlogPermission) -> Bool
    ) {
        statusHandler = status
        requestHandler = request
    }

    public func isGranted(_ permission: ScreenlogPermission) -> Bool {
        statusHandler(permission)
    }

    @discardableResult
    public func request(_ permission: ScreenlogPermission) -> Bool {
        requestHandler(permission)
    }

    public static let live = PermissionRequestClient(
        status: { permission in
            switch permission {
            case .screenRecording:
                ScreenRecordingPermission.preflightGranted()
            case .accessibility:
                AccessibilityPermission.isTrusted(prompt: false)
            }
        },
        request: { permission in
            switch permission {
            case .screenRecording:
                ScreenRecordingPermission.requestAccess()
            case .accessibility:
                AccessibilityPermission.requestAccess()
            }
        }
    )
}

public enum PermissionSettingsRoute: String, Sendable, Equatable {
    case privacyDeepLink
    case legacyDeepLink
    case systemSettingsApplication
    case unavailable
}

public struct PermissionSettingsOpenResult: Sendable, Equatable {
    public let permission: ScreenlogPermission
    public let route: PermissionSettingsRoute

    public init(permission: ScreenlogPermission, route: PermissionSettingsRoute) {
        self.permission = permission
        self.route = route
    }

    public var opened: Bool { route != .unavailable }

    public var instructions: String {
        let destination = permission.settingsPaneName
        switch route {
        case .privacyDeepLink, .legacyDeepLink:
            return "In System Settings, find Screenlogger in \(destination). Turn on Screenlogger."
        case .systemSettingsApplication:
            return "Open \(destination). Find Screenlogger. Turn on Screenlogger."
        case .unavailable:
            return "Open System Settings. Choose \(destination). Find Screenlogger. Turn on Screenlogger."
        }
    }
}

/// One routing authority for macOS privacy panes. Deep links vary between OS
/// releases, so both known forms are tried before opening System Settings as a
/// visible, instruction-backed fallback.
public struct PermissionSystemSettingsOpener {
    public typealias OpenURL = (URL) -> Bool

    private let openURL: OpenURL
    private let systemSettingsURL: URL

    public init(
        systemSettingsURL: URL = URL(fileURLWithPath: "/System/Applications/System Settings.app"),
        openURL: @escaping OpenURL
    ) {
        self.systemSettingsURL = systemSettingsURL
        self.openURL = openURL
    }

    public static let live = PermissionSystemSettingsOpener { url in
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    public func open(_ permission: ScreenlogPermission) -> PermissionSettingsOpenResult {
        for (index, url) in Self.deepLinks(for: permission).enumerated() {
            if openURL(url) {
                return PermissionSettingsOpenResult(
                    permission: permission,
                    route: index == 0 ? .privacyDeepLink : .legacyDeepLink
                )
            }
        }
        if openURL(systemSettingsURL) {
            return PermissionSettingsOpenResult(
                permission: permission,
                route: .systemSettingsApplication
            )
        }
        return PermissionSettingsOpenResult(permission: permission, route: .unavailable)
    }

    public static func deepLinks(for permission: ScreenlogPermission) -> [URL] {
        let pane =
            switch permission {
            case .screenRecording: "Privacy_ScreenCapture"
            case .accessibility: "Privacy_Accessibility"
            }
        return [
            URL(
                string:
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
            )!,
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            )!,
        ]
    }
}

public struct PermissionRequestOutcome: Equatable {
    public let permission: ScreenlogPermission
    public let requestAccepted: Bool
    public let verified: Bool
    public let settingsResult: PermissionSettingsOpenResult?

    public init(
        permission: ScreenlogPermission,
        requestAccepted: Bool,
        verified: Bool,
        settingsResult: PermissionSettingsOpenResult?
    ) {
        self.permission = permission
        self.requestAccepted = requestAccepted
        self.verified = verified
        self.settingsResult = settingsResult
    }
}

/// Orchestrates one explicit permission action without doing any work at
/// initialization time. That makes view appearance side-effect free and gives
/// tests a deterministic seam for prompt and routing behavior.
public final class PermissionFlowCoordinator {
    public private(set) var journey: PermissionJourney
    public private(set) var lastSettingsResult: PermissionSettingsOpenResult?

    private let requestClient: PermissionRequestClient
    private let settingsOpener: PermissionSystemSettingsOpener

    public init(
        snapshot: PermissionsSnapshot,
        requestClient: PermissionRequestClient = .live,
        settingsOpener: PermissionSystemSettingsOpener = .live
    ) {
        journey = PermissionJourney(snapshot: snapshot)
        self.requestClient = requestClient
        self.settingsOpener = settingsOpener
    }

    @discardableResult
    public func request(_ permission: ScreenlogPermission) -> PermissionRequestOutcome {
        guard journey.action(for: permission) == .request else {
            let verified = requestClient.isGranted(permission)
            if verified {
                let snapshot = PermissionsSnapshot(
                    screenRecording: permission == .screenRecording
                        ? true : journey.screenRecording == .ready,
                    accessibility: permission == .accessibility
                        ? true : journey.accessibility == .ready
                )
                journey.refresh(with: snapshot)
                if journey.isCaptureReady {
                    lastSettingsResult = nil
                }
                return PermissionRequestOutcome(
                    permission: permission,
                    requestAccepted: false,
                    verified: true,
                    settingsResult: nil
                )
            }

            let previousState = journey.state(for: permission)
            let settingsResult = settingsOpener.open(permission)
            lastSettingsResult = settingsResult
            if previousState != .restartRequired {
                journey.markSettingsOpened(for: permission, opened: settingsResult.opened)
            }
            return PermissionRequestOutcome(
                permission: permission,
                requestAccepted: false,
                verified: false,
                settingsResult: settingsResult
            )
        }

        journey.beginRequest(for: permission)
        let requestAccepted = requestClient.request(permission)
        let verified = requestClient.isGranted(permission)
        // The native request API may already present consent UI. Do not also
        // pull System Settings forward in the same click; that creates a
        // stacked, spammy flow and can hide the consent sheet. If the grant is
        // still unavailable, the next explicit action offers System Settings.
        let settingsResult: PermissionSettingsOpenResult? = nil
        lastSettingsResult = nil
        journey.completeRequest(
            for: permission,
            requestAccepted: requestAccepted,
            verified: verified,
            settingsOpened: false
        )
        return PermissionRequestOutcome(
            permission: permission,
            requestAccepted: requestAccepted,
            verified: verified,
            settingsResult: settingsResult
        )
    }

    @discardableResult
    public func openSettings(_ permission: ScreenlogPermission) -> PermissionSettingsOpenResult {
        let result = settingsOpener.open(permission)
        lastSettingsResult = result
        journey.markSettingsOpened(for: permission, opened: result.opened)
        return result
    }

    public func refresh(with snapshot: PermissionsSnapshot) {
        journey.refresh(with: snapshot)
        if snapshot.isCaptureReady {
            lastSettingsResult = nil
        }
    }
}

/// Stable drag payload used by the Setup UI and its tests. System Settings'
/// drop receiver varies by macOS release, so the UI always pairs this provider
/// with Finder and Add-button instructions.
public enum AppBundleDragProvider {
    public static func make(for appURL: URL) -> NSItemProvider {
        let provider = NSItemProvider(item: appURL as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.applicationBundle.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(appURL, false, nil)
            return nil
        }
        return provider
    }
}
