import Foundation

/// Stable identifiers for every rebindable Screenlogger command.
///
/// Native control semantics such as a sheet's default Return action and Escape
/// cancellation intentionally do not live here. Those belong to the control,
/// while these actions represent product commands that people may customize.
public enum KeyboardShortcutActionID: String, CaseIterable, Codable, Identifiable, Sendable {
    case findLibrary = "library.find"
    case showLibrary = "navigation.library"
    case showSessions = "navigation.sessions"
    case searchLibrary = "library.search"
    case showTimeline = "navigation.timeline"
    case showSettings = "navigation.settings"
    case toggleCapture = "capture.toggle"
    case quit = "application.quit"

    case askAssistant = "library.ask-assistant"

    case timelineFilter = "timeline.filter"
    case timelinePreviousMoment = "timeline.previous-moment"
    case timelineNextMoment = "timeline.next-moment"
    case timelinePreviousActivity = "timeline.previous-activity"
    case timelineNextActivity = "timeline.next-activity"
    case timelineToggleReplay = "timeline.toggle-replay"
    case timelineZoomIn = "timeline.zoom-in"
    case timelineZoomOut = "timeline.zoom-out"
    case timelineResetZoom = "timeline.reset-zoom"

    public var id: String { rawValue }
}

/// Where a shortcut is active. App-wide commands overlap every product window;
/// Library and Timeline commands may reuse one another because their windows
/// never route the same key event to both feature handlers.
public enum KeyboardShortcutScope: String, Codable, Sendable {
    case application
    case library
    case timeline

    public func overlaps(_ other: Self) -> Bool {
        self == .application || other == .application || self == other
    }
}

/// Stable grouping metadata for the future Keyboard Shortcuts settings pane.
public enum KeyboardShortcutCategory: String, CaseIterable, Codable, Sendable {
    case navigation
    case library
    case capture
    case timeline
    case application
}

/// Named keys that cannot be represented clearly as a printable character.
public enum KeyboardShortcutSpecialKey: String, CaseIterable, Codable, Sendable {
    case returnKey = "return"
    case space
    case leftArrow = "left-arrow"
    case rightArrow = "right-arrow"
    case upArrow = "up-arrow"
    case downArrow = "down-arrow"
    case tab
    case delete
    case forwardDelete = "forward-delete"
    case home
    case end
    case pageUp = "page-up"
    case pageDown = "page-down"

    fileprivate var displayLabel: String {
        switch self {
        case .returnKey: return "Return"
        case .space: return "Space"
        case .leftArrow: return "Left Arrow"
        case .rightArrow: return "Right Arrow"
        case .upArrow: return "Up Arrow"
        case .downArrow: return "Down Arrow"
        case .tab: return "Tab"
        case .delete: return "Delete"
        case .forwardDelete: return "Forward Delete"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        }
    }

    fileprivate var accessibilityLabel: String {
        switch self {
        case .returnKey: return "Return"
        case .space: return "Space"
        case .leftArrow: return "Left Arrow"
        case .rightArrow: return "Right Arrow"
        case .upArrow: return "Up Arrow"
        case .downArrow: return "Down Arrow"
        case .tab: return "Tab"
        case .delete: return "Delete"
        case .forwardDelete: return "Forward Delete"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        }
    }
}

/// A layout-aware printable key or a named non-printable key.
///
/// Printable characters are normalized to lowercase when that transformation
/// remains a single Character. Shift stays explicit in the modifier set.
public struct KeyboardShortcutKey: Hashable, Codable, Sendable {
    public let character: Character?
    public let specialKey: KeyboardShortcutSpecialKey?

    public static func character(_ character: Character) -> Self {
        let lowercase = String(character).lowercased()
        let normalized = lowercase.count == 1 ? lowercase.first! : character
        return Self(character: normalized, specialKey: nil)
    }

    public static func special(_ key: KeyboardShortcutSpecialKey) -> Self {
        Self(character: nil, specialKey: key)
    }

    public static let returnKey = special(.returnKey)
    public static let space = special(.space)
    public static let leftArrow = special(.leftArrow)
    public static let rightArrow = special(.rightArrow)
    public static let upArrow = special(.upArrow)
    public static let downArrow = special(.downArrow)

