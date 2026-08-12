import Foundation
import ScreenlogCore

/// Spoken state shared by custom checkbox and switch rows in Settings.
/// Native controls usually infer this value, but explicit values keep custom
/// label-hidden layouts predictable for VoiceOver.
enum SettingsAccessibilityValue {
    static func onOff(_ isOn: Bool) -> String {
        isOn ? "On" : "Off"
    }
}

enum CaptureDisplaySettingsCopy {
    static func summary(_ mode: CaptureDisplayMode) -> String {
        switch mode {
        case .active:
            return "Follows the display containing the app you are using."
        case .all:
            return "Saves every connected display at each interval."
        }
    }

    static func connectionNote(_ mode: CaptureDisplayMode, count: Int) -> String {
        let count = max(1, count)
        switch mode {
        case .active:
            if count == 1 { return "1 display connected. One moment is saved per interval." }
            return "\(count) displays connected. One moment is saved per interval as focus moves."
        case .all:
            if count == 1 {
                return "1 display connected. Displays connected later are included automatically."
            }
            return
                "\(count) displays connected. Each interval saves one Timeline moment with \(count) display images and uses roughly \(count)x the processing and storage."
        }
    }
}

/// A stable place inside Screenlogger Settings.
///
/// Callers describe the outcome they want instead of knowing how a pane is
/// laid out. Section destinations reveal the pane from its top, while anchored
/// destinations bring a specific control group into view.
enum SettingsDestination: Hashable {
    case section(SettingsSidebarItem)
    case anchor(SettingsAnchor)

    static let general = section(SettingsSidebarItem.general)
    static let appearance = section(SettingsSidebarItem.appearance)
    static let shortcuts = section(SettingsSidebarItem.shortcuts)
    static let capture = section(SettingsSidebarItem.capture)
    static let privacy = section(SettingsSidebarItem.privacy)
    static let exclusions = section(SettingsSidebarItem.exclusions)
    static let storage = section(SettingsSidebarItem.storage)
    static let integrations = section(SettingsSidebarItem.integrations)
    static let support = section(SettingsSidebarItem.support)

    static let captureStatus = anchor(SettingsAnchor.captureStatus)
    static let captureOnce = anchor(SettingsAnchor.captureOnce)
    static let captureDisplays = anchor(SettingsAnchor.captureDisplays)
    static let captureTiming = anchor(SettingsAnchor.captureTiming)
    static let captureAudio = anchor(SettingsAnchor.captureAudio)
    static let privacyPermissions = anchor(SettingsAnchor.privacyPermissions)
    static let privacyProtection = anchor(SettingsAnchor.privacyProtection)
    static let privacyNetwork = anchor(SettingsAnchor.privacyNetwork)
    static let privacyLocalData = anchor(SettingsAnchor.privacyLocalData)
    static let exclusionsApplications = anchor(SettingsAnchor.exclusionsApplications)
    static let exclusionsWebsites = anchor(SettingsAnchor.exclusionsWebsites)
    static let storageOverview = anchor(SettingsAnchor.storageOverview)
    static let storageManagement = anchor(SettingsAnchor.storageManagement)
    static let storageLibraryTools = anchor(SettingsAnchor.storageLibraryTools)
    static let integrationsLocalTools = anchor(SettingsAnchor.integrationsLocalTools)
    static let integrationsAssistantConnections =
        anchor(SettingsAnchor.integrationsAssistantConnections)
    static let supportGuide = anchor(SettingsAnchor.supportGuide)
    static let supportDiagnostics = anchor(SettingsAnchor.supportDiagnostics)

    var section: SettingsSidebarItem {
        switch self {
        case .section(let section): return section
        case .anchor(let anchor): return anchor.section
        }
    }

    var anchor: SettingsAnchor? {
        guard case .anchor(let anchor) = self else { return nil }
        return anchor
    }

}

