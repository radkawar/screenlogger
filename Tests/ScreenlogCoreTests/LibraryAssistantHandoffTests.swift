import XCTest

@testable import ScreenlogCore

final class LibraryAssistantHandoffTests: XCTestCase {
    func testPromptContainsOnlyAuthoredRequestAndExplicitConstraints() throws {
        let hiddenOCR = "private OCR content"
        let hiddenSnippet = "private result snippet"
        let hiddenURL = "https://hidden.example/private"

        let prompt = try LibraryAssistantHandoffPromptBuilder.build(
            LibraryAssistantHandoffRequest(
                authoredText: "Find the design review I was reading",
                constraints: LibraryAssistantHandoffConstraints(
                    application: "Safari",
                    website: "design.example",
                    date: "July 31, 2026",
                    time: "Morning",
                    session: "Safari session"
                )
            )
        )

        XCTAssertEqual(
            prompt.text,
            """
            Search my Screenlogger Library.
            Request: Find the design review I was reading
            Application: Safari
            Website: design.example
            Date: July 31, 2026
            Time: Morning
            Session: Safari session
            Use screenlog.
            """
        )
        XCTAssertFalse(prompt.text.contains(hiddenOCR))
        XCTAssertFalse(prompt.text.contains(hiddenSnippet))
        XCTAssertFalse(prompt.text.contains(hiddenURL))
        XCTAssertFalse(prompt.wasTruncated)
    }

    func testPromptAllowsExplicitConstraintsWithoutAuthoredText() throws {
        let prompt = try LibraryAssistantHandoffPromptBuilder.build(
            LibraryAssistantHandoffRequest(
                authoredText: "  ",
                constraints: .init(application: "TextEdit", date: "Today")
            )
        )

        XCTAssertEqual(
            prompt.text,
            """
            Search my Screenlogger Library.
            Application: TextEdit
            Date: Today
            Use screenlog.
            """
        )
    }

    func testPromptRejectsAnEmptyRequest() {
        XCTAssertThrowsError(
            try LibraryAssistantHandoffPromptBuilder.build(
                LibraryAssistantHandoffRequest(
                    authoredText: " \n\t ",
                    constraints: .init(website: "")
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryAssistantHandoffPromptError,
                .missingRequest
            )
        }
    }

    func testPromptNormalizesControlCharactersAndAlwaysEndsWithInstruction() throws {
        let prompt = try LibraryAssistantHandoffPromptBuilder.build(
            LibraryAssistantHandoffRequest(
                authoredText: "Find\n\tthe\u{0000}design review",
                constraints: .init(session: "Planning\nsession")
            )
        )

        XCTAssertTrue(prompt.text.contains("Request: Find the design review"))
        XCTAssertTrue(prompt.text.contains("Session: Planning session"))
        XCTAssertEqual(prompt.text.split(separator: "\n").last, "Use screenlog.")
    }

    func testPromptCapsUnicodeSafelyWithinFourKilobytes() throws {
        let prompt = try LibraryAssistantHandoffPromptBuilder.build(
            LibraryAssistantHandoffRequest(
                authoredText: String(repeating: "research-\u{1F4DA}-", count: 1_000),
                constraints: .init(
                    application: String(repeating: "Application ", count: 200),
                    website: String(repeating: "website.example ", count: 200),
                    date: String(repeating: "Today ", count: 200),
                    time: String(repeating: "Morning ", count: 200),
                    session: String(repeating: "Design session ", count: 200)
                )
            )
        )

        XCTAssertLessThanOrEqual(
            prompt.utf8ByteCount,
            LibraryAssistantHandoffPromptBuilder.maximumUTF8Bytes
        )
        XCTAssertTrue(prompt.wasTruncated)
        XCTAssertEqual(prompt.text.split(separator: "\n").last, "Use screenlog.")
        for label in ["Application:", "Website:", "Date:", "Time:", "Session:"] {
            XCTAssertTrue(prompt.text.contains(label))
        }
    }

    func testAutomaticRoutingHandlesZeroOneAndMultipleTargets() {
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [],
                preference: .automatic
            ),
            .unavailable
        )
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [.codex],
                preference: .automatic
            ),
            .route(.codex)
        )
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [.openclaw, .claude, .openclaw],
                preference: .automatic
            ),
            .choose([.claude, .openclaw])
        )
    }

    func testAskEveryTimeAlwaysChoosesWhenAnyTargetIsCapable() {
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [.codex],
                preference: .askEveryTime
            ),
            .choose([.codex])
        )
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [],
                preference: .askEveryTime
            ),
            .unavailable
        )
    }

    func testPreferredTargetNeverFallsBackSilently() {
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [.codex, .claude],
                preference: .preferred(.codex)
            ),
            .route(.codex)
        )
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [.openclaw, .claude],
                preference: .preferred(.codex)
            ),
            .preferredUnavailable(
                preferred: .codex,
                capableTargets: [.claude, .openclaw]
            )
        )
        XCTAssertEqual(
            LibraryAssistantRoutingPolicy.decide(
                capableTargets: [],
                preference: .preferred(.codex)
            ),
            .preferredUnavailable(
                preferred: .codex,
                capableTargets: []
            )
        )
    }

    func testRoutingPreferencePersistsWithoutGuessingUnknownValues() {
        for preference in [
            LibraryAssistantRoutingPreference.automatic,
            .askEveryTime,
            .preferred(.claude),
            .preferred(.grok),
        ] {
            XCTAssertEqual(
                LibraryAssistantRoutingPreference(
                    persistedValue: preference.persistedValue
                ),
                preference
            )
        }

        XCTAssertEqual(
            LibraryAssistantRoutingPreference(persistedValue: "preferred:unknown"),
            .automatic
        )
        XCTAssertEqual(
            LibraryAssistantRoutingPreference(persistedValue: "future-mode"),
            .automatic
        )
    }
}