    public var displayLabel: String {
        if let character { return String(character).uppercased() }
        return specialKey?.displayLabel ?? ""
    }

    public var accessibilityLabel: String {
        if let character {
            switch character {
            case ",": return "Comma"
            case ".": return "Period"
            case "/": return "Slash"
            case "-": return "Minus"
            case "=": return "Equals"
            case "+": return "Plus"
            default: return String(character).uppercased()
            }
        }
        return specialKey?.accessibilityLabel ?? ""
    }

    private init(character: Character?, specialKey: KeyboardShortcutSpecialKey?) {
        self.character = character
        self.specialKey = specialKey
    }

    private enum CodingKeys: String, CodingKey {
        case character
        case specialKey = "special"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let characterValue = try container.decodeIfPresent(String.self, forKey: .character)
        let specialValue = try container.decodeIfPresent(
            KeyboardShortcutSpecialKey.self,
            forKey: .specialKey
        )

        switch (characterValue, specialValue) {
        case (.some(let value), nil):
            guard value.count == 1, let character = value.first else {
                throw DecodingError.dataCorruptedError(
                    forKey: .character,
                    in: container,
                    debugDescription: "A shortcut character must contain exactly one Character."
                )
            }
            self = .character(character)
        case (nil, .some(let specialKey)):
            self = .special(specialKey)
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A shortcut key must contain either a character or a special key."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let character {
            try container.encode(String(character), forKey: .character)
        } else if let specialKey {
            try container.encode(specialKey, forKey: .specialKey)
        }
    }
}

public enum KeyboardShortcutModifier: String, CaseIterable, Codable, Sendable {
    case control
    case option
    case shift
    case command

    fileprivate var displayLabel: String {
        switch self {
        case .control: return "Control-"
        case .option: return "Option-"
        case .shift: return "Shift-"
        case .command: return "Command-"
        }
    }

    fileprivate var accessibilityLabel: String {
        rawValue.capitalized
    }
}

/// A validated set of modifier keys with deterministic persistence and native
/// macOS display ordering.
public struct KeyboardShortcutModifiers:
    Hashable, Codable, Sendable, ExpressibleByArrayLiteral
{
    public typealias ArrayLiteralElement = KeyboardShortcutModifier

    private static let displayOrder: [KeyboardShortcutModifier] = [
        .control, .option, .shift, .command,
    ]

    private let values: Set<KeyboardShortcutModifier>

    public init(_ values: Set<KeyboardShortcutModifier> = []) {
        self.values = values
    }

    public init(arrayLiteral elements: KeyboardShortcutModifier...) {
        values = Set(elements)
    }

    public static let none = Self()
    public static let command: Self = [.command]

    public var isEmpty: Bool { values.isEmpty }

    public func contains(_ modifier: KeyboardShortcutModifier) -> Bool {
        values.contains(modifier)
    }

    public var ordered: [KeyboardShortcutModifier] {
        Self.displayOrder.filter(values.contains)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([KeyboardShortcutModifier].self)
        guard Set(decoded).count == decoded.count else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Shortcut modifiers may not contain duplicates."
            )
        }
        values = Set(decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ordered)
    }
}

public struct KeyboardShortcutBinding: Hashable, Codable, Sendable {
    public let key: KeyboardShortcutKey
    public let modifiers: KeyboardShortcutModifiers

    public init(
        key: KeyboardShortcutKey,
        modifiers: KeyboardShortcutModifiers = .none
    ) {
        self.key = key
        self.modifiers = modifiers
    }

    public var displayLabel: String {
        modifiers.ordered.map(\.displayLabel).joined() + key.displayLabel
    }

    public var accessibilityLabel: String {
        (modifiers.ordered.map(\.accessibilityLabel) + [key.accessibilityLabel])
            .joined(separator: "-")
    }
}

public struct KeyboardShortcutDefinition: Identifiable, Hashable, Sendable {
    public let id: KeyboardShortcutActionID
    public let title: String
    public let subtitle: String?
    public let category: KeyboardShortcutCategory
    public let scope: KeyboardShortcutScope
    public let defaultBinding: KeyboardShortcutBinding

