import XCTest

final class SettingsDestinationTests: XCTestCase {
    func testCustomSettingsControlsExposeConsistentSpokenState() {
        XCTAssertEqual(SettingsAccessibilityValue.onOff(true), "On")
        XCTAssertEqual(SettingsAccessibilityValue.onOff(false), "Off")
    }

    func testShortcutSearchTermsReturnDedicatedShortcutsPane() {
        for query in [
            "Keyboard Shortcuts", "hotkey", "key binding", "rebind", "reset shortcut",
        ] {
            XCTAssertEqual(
                SettingsSearchResult.matching(query).map(\.destination),
                [.shortcuts],
                query
            )
        }
    }

    func testShortcutsAreAFirstClassAppSettingsDestination() {
        XCTAssertEqual(SettingsDestination.shortcuts.section, .shortcuts)
        XCTAssertEqual(
            SettingsSidebarSection.all.first(where: { $0.id == "app" })?.items,
            [.general, .appearance, .shortcuts]
        )
    }

    func testMeaningSearchHasADedicatedSearchDestination() {
        XCTAssertEqual(SettingsDestination.search.section, .search)
        XCTAssertEqual(SettingsDestination.searchSemanticSearch.section, .search)
        XCTAssertEqual(
            SettingsSidebarSection.all.first(where: { $0.id == "capture-and-data" })?.items,
            [.capture, .privacy, .exclusions, .search, .storage]
        )
        XCTAssertEqual(SettingsSearchResult.matching("Search").map(\.destination), [.search])
        for query in ["Meaning Search", "semantic", "related", "model download", "sources", "indexing"] {
            XCTAssertEqual(
                SettingsSearchResult.matching(query).map(\.destination),
                [.searchSemanticSearch],
                query
            )
        }
        XCTAssertEqual(
            SettingsDestination.searchSemanticSearch.anchor?.accessibilityIdentifier,
            "settings.destination.search-semantic-search"
        )
        XCTAssertEqual(
            SettingsDestination.searchSemanticSearch.anchor?.searchResultAccessibilityIdentifier,
            "settings.search-result.search-semantic-search"
        )
    }

    func testMeaningSearchDeepLinkPreservesFocusedControlAndRepeatNavigation() {
        let first = SettingsNavigationRequest(
            destination: .searchSemanticSearch,
            focusedElementIdentifier: "settings.semantic.mode"
        )
        let second = SettingsNavigationRequest(destination: .searchSemanticSearch)
        XCTAssertEqual(first.destination.section, .search)
        XCTAssertEqual(first.focusedElementIdentifier, "settings.semantic.mode")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(SettingsDestination.storageManagement.section, .storage)
        XCTAssertEqual(SettingsDestination.storageLibraryTools.section, .storage)
    }

    func testAssistantSearchTermsReturnAnExplicitAssistantConnectionsResult() {
        for query in [
            "assistant", "Assistant Connections", "Claude", "Cursor", "Codex", "Grok", "Grok Build", "OpenClaw", "AI agent", "skill",
        ] {
            XCTAssertEqual(
                SettingsSearchResult.matching(query).map(\.destination),
                [.integrationsAssistantConnections],
                query
            )
        }
    }

    func testCommandSearchTermsReturnAnExplicitCommandSetupResult() {
        for query in ["Command Setup", "Terminal", "CLI", "screenlog command", "shell PATH"] {
            XCTAssertEqual(
                SettingsSearchResult.matching(query).map(\.destination),
                [.integrationsLocalTools],
                query
            )
        }
    }

    func testBroadAndMixedQueriesReturnASectionInsteadOfGuessingAtAChildGroup() {
        XCTAssertTrue(SettingsSearchResult.matching("").isEmpty)
        XCTAssertEqual(
            SettingsSearchResult.matching("integration").map(\.destination),
            [.integrations]
        )
        XCTAssertEqual(
            SettingsSearchResult.matching("assistant command").map(\.destination),
            [.integrations]
        )
        XCTAssertEqual(
            SettingsSearchResult.matching("privacy").map(\.destination),
            [.privacy]
        )
    }

