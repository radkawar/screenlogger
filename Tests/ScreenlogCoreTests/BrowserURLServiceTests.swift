import Foundation
import XCTest

@testable import ScreenlogCore

final class BrowserURLServiceTests: XCTestCase {
    private final class Node {
        let attributes: [String: String]
        let children: [Node]
        let unavailable: Bool

        init(
            _ role: String,
            title: String? = nil,
            url: String? = nil,
            document: String? = nil,
            value: String? = nil,
            hidden: Bool = false,
            unavailable: Bool = false,
            children: [Node] = []
        ) {
            var attributes = ["AXRole": role]
            attributes["AXTitle"] = title
            attributes["AXURL"] = url
            attributes["AXDocument"] = document
            attributes["AXValue"] = value
            if hidden { attributes["AXHidden"] = "true" }
            self.attributes = attributes
            self.children = children
            self.unavailable = unavailable
        }
    }

    private enum FixtureFailure: Error {
        case unavailable
        case truncated
    }

    private func observe(
        _ window: Node?,
        bundleID: String = "com.google.Chrome",
        maxNodes: Int = 400,
        maxDepth: Int = 10,
        onChildren: (Node) -> Void = { _ in }
    ) -> BrowserURLAttribution {
        BrowserURLService.focusedWindowAttribution(
            window: window,
            bundleID: bundleID,
            maxNodes: maxNodes,
            maxDepth: maxDepth,
            stringAttribute: { node, name in
                if node.unavailable { throw FixtureFailure.unavailable }
                return node.attributes[name]
            },
            children: { node, limit in
                onChildren(node)
                if node.children.count > limit { throw FixtureFailure.truncated }
                return node.children
            }
        )
    }