    public init(
        id: KeyboardShortcutActionID,
        title: String,
        subtitle: String? = nil,
        category: KeyboardShortcutCategory,
        scope: KeyboardShortcutScope,
        defaultBinding: KeyboardShortcutBinding
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.scope = scope
        self.defaultBinding = defaultBinding
    }
}

public enum KeyboardShortcutRegistryError: Error, Equatable, Sendable {
    case duplicateAction(KeyboardShortcutActionID)
    case conflictingDefaults(KeyboardShortcutActionID, KeyboardShortcutActionID)
    case invalidDefault(KeyboardShortcutActionID, KeyboardShortcutValidationIssue)
}

/// The authority for action metadata and factory bindings.
public struct KeyboardShortcutRegistry: Sendable {
    public static let standard: Self = {
        if let registry = try? Self(definitions: standardDefinitions) {
            return registry
        }
        // Definitions are source-controlled and validated in tests, but a
        // future bad default must not make Screenlogger fail at launch. Keep
        // every independently valid, non-conflicting command available.
        return Self(recovering: standardDefinitions)
    }()

    public let definitions: [KeyboardShortcutDefinition]
    private let definitionsByID: [KeyboardShortcutActionID: KeyboardShortcutDefinition]

    public init(definitions: [KeyboardShortcutDefinition]) throws {
        var byID: [KeyboardShortcutActionID: KeyboardShortcutDefinition] = [:]
        for definition in definitions {
            guard byID.updateValue(definition, forKey: definition.id) == nil else {
                throw KeyboardShortcutRegistryError.duplicateAction(definition.id)
            }
            if case .invalid(let issue) = KeyboardShortcutValidation.validate(
                definition.defaultBinding,
                for: definition,
                allowsRegisteredDefault: true
            ) {
                throw KeyboardShortcutRegistryError.invalidDefault(definition.id, issue)
            }
        }

        for firstIndex in definitions.indices {
            for secondIndex in definitions.index(after: firstIndex)..<definitions.endIndex {
                let first = definitions[firstIndex]
                let second = definitions[secondIndex]
                if first.scope.overlaps(second.scope),
                    first.defaultBinding == second.defaultBinding
                {
                    throw KeyboardShortcutRegistryError.conflictingDefaults(first.id, second.id)
                }
            }
        }

        self.definitions = definitions
        definitionsByID = byID
    }

    private init(recovering definitions: [KeyboardShortcutDefinition]) {
        var accepted: [KeyboardShortcutDefinition] = []
        var byID: [KeyboardShortcutActionID: KeyboardShortcutDefinition] = [:]

        for definition in definitions {
            guard byID[definition.id] == nil else { continue }
            guard
                case .valid = KeyboardShortcutValidation.validate(
                    definition.defaultBinding,
                    for: definition,
                    allowsRegisteredDefault: true
                )
            else { continue }
            let conflicts = accepted.contains { existing in
                existing.scope.overlaps(definition.scope)
                    && existing.defaultBinding == definition.defaultBinding
            }
            guard !conflicts else { continue }
            accepted.append(definition)
            byID[definition.id] = definition
        }

        self.definitions = accepted
        definitionsByID = byID
    }

    public func definition(for actionID: KeyboardShortcutActionID) -> KeyboardShortcutDefinition? {
        definitionsByID[actionID]
    }