    func testSpecificSearchResultSuppressesItsBroaderSectionDuplicate() {
        XCTAssertEqual(
            SettingsSearchResult.matching("diagnostics").map(\.destination),
            [.supportDiagnostics]
        )
        XCTAssertEqual(
            SettingsSearchResult.matching("retention").map(\.destination),
            [.storageManagement]
        )
        XCTAssertEqual(
            SettingsSearchResult.matching("multiple monitors").map(\.destination),
            [.captureDisplays]
        )
        for query in ["audio transcription", "microphone", "computer audio", "meeting caption"] {
            XCTAssertEqual(
                SettingsSearchResult.matching(query).map(\.destination),
                [.captureAudio],
                query
            )
        }
    }

    func testAudioTranscriptionHasAStableCaptureDestination() {
        XCTAssertEqual(SettingsDestination.captureAudio.section, .capture)
        XCTAssertEqual(
            SettingsDestination.captureAudio.anchor?.accessibilityLabel,
            "Audio transcription"
        )
        XCTAssertEqual(
            SettingsDestination.captureAudio.anchor?.accessibilityIdentifier,
            "settings.destination.capture-audio"
        )
        XCTAssertEqual(
            SettingsDestination.captureAudio.anchor?.searchResultAccessibilityIdentifier,
            "settings.search-result.capture-audio"
        )
    }

    func testSearchResultsExposeStableActivationIdentifiers() throws {
        let result = try XCTUnwrap(SettingsSearchResult.matching("Claude").first)

        XCTAssertEqual(
            result.accessibilityIdentifier,
            "settings.search-result.integrations-assistant-connections"
        )
    }

    func testIntegrationAnchorsExposeStableProductLanguageAndIdentifiers() {
        XCTAssertEqual(SettingsDestination.integrationsLocalTools.section, .integrations)
        XCTAssertEqual(SettingsDestination.integrationsAssistantConnections.section, .integrations)
        XCTAssertEqual(
            SettingsDestination.integrationsLocalTools.anchor?.accessibilityIdentifier,
            "settings.destination.integrations-local-tools"
        )
        XCTAssertEqual(
            SettingsDestination.integrationsAssistantConnections.anchor?.accessibilityIdentifier,
            "settings.destination.integrations-assistant-connections"
        )
        XCTAssertEqual(
            SettingsDestination.integrationsLocalTools.anchor?.searchResultAccessibilityIdentifier,
            "settings.search-result.integrations-local-tools"
        )
        XCTAssertEqual(
            SettingsDestination.integrationsAssistantConnections.anchor?.searchResultAccessibilityIdentifier,
            "settings.search-result.integrations-assistant-connections"
        )
    }

    func testRepeatedRequestsForSameAnchorRemainDistinctEvents() {
        let first = SettingsNavigationRequest(destination: .integrationsAssistantConnections)
        let second = SettingsNavigationRequest(destination: .integrationsAssistantConnections)

        XCTAssertEqual(first.destination, second.destination)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first, second)
    }

    func testAssistantRecoveryCanFocusOneConnectionWithoutChangingItsSection() {
        let request = SettingsNavigationRequest(
            destination: .integrationsAssistantConnections,
            focusedElementIdentifier: "settings.integration.codex"
        )

        XCTAssertEqual(request.destination.section, .integrations)
        XCTAssertEqual(
            request.focusedElementIdentifier,
            "settings.integration.codex"
        )
    }

    func testRepeatedFocusRequestsForWebsiteExclusionsRemainDistinctEvents() {
        let first = SettingsDestinationFocusRequest(
            id: UUID(),
            anchor: .exclusionsWebsites
        )
        let second = SettingsDestinationFocusRequest(
            id: UUID(),
            anchor: .exclusionsWebsites
        )

        XCTAssertEqual(first.anchor, second.anchor)
        XCTAssertNotEqual(first, second)
    }
}
