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
}
