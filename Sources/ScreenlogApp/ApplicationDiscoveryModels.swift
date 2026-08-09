import ScreenlogCore

enum ApplicationDiscoveryLoadState: Equatable, Sendable {
    case loading
    case loaded([DiscoveredApplication])
    case failed(ApplicationDiscoveryError)
}

struct ExcludedApplicationChange: Equatable, Sendable {
    let bundleID: String
    let displayName: String
}

enum RecentCaptureExclusion: Equatable, Sendable {
    case application(ExcludedApplicationChange)
    case website(domain: String)
}
