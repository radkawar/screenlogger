import Foundation
import ScreenlogCore

/// Native menu state for the website under the active browser tab. Resolving
/// it here keeps Accessibility failures and browser focus races deterministic.
enum WebsiteExclusionMenuPresentation: Equatable, Sendable {
    case hidden
    case addressUnavailable
    case available(domain: String, isExcluded: Bool)

    static func resolve(
        frontmostBundleID: String?,
        attribution: BrowserURLAttribution?,
        isExcluded: (String) -> Bool
    ) -> Self {
        guard BrowserURLService.isSupportedBrowser(bundleID: frontmostBundleID) else {
            return .hidden
        }
        guard let attribution,
            attribution.observedBundleID == frontmostBundleID,
            let domain = attribution.domain,
            let normalized = DomainExclusionParser.normalize(domain)
        else {
            return .addressUnavailable
        }
        return .available(domain: normalized, isExcluded: isExcluded(normalized))
    }
}

/// The effective capture result shown beside every app and website policy.
/// These are deliberately outcomes rather than checkbox states: a disabled
/// checkbox can still mean "Never Capture" when a broader rule owns it.
enum ExclusionEffectiveOutcome: Equatable, Sendable {
    case neverCapture
    case canCapture

    var title: String {
        switch self {
        case .neverCapture: return "Never Capture"
        case .canCapture: return "Can Capture"
        }
    }

    var systemImage: String {
        switch self {
        case .neverCapture: return "eye.slash.fill"
        case .canCapture: return "eye"
        }
    }
}

/// Why an effective exclusion outcome applies. More than one source may be
/// active at once; retaining all of them prevents removing one explicit rule
/// from falsely implying that capture is now possible.
enum ExclusionPolicyProvenance: Equatable, Sendable {
    case explicitApplication
    case explicitDomain
    case broaderCategory(String)
    case entireBrowser
    case unknownAddressStrictProtection

    var title: String {
        switch self {
        case .explicitApplication: return "Explicit application"
        case .explicitDomain: return "Explicit website"
        case .broaderCategory(let name): return "Category: \(name)"
        case .entireBrowser: return "Entire browser"
        case .unknownAddressStrictProtection: return "Strict unknown-address protection"
        }
    }
}

/// Shared, deterministic copy policy for Exclusions Settings.
///
/// Application and website views provide facts; this type owns the outcome,
/// provenance, and future-only language presented to sighted and VoiceOver
/// users. It intentionally never claims that changing a rule deletes history.
struct ExclusionPolicyPresentation: Equatable, Sendable {
    static let futureMomentsNotice =
        "Changes apply to future moments only. Existing Library moments are not deleted."

    static let scopeSummary =
        "Exclusions decide what Screenlogger may save in future moments. Existing Library moments are unchanged."

    static let websiteAddressScope =
        "Website rules apply when a supported browser shares its active address."

    static let entireBrowserGuarantee =
        "Excluding a browser application protects every window from that browser."

    static let websiteScopeAccessibilityHint =
        "\(websiteAddressScope) \(entireBrowserGuarantee) \(futureMomentsNotice)"

    let outcome: ExclusionEffectiveOutcome
    let provenance: [ExclusionPolicyProvenance]
    let detail: String

    var provenanceSummary: String {
        guard !provenance.isEmpty else { return "No matching exclusion" }
        return provenance.map(\.title).joined(separator: ", ")
    }

    var accessibilityHint: String {
        "\(outcome.title). \(detail) \(Self.futureMomentsNotice)"
    }

    static func application(
        displayName: String,
        bundleID: String,
        explicitlyExcluded: Bool,
        categoryNames: [String] = []
    ) -> Self {
        let isBrowser = BrowserURLService.isSupportedBrowser(bundleID: bundleID)
        var provenance: [ExclusionPolicyProvenance] = []
        if explicitlyExcluded { provenance.append(.explicitApplication) }
        provenance.append(contentsOf: normalizedCategoryNames(categoryNames).map { .broaderCategory($0) })
        if explicitlyExcluded, isBrowser { provenance.append(.entireBrowser) }

        guard !provenance.isEmpty else {
            let browserQualification =
                isBrowser
                ? " Website, private-window, or strict unknown-address protections can still skip specific browser moments."
                : ""
            return Self(
                outcome: .canCapture,
                provenance: [],
                detail: "No application exclusion applies to \(displayName).\(browserQualification)"
            )
        }

        let detail: String
        if explicitlyExcluded, isBrowser {
            detail =
                "\(displayName) is explicitly excluded as an entire browser, so every one of its windows is skipped."
        } else if !categoryNames.isEmpty, explicitlyExcluded {
            detail =
                "\(displayName) is explicitly excluded and is also covered by \(categoryDescription(categoryNames))."
        } else if !categoryNames.isEmpty {
            detail = "\(displayName) is covered by \(categoryDescription(categoryNames))."
        } else {
            detail = "\(displayName) is explicitly excluded under Applications."
        }
        return Self(outcome: .neverCapture, provenance: provenance, detail: detail)
    }

    static func website(
        domain: String,
        explicitlyExcluded: Bool,
        categoryNames: [String] = []
    ) -> Self {
        let categories = normalizedCategoryNames(categoryNames)
        var provenance: [ExclusionPolicyProvenance] = []
        if explicitlyExcluded { provenance.append(.explicitDomain) }
        provenance.append(contentsOf: categories.map { .broaderCategory($0) })

        guard !provenance.isEmpty else {
            return Self(
                outcome: .canCapture,
                provenance: [],
                detail:
                    "No website exclusion applies to \(domain) when its browser address is available."
            )
        }

        let detail: String
        if explicitlyExcluded, !categories.isEmpty {
            detail =
                "\(domain) is explicitly excluded and is also covered by \(categoryDescription(categories)) when its browser address is available."
        } else if explicitlyExcluded {
            detail =
                "\(domain) is explicitly excluded when its browser address is available."
        } else {
            detail =
                "\(domain) is covered by \(categoryDescription(categories)) when its browser address is available."
        }
        return Self(outcome: .neverCapture, provenance: provenance, detail: detail)
    }

    static func broaderCategory(
        name: String,
        isEnabled: Bool,
        matchingContent: String
    ) -> Self {
        if isEnabled {
            return Self(
                outcome: .neverCapture,
                provenance: [.broaderCategory(name)],
                detail: "The enabled \(name) category skips matching \(matchingContent)."
            )
        }
        return Self(
            outcome: .canCapture,
            provenance: [],
            detail:
                "The \(name) category is off. Explicit or other broader exclusions can still apply."
        )
    }

    static func unknownBrowserAddress(strictProtectionEnabled: Bool) -> Self {
        if strictProtectionEnabled {
            return Self(
                outcome: .neverCapture,
                provenance: [.unknownAddressStrictProtection],
                detail:
                    "Supported browsers are skipped whenever Screenlogger cannot identify their active website."
            )
        }
        return Self(
            outcome: .canCapture,
            provenance: [],
            detail:
                "A supported browser can be captured when its active website is unknown. Exclude the entire browser for a guaranteed block."
        )
    }

    private static func normalizedCategoryNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return
            names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func categoryDescription(_ names: [String]) -> String {
        let names = normalizedCategoryNames(names)
        switch names.count {
        case 0: return "an enabled category"
        case 1: return "the enabled \(names[0]) category"
        default:
            guard let last = names.last else { return "an enabled category" }
            return "the enabled \(names.dropLast().joined(separator: ", ")) and \(last) categories"
        }
    }
}