    private static let standardDefinitions: [KeyboardShortcutDefinition] = [
        .init(
            id: .showLibrary,
            title: "Show Search",
            category: .navigation,
            scope: .application,
            defaultBinding: .init(key: .character("1"), modifiers: .command)
        ),
        .init(
            id: .showSessions,
            title: "Show Sessions",
            category: .navigation,
            scope: .application,
            defaultBinding: .init(key: .character("2"), modifiers: .command)
        ),
        .init(
            id: .showTimeline,
            title: "Show Timeline",
            category: .navigation,
            scope: .application,
            defaultBinding: .init(key: .character("3"), modifiers: .command)
        ),
        .init(
            id: .showSettings,
            title: "Show Settings",
            category: .navigation,
            scope: .application,
            defaultBinding: .init(key: .character(","), modifiers: .command)
        ),
        .init(
            id: .findLibrary,
            title: "Find in Library",
            subtitle: "Selects or replaces the current query",
            category: .library,
            scope: .application,
            defaultBinding: .init(key: .character("f"), modifiers: .command)
        ),
        .init(
            id: .searchLibrary,
            title: "Search Library",
            subtitle: "Opens Library",
            category: .library,
            scope: .application,
            defaultBinding: .init(key: .character("k"), modifiers: .command)
        ),
        .init(
            id: .askAssistant,
            title: "Ask an Assistant",
            category: .library,
            scope: .library,
            defaultBinding: .init(key: .returnKey, modifiers: .command)
        ),
        .init(
            id: .toggleCapture,
            title: "Start or Pause Capture",
            category: .capture,
            scope: .application,
            defaultBinding: .init(key: .character("r"), modifiers: .command)
        ),
        .init(
            id: .timelineFilter,
            title: "Filter Timeline",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .character("/"))
        ),
        .init(
            id: .timelinePreviousMoment,
            title: "Previous Moment",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .leftArrow)
        ),
        .init(
            id: .timelineNextMoment,
            title: "Next Moment",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .rightArrow)
        ),
        .init(
            id: .timelinePreviousActivity,
            title: "Previous Activity",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .leftArrow, modifiers: [.option])
        ),
        .init(
            id: .timelineNextActivity,
            title: "Next Activity",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .rightArrow, modifiers: [.option])
        ),
        .init(
            id: .timelineToggleReplay,
            title: "Play or Pause Replay",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .space)
        ),
        .init(
            id: .timelineZoomIn,
            title: "Zoom In",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .character("+"), modifiers: .command)
        ),
        .init(
            id: .timelineZoomOut,
            title: "Zoom Out",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .character("-"), modifiers: .command)
        ),
        .init(
            id: .timelineResetZoom,
            title: "Reset Zoom",
            category: .timeline,
            scope: .timeline,
            defaultBinding: .init(key: .character("0"), modifiers: .command)
        ),
        .init(
            id: .quit,
            title: "Quit Screenlogger",
            category: .application,
            scope: .application,
            defaultBinding: .init(key: .character("q"), modifiers: .command)
        ),
    ]
}

public struct KeyboardShortcutConflict: Equatable, Sendable {
    public let actionID: KeyboardShortcutActionID
    public let conflictingActionID: KeyboardShortcutActionID
    public let binding: KeyboardShortcutBinding

    public init(
        actionID: KeyboardShortcutActionID,
        conflictingActionID: KeyboardShortcutActionID,
        binding: KeyboardShortcutBinding
    ) {
        self.actionID = actionID
        self.conflictingActionID = conflictingActionID
        self.binding = binding
    }
}

/// Why a shortcut cannot be assigned to a Screenlogger command.
public enum KeyboardShortcutValidationIssue: Error, Equatable, Sendable {
    /// The action is not present in this store's shortcut registry.
    case unregisteredAction
    /// The key is not a printable character or one of the supported named keys.
    case unsupportedKey
    /// Window-wide commands must not intercept ordinary typing or Shift-only input.
    case requiresCommandOptionOrControl
    /// The combination has a standard macOS meaning that Screenlogger should preserve.
    case reservedMacOSShortcut(KeyboardShortcutReservedCategory)
}

/// The native macOS behavior a reserved shortcut belongs to.
public enum KeyboardShortcutReservedCategory: String, Equatable, Sendable {
    case editing
    case windowManagement
    case system
}

/// The result of validating a prospective shortcut before conflict detection.
public enum KeyboardShortcutValidationResult: Equatable, Sendable {
    case valid
    case invalid(KeyboardShortcutValidationIssue)
}

/// Shared shortcut safety policy used by the registry, preference store, and UI.
public enum KeyboardShortcutValidation {
    public static func validate(
        _ binding: KeyboardShortcutBinding,
        for definition: KeyboardShortcutDefinition
    ) -> KeyboardShortcutValidationResult {
        validate(binding, for: definition, allowsRegisteredDefault: true)
    }

