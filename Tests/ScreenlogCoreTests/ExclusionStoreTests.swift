import XCTest

@testable import ScreenlogCore

final class ExclusionStoreTests: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!
    var store: ExclusionStore!

    override func setUpWithError() throws {
        suiteName = "screenlog.exclusion.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = ExclusionStore(userDefaults: defaults)
    }

    override func tearDownWithError() throws {
        store.clearAll()
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
    }

    func testBundleAddContainsRemove() {
        XCTAssertFalse(store.contains("com.apple.mail"))
        XCTAssertTrue(store.add("com.apple.mail"))
        XCTAssertFalse(store.add("com.apple.mail"), "duplicate add returns false")
        XCTAssertTrue(store.contains("com.apple.mail"))
        // Case: stored as given; contains also checks lowercased set membership for lowercase stored
        XCTAssertTrue(store.add("  com.Slack  "))
        XCTAssertTrue(store.contains("com.Slack"))

        store.remove("com.apple.mail")
        XCTAssertFalse(store.contains("com.apple.mail"))

        XCTAssertFalse(store.add(""))
        XCTAssertFalse(store.add("   "))
        XCTAssertFalse(store.contains(nil))
        XCTAssertFalse(store.contains(""))
    }

    func testBundleReplaceAndSorted() {
        store.replaceAll(["z.app", "a.app", "", "  b.app  "])
        XCTAssertEqual(store.allSorted(), ["a.app", "b.app", "z.app"])
    }

    func testDomainNormalizationAndParentMatch() {
        store.addDomain("https://www.Example.com/path")
        XCTAssertEqual(store.allDomainsSorted(), ["example.com"])
        XCTAssertTrue(store.isDomainExcluded("example.com"))
        XCTAssertTrue(store.isDomainExcluded("docs.example.com"), "parent domain excludes subdomains")
        XCTAssertTrue(store.isDomainExcluded("HTTPS://WWW.EXAMPLE.COM/x"))
        XCTAssertFalse(store.isDomainExcluded("example.org"))
        XCTAssertFalse(store.isDomainExcluded(nil))
        XCTAssertFalse(store.isDomainExcluded(""))

        store.removeDomain("EXAMPLE.COM")
        XCTAssertFalse(store.isDomainExcluded("docs.example.com"))
    }

    func testDomainParserRejectsValuesThatCannotMatchBrowserHosts() {
        XCTAssertEqual(DomainExclusionParser.normalize("https://www.Example.com/path"), "example.com")
        XCTAssertEqual(DomainExclusionParser.normalize("docs.example.com"), "docs.example.com")
        XCTAssertNil(DomainExclusionParser.normalize("not a domain"))
        XCTAssertNil(DomainExclusionParser.normalize("https://user:secret@example.com"))
        XCTAssertNil(DomainExclusionParser.normalize("https://example.com:8443"))
        XCTAssertNil(DomainExclusionParser.normalize("ftp://example.com"))
        XCTAssertNil(DomainExclusionParser.normalize("-invalid.example"))
    }

    func testDomainReplaceAll() {
        store.replaceAllDomains(["a.com", "https://b.com/x", "www.c.com"])
        XCTAssertEqual(store.allDomainsSorted(), ["a.com", "b.com", "c.com"])
    }

    func testWebsitePreflightOnlyActivatesWhenAWebsitePolicyExists() {
        XCTAssertFalse(store.hasWebsiteExclusions)

        store.add("com.example.app")
        XCTAssertFalse(store.hasWebsiteExclusions)

        store.addDomain("example.com")
        XCTAssertTrue(store.hasWebsiteExclusions)

        store.removeDomain("example.com")
        XCTAssertFalse(store.hasWebsiteExclusions)

        store.banksCategoryEnabled = true
        XCTAssertTrue(store.hasWebsiteExclusions)
    }

    func testCombinedIsExcludedAndShouldExclude() {
        store.add("com.secret.app")
        store.addDomain("private.example")

        XCTAssertTrue(store.isExcluded(bundleID: "com.secret.app", domain: nil))
        XCTAssertTrue(store.shouldExclude(bundleID: nil, domain: "app.private.example"))
        XCTAssertFalse(store.isExcluded(bundleID: "com.public", domain: "public.example"))
        XCTAssertTrue(
            store.isExcluded(bundleID: "com.secret.app", domain: "public.example"),
            "bundle alone is enough"
        )
    }

    func testPersistenceAcrossInstances() {
        XCTAssertTrue(store.add("com.persisted"))
        store.addDomain("persist.example")

        let reloaded = ExclusionStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.contains("com.persisted"))
        XCTAssertTrue(reloaded.isDomainExcluded("sub.persist.example"))
    }

    func testClearAll() {
        store.add("com.x")
        store.addDomain("x.com")
        store.clearAll()
        XCTAssertTrue(store.allSorted().isEmpty)
        XCTAssertTrue(store.allDomainsSorted().isEmpty)
        XCTAssertFalse(store.contains("com.x"))
        XCTAssertFalse(store.isDomainExcluded("x.com"))
    }
}