    func testBlankFocusedWindowDoesNotUseBackgroundYouTubeWindow() {
        let blank = Node(
            "AXWindow", title: "about:blank",
            children: [
                Node("AXWebArea", url: "about:blank")
            ])
        let youtube = Node(
            "AXWindow", title: "YouTube",
            children: [
                Node("AXWebArea", url: "https://www.youtube.com/")
            ])
        // AXFocusedWindow is independent of AXWindows order. Only the focus
        // target is passed to selection; neither the app nor its windows are roots.
        let applicationWindows = [youtube, blank]
        let focusedWindow = applicationWindows[1]
        let result = observe(focusedWindow)

        XCTAssertNil(result.url)
        XCTAssertNil(result.domain)
        XCTAssertEqual(result.title, "about:blank")
        XCTAssertTrue(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.google.Chrome",
                attribution: result,
                pauseWhenAddressUnavailable: true
            ))
        XCTAssertEqual(observe(applicationWindows[0]).domain, "www.youtube.com")
    }

    func testApplicationRootIsNotAcceptedAsWindowEvidence() {
        let application = Node(
            "AXApplication", title: "Chrome",
            children: [
                Node("AXWindow", children: [Node("AXWebArea", url: "https://youtube.com")])
            ])
        let result = observe(application)
        XCTAssertNil(result.url)
        XCTAssertNil(result.title)
    }

    func testMissingFocusedWindowDoesNotInventTitleOrWebsite() {
        let result = observe(nil)
        XCTAssertNil(result.url)
        XCTAssertNil(result.title)
        XCTAssertEqual(result.observedBundleID, "com.google.Chrome")
    }

    func testChromeWebAreaAtDepthEightSuppliesPageURLAndTitle() {
        var content = Node("AXWebArea", title: "Video title", url: "https://www.youtube.com/watch?v=123")
        for _ in 0..<7 { content = Node("AXGroup", children: [content]) }
        let result = observe(Node("AXWindow", title: "Video title - Google Chrome", children: [content]))

        XCTAssertEqual(result.url, "https://www.youtube.com/watch?v=123")
        XCTAssertEqual(result.domain, "www.youtube.com")
        XCTAssertEqual(result.title, "Video title")
    }

    func testWindowTitleIsUsedWhenPageTitleIsMissing() {
        let result = observe(
            Node(
                "AXWindow", title: "Current tab",
                children: [
                    Node("AXWebArea", url: "https://example.com")
                ]))
        XCTAssertEqual(result.title, "Current tab")
    }

    func testSafariFocusedWindowDocumentIsSupportedWithoutWebAreaURL() {
        for bundleID in ["com.apple.Safari", "com.apple.SafariTechnologyPreview"] {
            let result = observe(
                Node(
                    "AXWindow", title: "Safari page", document: "https://example.com/article",
                    children: [Node("AXWebArea")]
                ), bundleID: bundleID)
            XCTAssertEqual(result.url, "https://example.com/article")
            XCTAssertEqual(result.domain, "example.com")
            XCTAssertEqual(result.observedBundleID, bundleID)
        }
    }

    func testWebAreaEvidenceWorksForOtherSupportedBrowsers() {
        for bundleID in BrowserURLService.browserBundleIDs {
            let result = observe(
                Node(
                    "AXWindow",
                    children: [
                        Node("AXWebArea", url: "HTTPS://EXAMPLE.COM/page")
                    ]), bundleID: bundleID)
            XCTAssertEqual(result.domain, "example.com", bundleID)
            XCTAssertTrue(result.hasWebsiteAddress, bundleID)
        }
    }

    func testInternalPageDoesNotFallBackToWindowDocumentOrAddressField() {
        for address in ["about:blank", "chrome://settings", "about:newtab", "", "file:///tmp/page.html"] {
            let result = observe(
                Node(
                    "AXWindow", document: "https://old.example",
                    children: [
                        Node("AXTextField", value: "https://typed.example"),
                        Node("AXWebArea", url: address),
                    ]))
            XCTAssertNil(result.url, address)
            XCTAssertNil(result.domain, address)
        }
    }

    func testLinksEditableFieldsMenusAndNestedWindowsAreNotPageEvidence() {
        let result = observe(
            Node(
                "AXWindow", title: "Unknown page",
                children: [
                    Node("AXLink", url: "https://link.example"),
                    Node("AXTextField", url: "https://field.example", value: "https://typed.example"),
                    Node("AXComboBox", value: "https://combo.example"),
                    Node("AXGroup", url: "https://group.example"),
                    Node("AXMenuBar", children: [Node("AXWebArea", url: "https://menu.example")]),
                    Node("AXWindow", children: [Node("AXWebArea", url: "https://background.example")]),
                ]))
        XCTAssertNil(result.url)
        XCTAssertEqual(result.title, "Unknown page")
    }

    func testWebContentAndNestedFramesAreNeverTraversed() {
        let page = Node(
            "AXWebArea",
            children: [
                Node("AXWebArea", url: "https://iframe.example"),
                Node("AXLink", url: "https://link.example"),
                Node("AXTextField", value: "https://input.example"),
                Node("AXGroup", unavailable: true),
            ])
        var pageChildrenRead = false
        let result = observe(Node("AXWindow", children: [page])) { node in
            if node === page { pageChildrenRead = true }
        }
        XCTAssertNil(result.url)
        XCTAssertFalse(pageChildrenRead)
    }

    func testHiddenTabDoesNotOverrideVisibleTab() {
        let result = observe(
            Node(
                "AXWindow",
                children: [
                    Node(
                        "AXGroup", hidden: true,
                        children: [
                            Node("AXWebArea", url: "https://background.example")
                        ]),
                    Node("AXWebArea", title: "Active tab", url: "https://active.example"),
                ]))
        XCTAssertEqual(result.domain, "active.example")
        XCTAssertEqual(result.title, "Active tab")
    }

    func testMultipleExposedPagesAreAmbiguousRatherThanFirstMatchWins() {
        let result = observe(
            Node(
                "AXWindow", document: "https://first.example",
                children: [
                    Node("AXWebArea", url: "https://first.example"),
                    Node("AXWebArea", url: "https://second.example"),
                ]))
        XCTAssertNil(result.url)
    }

    func testTimeoutAfterCandidateDiscardsCandidateAndDocumentFallback() {
        let result = observe(
            Node(
                "AXWindow", document: "https://document.example",
                children: [
                    Node("AXWebArea", url: "https://candidate.example"),
                    Node("AXGroup", unavailable: true),
                ]))
        XCTAssertNil(result.url)
        XCTAssertNil(result.domain)
    }

    func testDepthAndNodeLimitsFailClosedInsteadOfKeepingPartialEvidence() {
        let window = Node(
            "AXWindow", document: "https://document.example",
            children: [
                Node("AXWebArea", url: "https://candidate.example"),
                Node("AXGroup", children: [Node("AXGroup")]),
            ])
        XCTAssertNil(observe(window, maxNodes: 3).url)
        XCTAssertNil(observe(window, maxDepth: 1).url)
        XCTAssertNil(observe(window, maxNodes: 0).url)
        XCTAssertEqual(observe(window, maxNodes: 4, maxDepth: 2).domain, "candidate.example")
    }

    func testOnlyExactHTTPAndHTTPSSchemesWithHostsAreAccepted() {
        for address in ["httpx://example.com", "httpsomething://example.com", "https:", "http:///", "example.com"] {
            XCTAssertNil(observe(Node("AXWindow", children: [Node("AXWebArea", url: address)])).url, address)
            XCTAssertNil(observe(Node("AXWindow", document: address)).url, address)
        }
        for address in ["http://example.com", "https://example.com"] {
            XCTAssertEqual(observe(Node("AXWindow", children: [Node("AXWebArea", url: address)])).url, address)
        }
    }
}
