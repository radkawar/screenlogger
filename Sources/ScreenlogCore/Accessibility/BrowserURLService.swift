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
        var nodes = 0
        let rawURL = findURL(in: appEl, depth: 0, nodes: &nodes)
        let website = rawURL.flatMap(Self.normalizedWebsite)
        let title = stringAttr(appEl, kAXTitleAttribute as String)
        if let website {
            log.debug("browser url bundle=\(bid, privacy: .private(mask: .hash)) domain=\(website.domain, privacy: .private(mask: .hash))")
            return BrowserURLAttribution(
                url: website.url,
                domain: website.domain,
                title: title,
                observedBundleID: bid
            )
        }
        return BrowserURLAttribution(url: nil, domain: nil, title: title, observedBundleID: bid)
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

    private func findURL(in el: AXUIElement, depth: Int, nodes: inout Int) -> String? {
        if depth > maxDepth || nodes >= maxNodes { return nil }
        nodes += 1

        let role = stringAttr(el, kAXRoleAttribute as String) ?? ""
        // AXURL on web area / address fields
        if let url = stringAttr(el, "AXURL"), url.hasPrefix("http") {
            return url
        }
        if role == "AXWebArea" || role == "AXTextField" || role == "AXComboBox" {
            if let v = stringAttr(el, kAXValueAttribute as String), v.hasPrefix("http") {
                return v
            }
        }

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
            let children = ref as? [AXUIElement]
        {
            for child in children {
                if let u = findURL(in: child, depth: depth + 1, nodes: &nodes) {
                    return u
                }
            }
        }
        return nil
    }

    private func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success, let ref else { return nil }
        if let s = ref as? String { return s }
        if let url = ref as? URL { return url.absoluteString }
        return nil
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
