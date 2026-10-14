import XCTest

@testable import ScreenlogCore

final class PrivateBrowsingDetectorTests: XCTestCase {
    func testDetectsSafariPrivateTitle() {
        XCTAssertTrue(
            PrivateBrowsingDetector.looksPrivate(
                title: "Private Browsing - Safari",
                url: "https://example.com",
                bundleID: "com.apple.Safari"
            )
        )
    }

    func testDetectsChromeIncognitoTitle() {
        XCTAssertTrue(
            PrivateBrowsingDetector.looksPrivate(
                title: "New Tab - Incognito",
                url: nil,
                bundleID: "com.google.Chrome"
            )
        )
    }

    func testDetectsEdgeInPrivate() {
        XCTAssertTrue(
            PrivateBrowsingDetector.looksPrivate(
                title: "InPrivate - Microsoft Edge",
                url: "https://example.com",
                bundleID: "com.microsoft.edgemac"
            )
        )
    }

    func testNormalBrowsingNotPrivate() {
        XCTAssertFalse(
            PrivateBrowsingDetector.looksPrivate(
                title: "Example Domain",
                url: "https://example.com",
                bundleID: "com.apple.Safari"
            )
        )
        XCTAssertFalse(
            PrivateBrowsingDetector.looksPrivate(
                title: "Ghostty",
                url: nil,
                bundleID: "com.mitchellh.ghostty"
            )
        )
    }

    func testURLSchemeHints() {
        XCTAssertTrue(
            PrivateBrowsingDetector.looksPrivate(
                title: nil,
                url: "safari-private://example.com",
                bundleID: "com.apple.Safari"
            )
        )
    }
}