enum SettingsAnchor: String, CaseIterable, Hashable {
    case captureStatus = "capture-status"
    case captureOnce = "capture-once"
    case captureDisplays = "capture-displays"
    case captureTiming = "capture-timing"
    case captureAudio = "capture-audio"
    case privacyPermissions = "privacy-permissions"
    case privacyProtection = "privacy-protection"
    case privacyNetwork = "privacy-network"
    case privacyLocalData = "privacy-local-data"
    case exclusionsApplications = "exclusions-applications"
    case exclusionsWebsites = "exclusions-websites"
    case storageOverview = "storage-overview"
    case storageManagement = "storage-management"
    case storageLibraryTools = "storage-library-tools"
    case integrationsLocalTools = "integrations-local-tools"
    case integrationsAssistantConnections = "integrations-assistant-connections"
    case supportGuide = "support-guide"
    case supportDiagnostics = "support-diagnostics"

    var section: SettingsSidebarItem {
        switch self {
        case .captureStatus, .captureOnce, .captureDisplays, .captureTiming, .captureAudio:
            return .capture
        case .privacyPermissions, .privacyProtection, .privacyNetwork, .privacyLocalData:
            return .privacy
        case .exclusionsApplications, .exclusionsWebsites:
            return .exclusions
        case .storageOverview, .storageManagement, .storageLibraryTools:
            return .storage
        case .integrationsLocalTools, .integrationsAssistantConnections:
            return .integrations
        case .supportGuide, .supportDiagnostics:
            return .support
        }
    }

    var accessibilityIdentifier: String {
        "settings.destination.\(rawValue)"
    }

    var searchResultAccessibilityIdentifier: String {
        "settings.search-result.\(rawValue)"
    }

    var systemImage: String {
        switch self {
        case .integrationsLocalTools: return "terminal"
        case .integrationsAssistantConnections: return "bubble.left.and.bubble.right"
        case .captureDisplays: return "rectangle.on.rectangle"
        case .captureStatus, .captureOnce, .captureTiming: return "record.circle"
        case .captureAudio: return "waveform.badge.mic"
        case .privacyPermissions, .privacyProtection, .privacyNetwork, .privacyLocalData:
            return "hand.raised"
        case .exclusionsApplications, .exclusionsWebsites: return "eye.slash"
        case .storageOverview, .storageManagement, .storageLibraryTools: return "internaldrive"
        case .supportGuide, .supportDiagnostics: return "lifepreserver"
        }
    }

    /// A concise destination name for VoiceOver and programmatic focus.
    var accessibilityLabel: String {
        switch self {
        case .captureStatus: return "Capture status"
        case .captureOnce: return "Capture a moment"
        case .captureDisplays: return "Capture displays"
        case .captureTiming: return "Capture timing"
        case .captureAudio: return "Audio transcription"
        case .privacyPermissions: return "Screen capture permissions"
        case .privacyProtection: return "Privacy protection"
        case .privacyNetwork: return "Network privacy"
        case .privacyLocalData: return "Library data"
        case .exclusionsApplications: return "Excluded applications"
        case .exclusionsWebsites: return "Excluded websites"
        case .storageOverview: return "Storage overview"
        case .storageManagement: return "Automatic storage"
        case .storageLibraryTools: return "Library tools"
        case .integrationsLocalTools: return "Command Setup"
        case .integrationsAssistantConnections: return "Assistant Connections"
        case .supportGuide: return "User guide"
        case .supportDiagnostics: return "Diagnostics"
        }
    }