    fileprivate static func validate(
        _ binding: KeyboardShortcutBinding,
        for definition: KeyboardShortcutDefinition,
        allowsRegisteredDefault: Bool
    ) -> KeyboardShortcutValidationResult {
        guard isSupported(binding.key) else { return .invalid(.unsupportedKey) }

        if allowsRegisteredDefault, binding == definition.defaultBinding {
            return .valid
        }

        if definition.scope != .timeline,
            !binding.modifiers.contains(.command),
            !binding.modifiers.contains(.option),
            !binding.modifiers.contains(.control)
        {
            return .invalid(.requiresCommandOptionOrControl)
        }

        if let category = reservedCategory(for: binding) {
            return .invalid(.reservedMacOSShortcut(category))
        }
        return .valid
    }

    private static func isSupported(_ key: KeyboardShortcutKey) -> Bool {
        guard let character = key.character else { return key.specialKey != nil }
        return character.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private static func reservedCategory(
        for binding: KeyboardShortcutBinding
    ) -> KeyboardShortcutReservedCategory? {
        reservedBindings[binding]
    }

    private static let reservedBindings: [KeyboardShortcutBinding: KeyboardShortcutReservedCategory] = {
        var result: [KeyboardShortcutBinding: KeyboardShortcutReservedCategory] = [:]

        func reserve(
            _ key: KeyboardShortcutKey,
            _ modifiers: KeyboardShortcutModifiers,
            as category: KeyboardShortcutReservedCategory
        ) {
            result[.init(key: key, modifiers: modifiers)] = category
        }

        for character: Character in ["a", "b", "c", "i", "u", "v", "x", "z"] {
            reserve(.character(character), [.command], as: .editing)
        }
        reserve(.character("z"), [.shift, .command], as: .editing)

        for character: Character in ["h", "m", "w", "`"] {
            reserve(.character(character), [.command], as: .windowManagement)
        }
        reserve(.character("h"), [.option, .command], as: .windowManagement)

        for character: Character in ["n", "o", "p", "s"] {
            reserve(.character(character), [.command], as: .system)
        }
        for character: Character in [",", "f", "q", "r"] {
            reserve(.character(character), [.command], as: .system)
        }
        reserve(.space, [.command], as: .system)
        reserve(.space, [.option, .command], as: .system)
        reserve(.space, [.control, .command], as: .system)
        reserve(.special(.tab), [.command], as: .system)
        reserve(.special(.tab), [.shift, .command], as: .system)
        reserve(.character("d"), [.option, .command], as: .system)
        reserve(.character("f"), [.control, .command], as: .system)
        reserve(.character("q"), [.control, .command], as: .system)
        for character: Character in ["3", "4", "5"] {
            reserve(.character(character), [.shift, .command], as: .system)
        }
        for key: KeyboardShortcutKey in [.leftArrow, .rightArrow, .upArrow, .downArrow] {
            reserve(key, [.control], as: .system)
        }

        return result
    }()
}

public enum KeyboardShortcutPersistenceStatus: Equatable, Sendable {
    case defaults
    case loaded(version: Int)
    case repaired(version: Int, discardedActions: [KeyboardShortcutActionID])
    case migrated(fromVersion: Int, toVersion: Int)
    case unsupportedVersion(Int)
    case corrupt
}

/// A persisted override that was discarded because it no longer passes policy.
public struct KeyboardShortcutPersistenceRepair: Equatable, Sendable {
    public let actionID: KeyboardShortcutActionID
    public let issue: KeyboardShortcutValidationIssue

