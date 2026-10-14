import Foundation
import XCTest

@testable import ScreenlogCore

final class KeyboardShortcutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "screenlog.test.keyboard-shortcuts.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNumberedNavigationDefaultsAreAppWideAndDistinct() {
        let store = KeyboardShortcutStore(defaults: defaults)
        for (action, key) in [
            (KeyboardShortcutActionID.showLibrary, Character("1")),
            (.showSessions, "2"),
            (.showTimeline, "3"),
        ] {
            XCTAssertEqual(
                store.binding(for: action),
                KeyboardShortcutBinding(key: .character(key), modifiers: .command)
            )
            XCTAssertEqual(store.registry.definition(for: action)?.scope, .application)
        }
        XCTAssertTrue(store.allConflicts().isEmpty)
    }

    func testExistingOverridesSurviveNewNavigationDefaults() throws {
        let commandTwo = KeyboardShortcutBinding(key: .character("2"), modifiers: .command)
        let commandThree = KeyboardShortcutBinding(key: .character("3"), modifiers: .command)
        try persistCurrentDocument([
            (KeyboardShortcutActionID.showTimeline.rawValue, commandTwo),
            (KeyboardShortcutActionID.showLibrary.rawValue, commandThree),
            (KeyboardShortcutActionID.timelineToggleReplay.rawValue, nil),
        ])

        let store = KeyboardShortcutStore(defaults: defaults)
        XCTAssertEqual(store.persistenceStatus, .loaded(version: 1))
        XCTAssertEqual(store.binding(for: .showTimeline), commandTwo)
        XCTAssertEqual(store.binding(for: .showLibrary), commandThree)
        XCTAssertNil(store.binding(for: .showSessions))
        XCTAssertNil(store.binding(for: .timelineToggleReplay))
        XCTAssertTrue(store.allConflicts().isEmpty)

        // A later customization must persist the displaced default as disabled.
        try store.setBinding(nil, for: .askAssistant)
        let restored = KeyboardShortcutStore(defaults: defaults)
        XCTAssertEqual(restored.binding(for: .showTimeline), commandTwo)
        XCTAssertEqual(restored.binding(for: .showLibrary), commandThree)
        XCTAssertNil(restored.binding(for: .showSessions))
        XCTAssertTrue(restored.allConflicts().isEmpty)
        restored.resetToDefaults()
        XCTAssertEqual(restored.binding(for: .showSessions), commandTwo)
        XCTAssertEqual(restored.binding(for: .showTimeline), commandThree)
    }

    func testStandardRegistryCoversEveryActionAndHasNoConflicts() {
        let registry = KeyboardShortcutRegistry.standard

        XCTAssertEqual(Set(registry.definitions.map(\.id)), Set(KeyboardShortcutActionID.allCases))
        XCTAssertEqual(
            registry.definition(for: .askAssistant)?.defaultBinding,
            KeyboardShortcutBinding(key: .returnKey, modifiers: .command)
        )
        XCTAssertTrue(KeyboardShortcutStore(defaults: defaults).allConflicts().isEmpty)
        for definition in registry.definitions {
            XCTAssertEqual(
                KeyboardShortcutValidation.validate(
                    definition.defaultBinding,
                    for: definition
                ),
                .valid,
                definition.id.rawValue
            )
        }
    }

    func testWindowWideCharacterShortcutsRequireACommandOptionOrControlModifier() throws {
        let store = KeyboardShortcutStore(defaults: defaults)

        XCTAssertEqual(
            store.validationResult(
                for: .init(key: .character("g")),
                assignedTo: .showLibrary
            ),
            .invalid(.requiresCommandOptionOrControl)
        )
        XCTAssertEqual(
            store.validationResult(
                for: .init(key: .character("g"), modifiers: [.shift]),
                assignedTo: .askAssistant
            ),
            .invalid(.requiresCommandOptionOrControl)
        )
        XCTAssertEqual(
            store.validationResult(
                for: .init(key: .character("g"), modifiers: [.option]),
                assignedTo: .askAssistant
            ),
            .valid
        )

        let timelineSingleKey = KeyboardShortcutBinding(key: .character("g"))
        XCTAssertEqual(
            store.validationResult(
                for: timelineSingleKey,
                assignedTo: .timelineFilter
            ),
            .valid
        )
        try store.setBinding(timelineSingleKey, for: .timelineFilter)
        XCTAssertEqual(store.binding(for: .timelineFilter), timelineSingleKey)
    }

    func testCommonMacOSEditingWindowAndSystemShortcutsAreReserved() {
        let store = KeyboardShortcutStore(defaults: defaults)

        let cases: [(KeyboardShortcutBinding, KeyboardShortcutReservedCategory)] = [
            (.init(key: .character("c"), modifiers: [.command]), .editing),
            (.init(key: .character("w"), modifiers: [.command]), .windowManagement),
            (.init(key: .space, modifiers: [.command]), .system),
            (.init(key: .special(.tab), modifiers: [.command]), .system),
            (.init(key: .character("4"), modifiers: [.shift, .command]), .system),
            (.init(key: .leftArrow, modifiers: [.control]), .system),
        ]

        for (binding, category) in cases {
            XCTAssertEqual(
                store.validationResult(for: binding, assignedTo: .timelineFilter),
                .invalid(.reservedMacOSShortcut(category)),
                binding.accessibilityLabel
            )
        }
    }

    func testARegisteredDefaultRemainsValidWhenItHasStandardMacOSMeaning() throws {
        let store = KeyboardShortcutStore(defaults: defaults)
        let find = try XCTUnwrap(
            KeyboardShortcutRegistry.standard.definition(for: .findLibrary)
        )
        let quit = try XCTUnwrap(
            KeyboardShortcutRegistry.standard.definition(for: .quit)
        )

        XCTAssertEqual(KeyboardShortcutValidation.validate(find.defaultBinding, for: find), .valid)
        XCTAssertEqual(KeyboardShortcutValidation.validate(quit.defaultBinding, for: quit), .valid)
        XCTAssertEqual(
            store.validationResult(for: find.defaultBinding, assignedTo: .timelineFilter),
            .invalid(.reservedMacOSShortcut(.system))
        )
    }

    func testUnsupportedCharacterIsRejected() {
        let store = KeyboardShortcutStore(defaults: defaults)
        let whitespace = KeyboardShortcutBinding(
            key: .character(" "),
            modifiers: [.command]
        )

        XCTAssertEqual(
            store.validationResult(for: whitespace, assignedTo: .showLibrary),
            .invalid(.unsupportedKey)
        )
    }

    func testInvalidChangeIsRejectedWithoutMutationOrPersistence() throws {
        let store = KeyboardShortcutStore(defaults: defaults)
        let original = store.binding(for: .showLibrary)
        let unsafe = KeyboardShortcutBinding(key: .character("g"))

        XCTAssertThrowsError(try store.setBinding(unsafe, for: .showLibrary)) { error in
            XCTAssertEqual(
                error as? KeyboardShortcutStoreError,
                .invalidBinding(.showLibrary, .requiresCommandOptionOrControl)
            )
        }
        XCTAssertEqual(store.binding(for: .showLibrary), original)
        XCTAssertNil(defaults.data(forKey: KeyboardShortcutStore.defaultsKey))
    }

    func testBindingLabelsAndCodableRepresentationAreStable() throws {
        let binding = KeyboardShortcutBinding(
            key: .returnKey,
            modifiers: [.shift, .command, .option]
        )

        XCTAssertEqual(binding.displayLabel, "Option-Shift-Command-Return")
        XCTAssertEqual(binding.accessibilityLabel, "Option-Shift-Command-Return")
        XCTAssertEqual(
            KeyboardShortcutKey.character("K"),
            KeyboardShortcutKey.character("k")
        )

        let encoded = try JSONEncoder().encode(binding)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcutBinding.self, from: encoded), binding)
    }

    func testCustomAndDisabledBindingsRoundTrip() throws {
        var store: KeyboardShortcutStore? = KeyboardShortcutStore(defaults: defaults)
        let custom = KeyboardShortcutBinding(key: .character("l"), modifiers: [.option, .command])

        try store?.setBinding(custom, for: .showLibrary)
        try store?.setBinding(nil, for: .timelineToggleReplay)
        store = nil

        let restored = KeyboardShortcutStore(defaults: defaults)
        XCTAssertEqual(restored.binding(for: .showLibrary), custom)
        XCTAssertNil(restored.binding(for: .timelineToggleReplay))
        XCTAssertEqual(restored.persistenceStatus, .loaded(version: 1))
    }

    func testConflictingChangeIsRejectedWithoutMutation() {
        let store = KeyboardShortcutStore(defaults: defaults)
        let showTimeline = try! XCTUnwrap(store.binding(for: .showTimeline))

        XCTAssertThrowsError(try store.setBinding(showTimeline, for: .showLibrary)) { error in
            guard case .conflicts(let conflicts) = error as? KeyboardShortcutStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(conflicts.count, 1)
            XCTAssertEqual(conflicts.first?.binding, showTimeline)
        }
        XCTAssertEqual(
            store.binding(for: .showLibrary),
            KeyboardShortcutRegistry.standard.definition(for: .showLibrary)?.defaultBinding
        )
        XCTAssertNil(defaults.data(forKey: KeyboardShortcutStore.defaultsKey))
    }

    func testFeatureScopesMayReuseBindings() throws {
        let store = KeyboardShortcutStore(defaults: defaults)
        let sharedBinding = KeyboardShortcutBinding(
            key: .character("l"),
            modifiers: [.option]
        )
        try store.setBinding(sharedBinding, for: .timelineFilter)

        XCTAssertTrue(store.conflicts(for: sharedBinding, assignedTo: .askAssistant).isEmpty)
        try store.setBinding(sharedBinding, for: .askAssistant)
        XCTAssertEqual(store.binding(for: .askAssistant), sharedBinding)
    }

    func testResetOneAndResetAllRestoreRegistryDefaults() throws {
        let store = KeyboardShortcutStore(defaults: defaults)
        try store.setBinding(nil, for: .askAssistant)
        try store.setBinding(
            .init(key: .character("l"), modifiers: [.option, .command]),
            for: .showLibrary
        )

        try store.resetToDefault(for: .askAssistant)
        XCTAssertEqual(
            store.binding(for: .askAssistant),
            KeyboardShortcutRegistry.standard.definition(for: .askAssistant)?.defaultBinding
        )
        store.resetToDefaults()

        XCTAssertEqual(store.persistenceStatus, .defaults)
        XCTAssertNil(defaults.object(forKey: KeyboardShortcutStore.defaultsKey))
        XCTAssertEqual(
            store.binding(for: .showLibrary),
            KeyboardShortcutRegistry.standard.definition(for: .showLibrary)?.defaultBinding
        )
    }

    func testLegacyVersionMigratesAndRewritesCurrentSchema() throws {
        let legacyBinding = KeyboardShortcutBinding(key: .character("a"), modifiers: [.option])
        let encoder = JSONEncoder()
        let bindingObject = try JSONSerialization.jsonObject(with: encoder.encode(legacyBinding))
        let legacy: [String: Any] = [
            "schemaVersion": 0,
            "bindings": [KeyboardShortcutActionID.askAssistant.rawValue: bindingObject],
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: KeyboardShortcutStore.defaultsKey
        )

        let store = KeyboardShortcutStore(defaults: defaults)

        XCTAssertEqual(store.binding(for: .askAssistant), legacyBinding)
        XCTAssertEqual(store.persistenceStatus, .migrated(fromVersion: 0, toVersion: 1))
        let upgraded = try XCTUnwrap(defaults.data(forKey: KeyboardShortcutStore.defaultsKey))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: upgraded) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["entries"])
    }

    func testFutureVersionFailsClosedWithoutOverwritingData() throws {
        let future = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 99, "entries": []]
        )
        defaults.set(future, forKey: KeyboardShortcutStore.defaultsKey)

        let store = KeyboardShortcutStore(defaults: defaults)

        XCTAssertEqual(store.persistenceStatus, .unsupportedVersion(99))
        XCTAssertEqual(defaults.data(forKey: KeyboardShortcutStore.defaultsKey), future)
        XCTAssertEqual(
            store.binding(for: .askAssistant),
            KeyboardShortcutRegistry.standard.definition(for: .askAssistant)?.defaultBinding
        )
    }

    func testUnknownActionSurvivesAWriteFromAnOlderBuild() throws {
        let currentBinding = KeyboardShortcutBinding(key: .character("x"), modifiers: [.command])
        let encodedBinding = try JSONSerialization.jsonObject(with: JSONEncoder().encode(currentBinding))
        let document: [String: Any] = [
            "schemaVersion": 1,
            "entries": [
                ["actionID": "future.action", "binding": encodedBinding]
            ],
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: document),
            forKey: KeyboardShortcutStore.defaultsKey
        )

        let store = KeyboardShortcutStore(defaults: defaults)
        try store.setBinding(nil, for: .askAssistant)

        let data = try XCTUnwrap(defaults.data(forKey: KeyboardShortcutStore.defaultsKey))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertTrue(entries.contains { $0["actionID"] as? String == "future.action" })
    }

    func testMalformedDocumentsFailClosedToDefaults() {
        defaults.set(Data("not-json".utf8), forKey: KeyboardShortcutStore.defaultsKey)

        let store = KeyboardShortcutStore(defaults: defaults)

        XCTAssertEqual(store.persistenceStatus, .corrupt)
        XCTAssertEqual(
            store.binding(for: .askAssistant),
            KeyboardShortcutRegistry.standard.definition(for: .askAssistant)?.defaultBinding
        )
    }

    func testPersistedInvalidBindingsAreDiscardedAndRewritten() throws {
        let bareApplicationKey = KeyboardShortcutBinding(key: .character("g"))
        let reservedEditingKey = KeyboardShortcutBinding(
            key: .character("c"),
            modifiers: [.command]
        )
        try persistCurrentDocument([
            (KeyboardShortcutActionID.showLibrary.rawValue, bareApplicationKey),
            (KeyboardShortcutActionID.askAssistant.rawValue, reservedEditingKey),
            (KeyboardShortcutActionID.timelineToggleReplay.rawValue, nil),
        ])

        var store: KeyboardShortcutStore? = KeyboardShortcutStore(defaults: defaults)

        XCTAssertEqual(
            store?.persistenceStatus,
            .repaired(
                version: 1,
                discardedActions: [.askAssistant, .showLibrary]
            )
        )
        XCTAssertEqual(
            store?.persistenceRepairs,
            [
                .init(
                    actionID: .askAssistant,
                    issue: .reservedMacOSShortcut(.editing)
                ),
                .init(
                    actionID: .showLibrary,
                    issue: .requiresCommandOptionOrControl
                ),
            ]
        )
        XCTAssertEqual(
            store?.binding(for: .showLibrary),
            KeyboardShortcutRegistry.standard.definition(for: .showLibrary)?.defaultBinding
        )
        XCTAssertEqual(
            store?.binding(for: .askAssistant),
            KeyboardShortcutRegistry.standard.definition(for: .askAssistant)?.defaultBinding
        )
        XCTAssertNil(store?.binding(for: .timelineToggleReplay))

        store = nil
        let restored = KeyboardShortcutStore(defaults: defaults)
        XCTAssertEqual(restored.persistenceStatus, .loaded(version: 1))
        XCTAssertTrue(restored.persistenceRepairs.isEmpty)
        XCTAssertNil(restored.binding(for: .timelineToggleReplay))
    }

    func testPersistedTimelineSingleKeyRemainsValid() throws {
        let custom = KeyboardShortcutBinding(key: .character("g"))
        try persistCurrentDocument([
            (KeyboardShortcutActionID.timelineFilter.rawValue, custom)
        ])

        let store = KeyboardShortcutStore(defaults: defaults)

        XCTAssertEqual(store.persistenceStatus, .loaded(version: 1))
        XCTAssertTrue(store.persistenceRepairs.isEmpty)
        XCTAssertEqual(store.binding(for: .timelineFilter), custom)
    }

    func testCustomBindingWinsOverReassignedTimelineDefault() throws {
        let commandThree = KeyboardShortcutBinding(key: .character("3"), modifiers: .command)
        try persistCurrentDocument([
            (KeyboardShortcutActionID.showLibrary.rawValue, commandThree)
        ])

        let store = KeyboardShortcutStore(defaults: defaults)

        XCTAssertEqual(store.persistenceStatus, .loaded(version: 1))
        XCTAssertTrue(store.allConflicts().isEmpty)
        XCTAssertEqual(store.binding(for: .showLibrary), commandThree)
        XCTAssertNil(store.binding(for: .showTimeline))
    }

    func testConflictingExplicitOverridesStillFailClosed() throws {
        let custom = KeyboardShortcutBinding(key: .character("g"), modifiers: .command)
        try persistCurrentDocument([
            (KeyboardShortcutActionID.showLibrary.rawValue, custom),
            (KeyboardShortcutActionID.showTimeline.rawValue, custom),
        ])
        let store = KeyboardShortcutStore(defaults: defaults)
        XCTAssertEqual(store.persistenceStatus, .corrupt)
        XCTAssertTrue(store.allConflicts().isEmpty)
    }

    func testRegistryRejectsStructurallyInvalidDefault() {
        let definition = KeyboardShortcutDefinition(
            id: .showLibrary,
            title: "Show Library",
            category: .navigation,
            scope: .application,
            defaultBinding: .init(key: .character("\n"), modifiers: [.command])
        )

        XCTAssertThrowsError(try KeyboardShortcutRegistry(definitions: [definition])) { error in
            XCTAssertEqual(
                error as? KeyboardShortcutRegistryError,
                .invalidDefault(.showLibrary, .unsupportedKey)
            )
        }
    }

    private func persistCurrentDocument(
        _ entries: [(actionID: String, binding: KeyboardShortcutBinding?)]
    ) throws {
        let encoder = JSONEncoder()
        let encodedEntries: [[String: Any]] = try entries.map { entry in
            let binding: Any
            if let value = entry.binding {
                binding = try JSONSerialization.jsonObject(with: encoder.encode(value))
            } else {
                binding = NSNull()
            }
            return ["actionID": entry.actionID, "binding": binding]
        }
        defaults.set(
            try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": KeyboardShortcutStore.currentSchemaVersion,
                    "entries": encodedEntries,
                ]
            ),
            forKey: KeyboardShortcutStore.defaultsKey
        )
    }
}
