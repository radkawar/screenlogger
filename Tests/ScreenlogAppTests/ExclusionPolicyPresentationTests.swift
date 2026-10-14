import ScreenlogCore
import XCTest

final class ExclusionPolicyPresentationTests: XCTestCase {
    func testExplicitApplicationProducesNeverCaptureWithExactProvenance() {
        let presentation = ExclusionPolicyPresentation.application(
            displayName: "Notes",
            bundleID: "com.apple.Notes",
            explicitlyExcluded: true
        )

        XCTAssertEqual(presentation.outcome, .neverCapture)
        XCTAssertEqual(presentation.provenance, [.explicitApplication])
    }

    func testExplicitBrowserExplainsThatEveryWindowIsCovered() {
        let presentation = ExclusionPolicyPresentation.application(
            displayName: "Safari",
            bundleID: "com.apple.Safari",
            explicitlyExcluded: true
        )

        XCTAssertEqual(presentation.outcome, .neverCapture)
        XCTAssertEqual(
            presentation.provenance,
            [.explicitApplication, .entireBrowser]
        )
        XCTAssertTrue(presentation.detail.contains("skips every window"))
    }

    func testBroaderApplicationCategoryOwnsEffectiveOutcome() {
        let presentation = ExclusionPolicyPresentation.application(
            displayName: "1Password",
            bundleID: "com.1password.1password",
            explicitlyExcluded: false,
            categoryNames: ["Password Managers"]
        )

        XCTAssertEqual(presentation.outcome, .neverCapture)
        XCTAssertEqual(presentation.provenance, [.broaderCategory("Password Managers")])
    }

    func testWebsiteRetainsExplicitAndCategoryProvenanceTogether() {
        let presentation = ExclusionPolicyPresentation.website(
            domain: "secure.example",
            explicitlyExcluded: true,
            categoryNames: ["Banks"]
        )

        XCTAssertEqual(presentation.outcome, .neverCapture)
        XCTAssertEqual(
            presentation.provenance,
            [.explicitDomain, .broaderCategory("Banks")]
        )
        XCTAssertTrue(presentation.detail.contains("when its browser address is available"))
    }

    func testWebsiteWithoutMatchingPolicyCanCaptureWhenAddressIsAvailable() {
        let presentation = ExclusionPolicyPresentation.website(
            domain: "example.com",
            explicitlyExcluded: false
        )

        XCTAssertEqual(presentation.outcome, .canCapture)
        XCTAssertTrue(presentation.provenance.isEmpty)
        XCTAssertTrue(presentation.detail.contains("when its browser address is available"))
    }

    func testCategoryAndUnknownAddressOutcomesDescribeTheirOwningPolicy() {
        let enabledCategory = ExclusionPolicyPresentation.broaderCategory(
            name: "Banks",
            isEnabled: true,
            matchingContent: "banking websites"
        )
        let disabledCategory = ExclusionPolicyPresentation.broaderCategory(
            name: "Banks",
            isEnabled: false,
            matchingContent: "banking websites"
        )
        let strict = ExclusionPolicyPresentation.unknownBrowserAddress(
            strictProtectionEnabled: true
        )
        let permissive = ExclusionPolicyPresentation.unknownBrowserAddress(
            strictProtectionEnabled: false
        )

        XCTAssertEqual(enabledCategory.outcome, .neverCapture)
        XCTAssertEqual(enabledCategory.provenance, [.broaderCategory("Banks")])
        XCTAssertEqual(disabledCategory.outcome, .canCapture)
        XCTAssertEqual(strict.outcome, .neverCapture)
        XCTAssertEqual(strict.provenance, [.unknownAddressStrictProtection])
        XCTAssertEqual(permissive.outcome, .canCapture)
        XCTAssertTrue(permissive.detail.contains("Exclude the entire browser"))
    }

    func testEveryAccessibilityHintExplainsFutureOnlyNonDeletionBehavior() {
        let presentations = [
            ExclusionPolicyPresentation.application(
                displayName: "Notes",
                bundleID: "com.apple.Notes",
                explicitlyExcluded: false
            ),
            ExclusionPolicyPresentation.website(
                domain: "example.com",
                explicitlyExcluded: true
            ),
            ExclusionPolicyPresentation.broaderCategory(
                name: "Banks",
                isEnabled: true,
                matchingContent: "banking websites"
            ),
            ExclusionPolicyPresentation.unknownBrowserAddress(
                strictProtectionEnabled: true
            ),
        ]

        for presentation in presentations {
            XCTAssertTrue(presentation.accessibilityHint.hasPrefix(presentation.outcome.title))
            XCTAssertTrue(
                presentation.accessibilityHint.hasSuffix(
                    ExclusionPolicyPresentation.futureMomentsNotice
                )
            )
            XCTAssertTrue(presentation.accessibilityHint.contains("does not delete existing Library moments"))
        }
    }
}

final class WebsiteExclusionMenuPresentationTests: XCTestCase {
    func testNonBrowserKeepsWebsiteActionOutOfTheMenu() {
        XCTAssertEqual(
            WebsiteExclusionMenuPresentation.resolve(
                frontmostBundleID: "com.apple.Notes",
                attribution: nil,
                isExcluded: { _ in false }
            ),
            .hidden
        )
    }

    func testBrowserWithoutReadableAddressExplainsWhyActionIsUnavailable() {
        XCTAssertEqual(
            WebsiteExclusionMenuPresentation.resolve(
                frontmostBundleID: "com.apple.Safari",
                attribution: nil,
                isExcluded: { _ in false }
            ),
            .addressUnavailable
        )
    }

    func testCurrentWebsiteIsNormalizedAndReflectsExistingPolicy() {
        let attribution = BrowserURLAttribution(
            url: "https://www.example.com/design",
            domain: "www.example.com",
            title: "Design",
            observedBundleID: "com.apple.Safari"
        )

        XCTAssertEqual(
            WebsiteExclusionMenuPresentation.resolve(
                frontmostBundleID: "com.apple.Safari",
                attribution: attribution,
                isExcluded: { $0 == "example.com" }
            ),
            .available(domain: "example.com", isExcluded: true)
        )
    }

    func testAttributionFromAnotherBrowserIsNeverOffered() {
        let attribution = BrowserURLAttribution(
            url: "https://example.com",
            domain: "example.com",
            title: "Example",
            observedBundleID: "com.google.Chrome"
        )

        XCTAssertEqual(
            WebsiteExclusionMenuPresentation.resolve(
                frontmostBundleID: "com.apple.Safari",
                attribution: attribution,
                isExcluded: { _ in false }
            ),
            .addressUnavailable
        )
    }
}
