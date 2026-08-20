import XCTest

final class LibraryAssistantAskPresentationTests: XCTestCase {
    func testAskIsNotAPrimaryControlBeforeAQueryExists() {
        XCTAssertEqual(
            LibraryAssistantAskPolicy.resolve(hasQuery: false, connectionCount: 0),
            .hidden
        )
        XCTAssertEqual(
            LibraryAssistantAskPolicy.resolve(hasQuery: false, connectionCount: 2),
            .hidden
        )
        XCTAssertFalse(LibraryAssistantAskPolicy.isPrimaryControlVisible(hasQuery: false))
    }

    func testAskWithAQueryAndNoConnectionsOpensIntegrations() {
        XCTAssertEqual(
            LibraryAssistantAskPolicy.resolve(hasQuery: true, connectionCount: 0),
            .openIntegrations
        )
        XCTAssertTrue(LibraryAssistantAskPolicy.isPrimaryControlVisible(hasQuery: true))
    }

    func testAskWithAQueryAndConnectionsOpensTheHandoffSheet() {
        XCTAssertEqual(
            LibraryAssistantAskPolicy.resolve(hasQuery: true, connectionCount: 1),
            .openHandoff
        )
        XCTAssertEqual(
            LibraryAssistantAskPolicy.resolve(hasQuery: true, connectionCount: 3),
            .openHandoff
        )
    }
}
