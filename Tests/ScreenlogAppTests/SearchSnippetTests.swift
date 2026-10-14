import XCTest

final class SearchSnippetTests: XCTestCase {
    func testParserPreservesCapturedBracketsAndHighlightsMarkedText() throws {
        let parsed = try XCTUnwrap(SearchSnippet.parse("array [\u{1F}needle\u{1E}] value"))

        XCTAssertEqual(parsed.text, "array [needle] value")
        XCTAssertEqual(parsed.matches.map { String(parsed.text[$0]) }, ["needle"])
    }

    func testParserCollapsesWhitespaceWithoutInvalidatingUnicodeRanges() throws {
        let parsed = try XCTUnwrap(
            SearchSnippet.parse("  before\n\u{1F}caf\u{E9}\u{1E}\t after  ")
        )

        XCTAssertEqual(parsed.text, "before caf\u{E9} after")
        XCTAssertEqual(parsed.matches.map { String(parsed.text[$0]) }, ["caf\u{E9}"])
    }

    func testParserRejectsEmptyContent() {
        XCTAssertNil(SearchSnippet.parse(nil))
        XCTAssertNil(SearchSnippet.parse(" \n\t "))
    }

    func testMissingTitleUsesAppWithoutRepeatingItsContextOrPromotingOCR() {
        let display = LibraryResultTextPresentation(
            title: " \n", appLabel: "Editor", domain: nil,
            snippet: "Unrelated toolbar text", allowsUnmarkedExcerpt: false
        )

        XCTAssertEqual(display.title, "Editor")
        XCTAssertNil(display.appContext)
        XCTAssertNil(display.excerpt)
        XCTAssertEqual(display.cleanedSnippet, "Unrelated toolbar text")
    }

    func testRecordedTitleRetainsDistinctAppAndWebsiteContext() {
        let display = LibraryResultTextPresentation(
            title: "  Project\nnotes  ", appLabel: "Browser", domain: "example.com",
            snippet: nil, allowsUnmarkedExcerpt: false
        )

        XCTAssertEqual(display.title, "Project notes")
        XCTAssertEqual(display.appContext, "Browser")
        XCTAssertEqual(display.domainContext, "example.com")
    }

    func testIdentityOnlyMatchIsNotRepeatedAsExcerpt() {
        for snippet in ["\u{1F}Project\u{1E} notes", "\u{1F}Project\u{1E}\u{2026}"] {
            let display = LibraryResultTextPresentation(
                title: "Project notes", appLabel: "Editor", domain: nil,
                snippet: snippet, allowsUnmarkedExcerpt: false
            )
            XCTAssertNil(display.excerpt)
            XCTAssertTrue(display.matches.isEmpty)
        }
    }

    func testInformativeMatchRetainsUnicodeHighlightRanges() throws {
        let display = LibraryResultTextPresentation(
            title: "Project notes", appLabel: "Editor", domain: nil,
            snippet: "Discuss \u{1F}caf\u{E9}\u{1E}\nlaunch", allowsUnmarkedExcerpt: false
        )
        let excerpt = try XCTUnwrap(display.excerpt)

        XCTAssertEqual(excerpt, "Discuss caf\u{E9} launch")
        XCTAssertEqual(display.matches.map { String(excerpt[$0]) }, ["caf\u{E9}"])
    }

    func testUnmarkedTextRequiresTranscriptOrSemanticContext() {
        for allowed in [false, true] {
            let display = LibraryResultTextPresentation(
                title: "Project notes", appLabel: "Editor", domain: nil,
                snippet: "Discuss launch plans", allowsUnmarkedExcerpt: allowed
            )
            XCTAssertEqual(display.excerpt != nil, allowed)
        }
    }

    func testIdentityComparisonIgnoresCaseAndWhitespace() {
        let display = LibraryResultTextPresentation(
            title: "  EDITOR ", appLabel: "Editor", domain: "editor",
            snippet: "\u{1F}editor\u{1E}", allowsUnmarkedExcerpt: false
        )

        XCTAssertNil(display.appContext)
        XCTAssertNil(display.domainContext)
        XCTAssertNil(display.excerpt)
    }
}