    public init(
        actionID: KeyboardShortcutActionID,
        issue: KeyboardShortcutValidationIssue
    ) {
        self.actionID = actionID
        self.issue = issue
    }
}

public enum KeyboardShortcutStoreError: Error, Equatable, Sendable {
    case unregisteredAction(KeyboardShortcutActionID)
    case invalidBinding(KeyboardShortcutActionID, KeyboardShortcutValidationIssue)
    case conflicts([KeyboardShortcutConflict])
    case couldNotEncode
}

/// Versioned, UserDefaults-backed shortcut preferences.
///
/// Only overrides are persisted, so newly added product actions automatically
/// inherit their registry defaults. Unknown entries survive writes from an
/// older app build, which keeps downgrade/upgrade cycles from erasing future
/// preferences.
public final class KeyboardShortcutStore: @unchecked Sendable {
    public static let defaultsKey = "screenlog.keyboardShortcuts"
    public static let currentSchemaVersion = 1
    public static let didChangeNotification = Notification.Name(
        "dev.screenlog.keyboard-shortcuts-did-change"
    )
    public static let changedActionUserInfoKey = "actionID"

    public let registry: KeyboardShortcutRegistry

    private let defaults: UserDefaults
    private let key: String
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var overrides: [KeyboardShortcutActionID: Override] = [:]
    private var unknownEntries: [PersistedEntry] = []
    private var status: KeyboardShortcutPersistenceStatus = .defaults
    private var repairs: [KeyboardShortcutPersistenceRepair] = []

    public init(
        defaults: UserDefaults = ScreenlogProcessPreferences.current,
        key: String = KeyboardShortcutStore.defaultsKey,
        registry: KeyboardShortcutRegistry = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.key = key
        self.registry = registry
        self.notificationCenter = notificationCenter
        load()
    }

    public var persistenceStatus: KeyboardShortcutPersistenceStatus {
        lock.withLock { status }
    }

    public var persistenceRepairs: [KeyboardShortcutPersistenceRepair] {
        lock.withLock { repairs }
    }

    public func binding(for actionID: KeyboardShortcutActionID) -> KeyboardShortcutBinding? {
        lock.withLock { effectiveBinding(for: actionID, overrides: overrides) }
    }

    public func bindings() -> [KeyboardShortcutActionID: KeyboardShortcutBinding] {
        lock.withLock {
            Dictionary(
                uniqueKeysWithValues: registry.definitions.compactMap { definition in
                    effectiveBinding(for: definition.id, overrides: overrides).map {
                        (definition.id, $0)
                    }
                }
            )
        }
    }

    public func conflicts(
        for binding: KeyboardShortcutBinding,
        assignedTo actionID: KeyboardShortcutActionID
    ) -> [KeyboardShortcutConflict] {
        lock.withLock {
            conflicts(
                for: binding,
                assignedTo: actionID,
                overrides: overrides
            )
        }
    }

    public func validationResult(
        for binding: KeyboardShortcutBinding,
        assignedTo actionID: KeyboardShortcutActionID
    ) -> KeyboardShortcutValidationResult {
        guard let definition = registry.definition(for: actionID) else {
            return .invalid(.unregisteredAction)
        }
        return KeyboardShortcutValidation.validate(binding, for: definition)
    }

    public func allConflicts() -> [KeyboardShortcutConflict] {
        lock.withLock { allConflicts(overrides: overrides) }
    }

    /// Assigns a custom binding, or disables the command when `binding` is nil.
    /// Conflicting changes fail without modifying memory or persisted state.
    public func setBinding(
        _ binding: KeyboardShortcutBinding?,
        for actionID: KeyboardShortcutActionID
    ) throws {
        guard let definition = registry.definition(for: actionID) else {
            throw KeyboardShortcutStoreError.unregisteredAction(actionID)
        }
        if let binding,
            case .invalid(let issue) = KeyboardShortcutValidation.validate(
                binding,
                for: definition
            )
        {
            throw KeyboardShortcutStoreError.invalidBinding(actionID, issue)
        }
        try mutate(actionID: actionID) { candidate in
            if let binding {
                candidate[actionID] =
                    binding == definition.defaultBinding
                    ? nil
                    : .binding(binding)
            } else {
                candidate[actionID] = .disabled
            }
        }
    }

    public func resetToDefault(for actionID: KeyboardShortcutActionID) throws {
        try mutate(actionID: actionID) { candidate in
            guard registry.definition(for: actionID) != nil else {
                throw KeyboardShortcutStoreError.unregisteredAction(actionID)
            }
            candidate[actionID] = nil
        }
    }

