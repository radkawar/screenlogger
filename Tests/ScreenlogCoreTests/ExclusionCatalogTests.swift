import XCTest

@testable import ScreenlogCore

final class ExclusionCatalogTests: XCTestCase {
    func testApplicationDiscoveryReturnsLegitimateEmptyCatalog() throws {
        let service = ApplicationDiscoveryService(
            searchRoots: [URL(fileURLWithPath: "/missing-applications")],
            directoryCatalog: { _ in [] },
            runningCatalog: { [] }
        )

        XCTAssertEqual(try service.discover(), [])
    }

    func testApplicationDiscoverySurfacesFailureInsteadOfEmptyCatalog() {
        let service = ApplicationDiscoveryService(
            searchRoots: [URL(fileURLWithPath: "/unreadable-applications")],
            directoryCatalog: { _ in throw TestCatalogError.unreadable },
            runningCatalog: { [] }
        )

        XCTAssertThrowsError(try service.discover()) { error in
            XCTAssertEqual(error as? ApplicationDiscoveryError, .catalogUnavailable)
        }
    }

    func testApplicationDiscoveryKeepsUsefulResultsWhenOneCatalogFails() throws {
        let service = ApplicationDiscoveryService(
            searchRoots: [URL(fileURLWithPath: "/unreadable-applications")],
            directoryCatalog: { _ in throw TestCatalogError.unreadable },
            runningCatalog: {
                [DiscoveredApplication(bundleID: "com.example.Editor", name: "Editor")]
            }
        )

        XCTAssertEqual(
            try service.discover(),
            [DiscoveredApplication(bundleID: "com.example.Editor", name: "Editor")]
        )
    }

    func testApplicationDiscoveryDeduplicatesBundleIDsCaseInsensitively() throws {
        let service = ApplicationDiscoveryService(
            searchRoots: [URL(fileURLWithPath: "/Applications")],
            directoryCatalog: { _ in
                [DiscoveredApplication(bundleID: "com.example.Editor", name: "Editor")]
            },
            runningCatalog: {
                [DiscoveredApplication(bundleID: "COM.EXAMPLE.EDITOR", name: "Editor Running")]
            }
        )

        XCTAssertEqual(
            try service.discover(),
            [DiscoveredApplication(bundleID: "com.example.Editor", name: "Editor")]
        )
    }

    func testPasswordManagerCatalogLoadsFromDataFile() {
        let ids = ExclusionCatalog.passwordManagerBundleIDs
        XCTAssertFalse(ids.isEmpty)
        XCTAssertTrue(ids.contains("com.1password.1password"))
        XCTAssertTrue(ids.contains("com.bitwarden.desktop"))
        // All lowercase reverse-DNS style.
        XCTAssertTrue(ids.allSatisfy { $0 == $0.lowercased() && $0.contains(".") })
    }

    func testBankDomainCatalogLoadsProjectCuratedDefaults() {
        let domains = ExclusionCatalog.bankDomains
        XCTAssertGreaterThan(domains.count, 25, "curated financial exclusions should be useful")
        XCTAssertTrue(domains.contains("bankofamerica.com"))
        XCTAssertTrue(domains.contains("wise.com"))
        // No schemes / www.
        XCTAssertFalse(domains.contains(where: { $0.contains("://") || $0.hasPrefix("www.") }))
    }

    func testBanksCategoryExcludesDomainWithoutMaterializingList() {
        let store = ExclusionStore(userDefaults: UserDefaults(suiteName: "screenlog.test.banks.\(UUID().uuidString)")!)
        store.banksCategoryEnabled = false
        let sample = ExclusionCatalog.bankDomains.first ?? "ally.com"
        XCTAssertFalse(store.isDomainExcluded(sample), "banks off: not excluded")

        store.banksCategoryEnabled = true
        XCTAssertTrue(store.isDomainExcluded(sample), "banks on: catalog domain excluded")
        // Nested host
        XCTAssertTrue(store.isDomainExcluded("online.\(sample)"), "parent domain match under banks pack")
    }

    func testPasswordManagersCategoryMatchesCatalogBundle() {
        let store = ExclusionStore(userDefaults: UserDefaults(suiteName: "screenlog.test.pm.\(UUID().uuidString)")!)
        store.passwordManagersCategoryEnabled = true
        XCTAssertTrue(store.isExcluded(bundleID: "com.1password.1password", domain: nil))
        store.passwordManagersCategoryEnabled = false
        // Explicit add still works
        store.add("com.1password.1password")
        XCTAssertTrue(store.isExcluded(bundleID: "com.1password.1password", domain: nil))
    }

    private enum TestCatalogError: Error {
        case unreadable
    }
}
