import Foundation
import ScreenlogCore

/// Owns application and website exclusion settings.
@MainActor
extension AppModel {
    // MARK: - Exclusions (wired to ExclusionStore)

    func addExclusion() {
        let bid = newExclusionBundle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return }
        exclusionStore.add(bid)
        reloadExclusionsFromStore()
        newExclusionBundle = ""
        statusMessage = "Will not capture \(SLAppIdentity.displayName(bundleID: bid))"
    }

    func addExclusion(_ bundleID: String) {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return }
        exclusionStore.add(bid)
        reloadExclusionsFromStore()
    }

    func removeExclusion(_ bundleID: String) {
        let displayName = SLAppIdentity.displayName(bundleID: bundleID)
        exclusionStore.remove(bundleID)
        if case .application(let change) = recentCaptureExclusion,
            change.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        {
            recentCaptureExclusion = nil
        }
        reloadExclusionsFromStore()
        statusMessage = "Will capture \(displayName) again"
    }

    func addDomainExclusion() {
        let raw = newExclusionDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = DomainExclusionParser.normalize(raw) else { return }
        exclusionStore.addDomain(normalized)
        reloadExclusionsFromStore()
        newExclusionDomain = ""
        statusMessage = "Will not capture \(normalized)"
    }

    /// Installed and running apps shown by the exclusions picker.
    func refreshDiscoveredApplications() async {
        let requestID = UUID()
        applicationDiscoveryLoadRequestID = requestID
        applicationDiscoveryLoadState = .loading

        #if DEBUG
            if let fixtureIssue = AppUITestFixture.applicationDiscoveryIssue {
                applicationDiscoveryLoadState = .failed(fixtureIssue)
                return
            }
            if let fixtureApplications = AppUITestFixture.discoveredApplications {
                applicationDiscoveryLoadState = .loaded(fixtureApplications)
                return
            }
        #endif

        do {
            let applications = try await Task.detached(priority: .utility) {
                try ApplicationDiscoveryService().discover()
            }.value
            guard applicationDiscoveryLoadRequestID == requestID else { return }
            applicationDiscoveryLoadState = .loaded(applications)
        } catch {
            guard applicationDiscoveryLoadRequestID == requestID else { return }
            writeBootstrapLog("application discovery failed: \(error.localizedDescription)")
            applicationDiscoveryLoadState = .failed(.catalogUnavailable)
        }
    }

    /// Domains seen in the library (Exclusions to Websites 'Recently Recorded').
    func refreshRecordedDomains() async {
        let requestID = UUID()
        recordedDomainLoadRequestID = requestID
        recordedDomainLoadState = .loading
        guard let store else {
            recordedDomainLoadState = .failed(.libraryUnavailable)
            return
        }
        do {
            let rows = try await store.readAsync { try $0.listDomains() }
            guard recordedDomainLoadRequestID == requestID else { return }
            recordedDomainList = rows.map(\.normalizedDomain).filter { !$0.isEmpty }.sorted()
            recordedDomainLoadState = .loaded
        } catch {
            guard recordedDomainLoadRequestID == requestID else { return }
            writeBootstrapLog("recorded domain refresh failed: \(error.localizedDescription)")
            recordedDomainLoadState = .failed(.queryFailed)
        }
    }

    func restoreExclusionDefaults() {
        exclusionStore.clearAll()
        recentCaptureExclusion = nil
        // Privacy-first defaults: exclude password managers and private tabs.
        applyExclusionCategory(.passwordManagers, enabled: true)
        applyExclusionCategory(.banks, enabled: false)
        excludePrivateTabs = true
        pauseWhenBrowserAddressUnavailable = false
        for app in SystemExclusionApp.allCases {
            setSystemAppExcluded(app, excluded: false)
        }
        reloadExclusionsFromStore()
        statusMessage = "Exclusion defaults restored"
    }

    @discardableResult
    func addDomainExclusion(_ domain: String) -> Bool {
        guard let normalized = DomainExclusionParser.normalize(domain) else { return false }
        exclusionStore.addDomain(normalized)
        reloadExclusionsFromStore()
        statusMessage = "Will not capture \(normalized)"
        return true
    }

    func removeDomainExclusion(_ domain: String) {
        exclusionStore.removeDomain(domain)
        if case .website(let recentDomain) = recentCaptureExclusion,
            DomainExclusionParser.normalize(recentDomain) == DomainExclusionParser.normalize(domain)
        {
            recentCaptureExclusion = nil
        }
        reloadExclusionsFromStore()
        statusMessage = "Removed \(domain)"
    }

    func isDomainEffectivelyExcluded(_ domain: String) -> Bool {
        exclusionStore.isDomainExcluded(domain)
    }

    func reloadExclusionsFromStore() {
        excludedBundles = exclusionStore.allSorted()
        excludedDomains = exclusionStore.allDomainsSorted()
    }

}
