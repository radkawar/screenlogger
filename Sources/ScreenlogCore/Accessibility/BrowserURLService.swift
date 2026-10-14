import AppKit
import ApplicationServices
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.screenlog", category: "browser-url")

/// One live observation of a supported foreground browser. A missing result
/// means Accessibility was unavailable or the foreground app was not a browser.
/// `url` and `domain` remain nil when the browser was recognized but did not
/// expose a valid HTTP(S) website address.
public struct BrowserURLAttribution: Equatable, Sendable {
    public var url: String?
    public var domain: String?
    public var title: String?
    public var observedBundleID: String

    public init(url: String?, domain: String?, title: String?, observedBundleID: String) {
        self.url = url
        self.domain = domain
        self.title = title
        self.observedBundleID = observedBundleID
    }

    public var hasWebsiteAddress: Bool {
        guard let url,
            let components = URLComponents(string: url),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            domain?.caseInsensitiveCompare(host) == .orderedSame
        else {
            return false
        }
        return true
    }
}

/// Reads the frontmost browser URL via Accessibility (AXWebArea + AXURL).
public final class BrowserURLService: @unchecked Sendable {
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
    ]

    public var maxNodes = 400
    public var maxDepth = 10

    public init() {}

    public static func isSupportedBrowser(bundleID: String?) -> Bool {
        bundleID.map(browserBundleIDs.contains) ?? false
    }

    public func frontmostBrowserAttribution() -> BrowserURLAttribution? {
        browserAttribution(for: NSWorkspace.shared.frontmostApplication)
    }

    /// Reads a specific browser retained by a menu action. The status item can
    /// temporarily become frontmost while its menu is open, so callers must be
    /// able to resolve the browser that was active immediately beforehand.
    public func browserAttribution(
        for application: NSRunningApplication?
    ) -> BrowserURLAttribution? {
        guard AccessibilityPermission.isTrusted(prompt: false) else {
            return nil
        }
        guard let app = application,
            !app.isTerminated,
            let bid = app.bundleIdentifier,
            Self.browserBundleIDs.contains(bid)
        else {
            return nil
        }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // An unresponsive browser must not stall capture privacy evaluation or
        // the app's main actor. The caller treats an AX timeout as an unknown
        // address and applies its configured fail-closed policy.
        AXUIElementSetMessagingTimeout(appEl, 0.15)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        do {
            let window = try focusedWindow(appEl, deadline: deadline)
            let attribution = Self.focusedWindowAttribution(
                window: window,
                bundleID: bid,
                maxNodes: maxNodes,
                maxDepth: maxDepth,
                stringAttribute: { try self.stringAttr($0, $1, deadline: deadline) },
                children: { try self.children($0, limit: $1, deadline: deadline) }
            )
            // Focus can move while AX is answering. Never attach the old
            // window's address or title to the newly focused window.
            guard let window,
                let currentWindow = try focusedWindow(appEl, deadline: deadline),
                CFEqual(window, currentWindow)
            else {
                return BrowserURLAttribution(url: nil, domain: nil, title: nil, observedBundleID: bid)
            }
            if let domain = attribution.domain {
                log.debug("browser url bundle=\(bid, privacy: .private(mask: .hash)) domain=\(domain, privacy: .private(mask: .hash))")
            }
            return attribution
        } catch {
            return BrowserURLAttribution(url: nil, domain: nil, title: nil, observedBundleID: bid)
        }
    }

    /// Compatibility wrapper for existing non-capture callers.
    public func frontmostBrowserURL() -> (url: String?, domain: String?, title: String?, bundleID: String?) {
        guard let attribution = frontmostBrowserAttribution() else {
            return (nil, nil, nil, nil)
        }
        return (
            attribution.url,
            attribution.domain,
            attribution.title,
            attribution.observedBundleID
        )
    }

    private static func normalizedWebsite(_ raw: String) -> (url: String, domain: String)? {
        guard let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host?.lowercased(),
            !host.isEmpty
        else {
            return nil
        }
        return (raw, host)
    }

    /// Shared selection policy for live AX and small in-memory test fixtures.
    /// The only root is AXFocusedWindow, never AXWindows or the application tree.
    static func focusedWindowAttribution<Element>(
        window: Element?,
        bundleID: String,
        maxNodes: Int = 400,
        maxDepth: Int = 10,
        stringAttribute: (Element, String) throws -> String?,
        children: (Element, Int) throws -> [Element]
    ) -> BrowserURLAttribution {
        var result = BrowserURLAttribution(
            url: nil, domain: nil, title: nil, observedBundleID: bundleID
        )
        guard let window else { return result }
        do {
            guard try stringAttribute(window, kAXRoleAttribute as String) == kAXWindowRole as String
            else { return result }
            result.title = try stringAttribute(window, kAXTitleAttribute as String)
            let document = try stringAttribute(window, kAXDocumentAttribute as String)
            var nodes = 0
            var webAreaCount = 0
            var pageURL: String?
            var pageTitle: String?

            func visit(_ element: Element, depth: Int) throws {
                guard depth <= maxDepth, nodes < maxNodes else { throw ReadFailure.incomplete }
                nodes += 1
                if try stringAttribute(element, "AXHidden") == "true" { return }
                let role = try stringAttribute(element, kAXRoleAttribute as String)
                if role == "AXWebArea" {
                    webAreaCount += 1
                    guard webAreaCount == 1 else { throw ReadFailure.incomplete }
                    pageURL = try stringAttribute(element, "AXURL")
                    pageTitle = try stringAttribute(element, kAXTitleAttribute as String)
                    // Never descend into page content: links, editable fields,
                    // and nested frames cannot identify the top-level page.
                    return
                }
                if (depth > 0 && role == kAXWindowRole as String)
                    || role == "AXMenuBar" || role == "AXMenu" || role == "AXMenuItem"
                    || role == "AXLink" || role == "AXTextField" || role == "AXComboBox"
                {
                    return
                }
                for child in try children(element, maxNodes - nodes) {
                    try visit(child, depth: depth + 1)
                }
            }

            try visit(window, depth: 0)
            // A present but internal/blank WebArea URL is authoritative. In
            // particular it must not fall through to an old window document.
            // Safari and other browsers may instead expose AXDocument on the
            // focused window; it is the only fallback, not an editable omnibox.
            let website = (pageURL ?? document).flatMap(normalizedWebsite)
            result.url = website?.url
            result.domain = website?.domain
            if let pageTitle, !pageTitle.isEmpty {
                result.title = pageTitle
            }
        } catch {
            // Timeouts, ambiguous pages and incomplete traversal are unknown,
            // even if an earlier node offered a plausible website.
            result.url = nil
            result.domain = nil
        }
        return result
    }

    private enum ReadFailure: Error {
        case incomplete
    }

    private func attribute(
        _ element: AXUIElement, _ name: String, deadline: ContinuousClock.Instant
    ) throws -> CFTypeRef? {
        guard ContinuousClock.now < deadline else { throw ReadFailure.incomplete }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch error {
        case .success:
            return value
        case .attributeUnsupported, .noValue:
            return nil
        default:
            throw ReadFailure.incomplete
        }
    }

    private func focusedWindow(
        _ application: AXUIElement, deadline: ContinuousClock.Instant
    ) throws -> AXUIElement? {
        guard let value = try attribute(application, kAXFocusedWindowAttribute as String, deadline: deadline)
        else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw ReadFailure.incomplete }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttr(
        _ element: AXUIElement, _ name: String, deadline: ContinuousClock.Instant
    ) throws -> String? {
        guard let value = try attribute(element, name, deadline: deadline) else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        if name == "AXHidden", let hidden = value as? NSNumber {
            return hidden.boolValue ? "true" : "false"
        }
        return nil
    }

    private func children(
        _ element: AXUIElement, limit: Int, deadline: ContinuousClock.Instant
    ) throws -> [AXUIElement] {
        guard ContinuousClock.now < deadline else { throw ReadFailure.incomplete }
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        if error == .attributeUnsupported || error == .noValue { return [] }
        guard error == .success, count <= limit else { throw ReadFailure.incomplete }
        guard count > 0 else { return [] }
        var values: CFArray?
        guard
            AXUIElementCopyAttributeValues(
                element, kAXChildrenAttribute as CFString, 0, count, &values
            ) == .success, let children = values as? [AXUIElement]
        else {
            throw ReadFailure.incomplete
        }
        return children
    }
}

/// Pure decision boundary for website exclusions when browser attribution is
/// unavailable. The capture pipeline supplies the focused app and any detected
/// domain; keeping the policy here makes the privacy behavior deterministic and
/// unit-testable without ScreenCaptureKit or Accessibility access.
public enum BrowserCapturePrivacyPolicy {
    public static func shouldPause(
        capturedBundleID: String?,
        attribution: BrowserURLAttribution?,
        pauseWhenAddressUnavailable: Bool
    ) -> Bool {
        guard pauseWhenAddressUnavailable,
            let capturedBundleID,
            BrowserURLService.isSupportedBrowser(bundleID: capturedBundleID)
        else {
            return false
        }
        guard let attribution,
            attribution.observedBundleID == capturedBundleID
        else {
            return true
        }
        return !attribution.hasWebsiteAddress
    }
}