    public func resetToDefaults() {
        lock.withLock {
            overrides.removeAll()
            unknownEntries.removeAll()
            repairs.removeAll()
            status = .defaults
            defaults.removeObject(forKey: key)
        }
        postChange(actionID: nil)
    }

    private func mutate(
        actionID: KeyboardShortcutActionID,
        update: (inout [KeyboardShortcutActionID: Override]) throws -> Void
    ) throws {
        try lock.withLock {
            var candidate = overrides
            try update(&candidate)
            let conflicts = allConflicts(overrides: candidate)
            guard conflicts.isEmpty else {
                throw KeyboardShortcutStoreError.conflicts(conflicts)
            }
            guard let data = encode(overrides: candidate, unknownEntries: unknownEntries) else {
                throw KeyboardShortcutStoreError.couldNotEncode
            }
            defaults.set(data, forKey: key)
            overrides = candidate
            repairs.removeAll()
            status = .loaded(version: Self.currentSchemaVersion)
        }
        postChange(actionID: actionID)
    }

    private func postChange(actionID: KeyboardShortcutActionID?) {
        var userInfo: [AnyHashable: Any]?
        if let actionID {
            userInfo = [Self.changedActionUserInfoKey: actionID.rawValue]
        }
        notificationCenter.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: userInfo
        )
    }

    private func effectiveBinding(
        for actionID: KeyboardShortcutActionID,
        overrides: [KeyboardShortcutActionID: Override]
    ) -> KeyboardShortcutBinding? {
        if let override = overrides[actionID] {
            switch override {
            case .binding(let binding): return binding
            case .disabled: return nil
            }
        }
        return registry.definition(for: actionID)?.defaultBinding
    }

    private func conflicts(
        for binding: KeyboardShortcutBinding,
        assignedTo actionID: KeyboardShortcutActionID,
        overrides: [KeyboardShortcutActionID: Override]
    ) -> [KeyboardShortcutConflict] {
        guard let definition = registry.definition(for: actionID) else { return [] }
        return registry.definitions.compactMap { other in
            guard other.id != actionID,
                definition.scope.overlaps(other.scope),
                effectiveBinding(for: other.id, overrides: overrides) == binding
            else { return nil }
            return KeyboardShortcutConflict(
                actionID: actionID,
                conflictingActionID: other.id,
                binding: binding
            )
        }
    }

    private func allConflicts(
        overrides: [KeyboardShortcutActionID: Override]
    ) -> [KeyboardShortcutConflict] {
        var result: [KeyboardShortcutConflict] = []
        let definitions = registry.definitions
        for firstIndex in definitions.indices {
            let first = definitions[firstIndex]
            guard let firstBinding = effectiveBinding(for: first.id, overrides: overrides) else {
                continue
            }
            for secondIndex in definitions.index(after: firstIndex)..<definitions.endIndex {
                let second = definitions[secondIndex]
                guard first.scope.overlaps(second.scope),
                    effectiveBinding(for: second.id, overrides: overrides) == firstBinding
                else { continue }
                result.append(
                    .init(
                        actionID: first.id,
                        conflictingActionID: second.id,
                        binding: firstBinding
                    )
                )
            }
        }
        return result
    }

    private func load() {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else {
                status = defaults.object(forKey: key) == nil ? .defaults : .corrupt
                return
            }

            let decoder = JSONDecoder()
            guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
                status = .corrupt
                return
            }