    fileprivate var searchTerms: [String] {
        switch self {
        case .captureStatus:
            return ["recording", "running", "pause", "resume", "start", "health"]
        case .captureOnce:
            return ["manual", "capture now", "save moment", "screenshot"]
        case .captureDisplays:
            return [
                "display", "displays", "monitor", "monitors", "multiple monitors", "multi-display",
                "all screens", "active display",
            ]
        case .captureTiming:
            return ["interval", "timer", "frequency", "inactive", "inactivity"]
        case .captureAudio:
            return [
                "audio", "transcription", "transcript", "microphone", "computer audio",
                "speech", "meeting", "presentation", "caption", "voice",
            ]
        case .privacyPermissions:
            return ["permission", "screen recording", "accessibility", "system settings"]
        case .privacyProtection:
            return ["protected activity", "private browsing", "incognito", "exclude"]
        case .privacyNetwork:
            return ["network", "offline", "airgap", "favicon", "internet"]
        case .privacyLocalData:
            return ["local", "library location", "data folder", "on this Mac"]
        case .exclusionsApplications:
            return ["apps", "applications", "skip app", "excluded app"]
        case .exclusionsWebsites:
            return ["websites", "domains", "browser", "private tabs", "excluded website"]
        case .storageOverview:
            return ["disk", "space", "usage", "library size"]
        case .storageManagement:
            return ["retention", "limit", "compress", "cleanup", "automatic"]
        case .storageLibraryTools:
            return ["backup", "copy", "export", "restore", "finder", "delete", "history"]
        case .integrationsLocalTools:
            return [
                "terminal", "terminal command", "screenlog command", "command line", "CLI",
                "shell", "PATH", "local tool", "connection",
            ]
        case .integrationsAssistantConnections:
            return [
                "assistant", "AI", "agent", "skill", "ChatGPT", "Claude", "Cursor", "Codex",
                "Grok", "Grok Build", "OpenClaw",
            ]
        case .supportGuide:
            return ["help", "guide", "documentation", "getting started"]
        case .supportDiagnostics:
            return ["diagnostics", "support bundle", "troubleshooting", "bundle contents"]
        }
    }
}

/// The identifier makes selecting the same destination twice an observable
/// navigation event, which is required by the retained Settings window.
struct SettingsNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let destination: SettingsDestination
    let focusedElementIdentifier: String?

    init(
        destination: SettingsDestination,
        focusedElementIdentifier: String? = nil
    ) {
        self.destination = destination
        self.focusedElementIdentifier = focusedElementIdentifier
    }
}

/// Presentation request shared with a destination pane after Settings has
/// switched sections. Keeping the request identifier makes choosing the same
/// search result twice observable by both focus and pane-local navigation.
struct SettingsDestinationFocusRequest: Equatable {
    let id: UUID
    let anchor: SettingsAnchor
    let focusedElementIdentifier: String?

    init(
        id: UUID,
        anchor: SettingsAnchor,
        focusedElementIdentifier: String? = nil
    ) {
        self.id = id
        self.anchor = anchor
        self.focusedElementIdentifier = focusedElementIdentifier
    }
}

// MARK: - Sidebar search model

enum SettingsSidebarItem: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, shortcuts, capture, privacy, exclusions, storage, integrations, support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .integrations: return "Integrations"
        case .appearance: return "Appearance"
        case .shortcuts: return "Keyboard Shortcuts"
        case .capture: return "Capture"
        case .privacy: return "Privacy"
        case .storage: return "Storage"
        case .exclusions: return "Exclusions"
        case .support: return "Support & About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .integrations: return "terminal"
        case .appearance: return "circle.lefthalf.filled"
        case .shortcuts: return "keyboard"
        case .capture: return "record.circle"
        case .privacy: return "hand.raised"
        case .storage: return "internaldrive"
        case .exclusions: return "eye.slash"
        case .support: return "lifepreserver"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Startup and app behavior"
        case .integrations: return "Terminal command and assistant connections"
        case .appearance: return "Theme and Timeline controls"
        case .shortcuts: return "Customize how you navigate and control Screenlogger"
        case .capture: return "Displays, timing, image quality, text, and audio"
        case .privacy: return "Permissions, protected activity, and Library data"
        case .storage: return "Library usage and retention"
        case .exclusions: return "Apps and detectable websites Screenlogger skips"
        case .support: return "Versions and privacy-safe diagnostics"
        }
    }

    var accessibilityHint: String { "Show \(title) settings" }

    fileprivate var searchTerms: [String] {
        switch self {
        case .general:
            return [title, subtitle, "startup", "open at login", "dock", "menu bar", "visibility"]
        case .appearance:
            return [
                title, subtitle, "theme", "light", "dark", "accent", "timeline controls",
                "open source", "detected text", "zoom", "segment navigation",
            ]
        case .shortcuts:
            return [
                title, subtitle, "keyboard", "keys", "key binding", "keybindings", "hotkey",
                "customize", "disable", "reset", "conflict", "rebind",
            ]
        case .capture:
            return [
                title, subtitle, "recording", "quality", "interval", "OCR", "text recognition",
                "encoding", "display", "monitor", "multiple screens", "audio", "transcription",
                "microphone", "computer audio",
            ]
        case .privacy:
            return [title, subtitle, "permission", "screen recording", "accessibility", "offline", "network", "local"]
        case .exclusions:
            return [title, subtitle, "skip", "apps", "websites", "private browsing", "incognito"]
        case .storage:
            return [
                title, subtitle, "disk", "space", "retention", "limit", "compress", "library",
                "backup", "copy", "export", "restore", "finder", "delete", "history",
            ]
        case .integrations:
            return [
                title, subtitle, "terminal", "terminal command", "screenlog command", "command line",
                "CLI", "shell", "PATH", "local tool", "connection", "assistant", "AI", "agent",
                "skill", "ChatGPT", "Claude", "Cursor", "Codex", "Grok", "Grok Build", "OpenClaw",
            ]
        case .support:
            return [
                title, subtitle, "help", "privacy", "diagnostics", "bundle contents",
                "support bundle", "version", "troubleshooting",
            ]
        }
    }
}

/// A visible, activatable Settings search hit. Search only filters this index;
/// navigation happens after the person chooses a result.
struct SettingsSearchResult: Identifiable, Hashable {
    let destination: SettingsDestination
    let title: String
    let subtitle: String
    let systemImage: String
    fileprivate let searchTerms: [String]

    var id: String {
        switch destination {
        case .section(let section): return "section.\(section.rawValue)"
        case .anchor(let anchor): return anchor.rawValue
        }
    }

    var accessibilityIdentifier: String {
        switch destination {
        case .section(let section): return "settings.search-result.section.\(section.rawValue)"
        case .anchor(let anchor): return anchor.searchResultAccessibilityIdentifier
        }
    }

    func matches(_ query: String) -> Bool {
        SettingsSearchResult.matches(query, terms: [title, subtitle] + searchTerms)
    }

    static func matching(_ query: String) -> [Self] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let exactMatches = all.filter {
            $0.title.compare(
                normalized,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
        if !exactMatches.isEmpty { return exactMatches }

        let broadSectionMatches = all.filter { result in
            guard case .section = result.destination else { return false }
            return comparableSectionName(result.title) == comparableSectionName(normalized)
        }
        if !broadSectionMatches.isEmpty { return broadSectionMatches }

        let matches = all.filter { $0.matches(normalized) }
        let sectionsWithSpecificMatches = Set(
            matches.compactMap { result -> SettingsSidebarItem? in
                guard case .anchor = result.destination else { return nil }
                return result.destination.section
            }
        )
        return matches.filter { result in
            guard case .section(let section) = result.destination else { return true }
            return !sectionsWithSpecificMatches.contains(section)
        }
    }

    private static let all: [Self] = {
        let sections = SettingsSidebarItem.allCases.map { section in
            Self(
                destination: .section(section),
                title: section.title,
                subtitle: section.subtitle,
                systemImage: section.systemImage,
                searchTerms: section.searchTerms
            )
        }
        let anchors = SettingsAnchor.allCases.map { anchor in
            Self(
                destination: .anchor(anchor),
                title: anchor.accessibilityLabel,
                subtitle: "\(anchor.section.title) settings",
                systemImage: anchor.systemImage,
                searchTerms: anchor.searchTerms
            )
        }
        return sections + anchors
    }()

    private static func matches(_ query: String, terms: [String]) -> Bool {
        let searchableText = terms.joined(separator: " ")
        return query.split(whereSeparator: \Character.isWhitespace).allSatisfy { token in
            searchableText.localizedCaseInsensitiveContains(String(token))
        }
    }

    private static func comparableSectionName(_ value: String) -> String {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasSuffix("s") ? String(normalized.dropLast()) : normalized
    }
}

struct SettingsSidebarSection: Identifiable {
    let id: String
    let title: String
    let items: [SettingsSidebarItem]

    static let all = [
        SettingsSidebarSection(
            id: "app",
            title: "App",
            items: [.general, .appearance, .shortcuts]
        ),
        SettingsSidebarSection(
            id: "capture-and-data",
            title: "Capture & Data",
            items: [.capture, .privacy, .exclusions, .storage]
        ),
        SettingsSidebarSection(
            id: "tools-and-support",
            title: "Tools & Support",
            items: [.integrations, .support]
        ),
    ]
}