            switch probe.schemaVersion {
            case 0:
                guard let document = try? decoder.decode(LegacyDocument.self, from: data) else {
                    status = .corrupt
                    return
                }
                let migratedEntries = document.bindings.map {
                    PersistedEntry(actionID: $0.key, binding: $0.value)
                }
                guard let installResult = install(entries: migratedEntries) else {
                    status = .corrupt
                    return
                }
                repairs = installResult.repairs
                status = .migrated(fromVersion: 0, toVersion: Self.currentSchemaVersion)
                if let upgraded = encode(overrides: overrides, unknownEntries: unknownEntries) {
                    defaults.set(upgraded, forKey: key)
                }
            case Self.currentSchemaVersion:
                guard let document = try? decoder.decode(PersistedDocument.self, from: data),
                    let installResult = install(entries: document.entries)
                else {
                    status = .corrupt
                    return
                }
                repairs = installResult.repairs
                if installResult.repairs.isEmpty {
                    status = .loaded(version: Self.currentSchemaVersion)
                } else {
                    status = .repaired(
                        version: Self.currentSchemaVersion,
                        discardedActions: installResult.repairs.map(\.actionID)
                    )
                    if let repaired = encode(
                        overrides: overrides,
                        unknownEntries: unknownEntries
                    ) {
                        defaults.set(repaired, forKey: key)
                    }
                }
            default:
                status = .unsupportedVersion(probe.schemaVersion)
            }
        }
    }

    private func install(entries: [PersistedEntry]) -> InstallResult? {
        var seen = Set<String>()
        var loadedOverrides: [KeyboardShortcutActionID: Override] = [:]
        var loadedUnknown: [PersistedEntry] = []
        var loadedRepairs: [KeyboardShortcutPersistenceRepair] = []

        for entry in entries {
            guard seen.insert(entry.actionID).inserted else { return nil }
            guard let actionID = KeyboardShortcutActionID(rawValue: entry.actionID),
                let definition = registry.definition(for: actionID)
            else {
                loadedUnknown.append(entry)
                continue
            }
            if let binding = entry.binding {
                switch KeyboardShortcutValidation.validate(binding, for: definition) {
                case .valid:
                    loadedOverrides[actionID] = .binding(binding)
                case .invalid(let issue):
                    loadedRepairs.append(.init(actionID: actionID, issue: issue))
                }
            } else {
                loadedOverrides[actionID] = .disabled
            }
        }

        // Navigation defaults moved when Sessions gained its own command.
        // An intentional override wins over either newly assigned default;
        // never discard the person's entire shortcut catalog on upgrade.
        for actionID in [KeyboardShortcutActionID.showSessions, .showTimeline] {
            guard loadedOverrides[actionID] == nil,
                let definition = registry.definition(for: actionID)
            else { continue }
            let binding = definition.defaultBinding
            let hasCustomConflict = registry.definitions.contains { other in
                guard other.id != actionID,
                    definition.scope.overlaps(other.scope),
                    case .binding(let custom) = loadedOverrides[other.id]
                else { return false }
                return custom == binding
            }
            if hasCustomConflict {
                loadedOverrides[actionID] = .disabled
            }
        }

        guard allConflicts(overrides: loadedOverrides).isEmpty else { return nil }

        overrides = loadedOverrides
        unknownEntries = loadedUnknown
        return InstallResult(
            repairs: loadedRepairs.sorted { $0.actionID.rawValue < $1.actionID.rawValue }
        )
    }

    private func encode(
        overrides: [KeyboardShortcutActionID: Override],
        unknownEntries: [PersistedEntry]
    ) -> Data? {
        var entries = overrides.map { actionID, override in
            switch override {
            case .binding(let binding):
                return PersistedEntry(actionID: actionID.rawValue, binding: binding)
            case .disabled:
                return PersistedEntry(actionID: actionID.rawValue, binding: nil)
            }
        }
        entries.append(contentsOf: unknownEntries)
        entries.sort { $0.actionID < $1.actionID }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(
            PersistedDocument(
                schemaVersion: Self.currentSchemaVersion,
                entries: entries
            )
        )
    }

    private enum Override {
        case binding(KeyboardShortcutBinding)
        case disabled
    }

    private struct InstallResult {
        let repairs: [KeyboardShortcutPersistenceRepair]
    }

    private struct VersionProbe: Codable {
        let schemaVersion: Int
    }

    private struct PersistedDocument: Codable {
        let schemaVersion: Int
        let entries: [PersistedEntry]
    }

    private struct PersistedEntry: Codable {
        let actionID: String
        let binding: KeyboardShortcutBinding?
    }

    private struct LegacyDocument: Codable {
        let schemaVersion: Int
        let bindings: [String: KeyboardShortcutBinding]
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
