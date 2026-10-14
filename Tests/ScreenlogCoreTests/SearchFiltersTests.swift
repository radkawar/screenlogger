import XCTest

@testable import ScreenlogCore

final class SearchFiltersTests: XCTestCase {
    private func hit(
        id: Int64,
        ms: Int64,
        bundle: String? = nil,
        domain: String? = nil,
        display: String? = nil
    ) -> FTSResult {
        FTSResult(
            frameID: id,
            timestampMs: ms,
            title: nil,
            bundleID: bundle,
            displayName: display,
            domain: domain,
            snippet: nil,
            imagePath: nil,
            isCompacted: false
        )
    }

    func testTimeWindowTodayYesterdayLastWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // Fixed "now": 2024-06-15 15:00 UTC
        let now = Date(timeIntervalSince1970: 1_718_463_600)
        let todayMs: Int64 = 1_718_463_600 * 1000
        let yesterdayMs: Int64 = (1_718_463_600 - 86_400) * 1000
        let eightDaysAgoMs: Int64 = (1_718_463_600 - 8 * 86_400) * 1000
        let threeDaysAgoMs: Int64 = (1_718_463_600 - 3 * 86_400) * 1000

        XCTAssertTrue(SearchTimeWindow.today.matches(timestampMs: todayMs, now: now, calendar: cal))
        XCTAssertFalse(SearchTimeWindow.today.matches(timestampMs: yesterdayMs, now: now, calendar: cal))

        XCTAssertTrue(SearchTimeWindow.yesterday.matches(timestampMs: yesterdayMs, now: now, calendar: cal))
        XCTAssertFalse(SearchTimeWindow.yesterday.matches(timestampMs: todayMs, now: now, calendar: cal))

        XCTAssertTrue(SearchTimeWindow.lastWeek.matches(timestampMs: threeDaysAgoMs, now: now, calendar: cal))
        XCTAssertFalse(SearchTimeWindow.lastWeek.matches(timestampMs: eightDaysAgoMs, now: now, calendar: cal))
        XCTAssertTrue(SearchTimeWindow.all.matches(timestampMs: eightDaysAgoMs, now: now, calendar: cal))
    }

    func testApplySessionAppDomainFilters() {
        let rows = [
            hit(id: 1, ms: 1_000, bundle: "a.app", domain: "https://www.Example.com/x"),
            hit(id: 2, ms: 2_000, bundle: "b.app", domain: "news.ycombinator.com"),
            hit(id: 3, ms: 50_000, bundle: "a.app", domain: "example.com"),
        ]

        let sessionOnly = SearchResultFiltering.apply(
            results: rows,
            sessionStartMs: 500,
            sessionEndMs: 3_000
        )
        XCTAssertEqual(sessionOnly.map(\.frameID), [1, 2])

        let appOnly = SearchResultFiltering.apply(results: rows, appBundleID: "a.app")
        XCTAssertEqual(appOnly.map(\.frameID), [1, 3])

        let domainOnly = SearchResultFiltering.apply(results: rows, domain: "example.com")
        XCTAssertEqual(domainOnly.map(\.frameID), [1, 3])

        let combined = SearchResultFiltering.apply(
            results: rows,
            appBundleID: "a.app",
            domain: "example.com",
            sessionStartMs: 500,
            sessionEndMs: 3_000
        )
        XCTAssertEqual(combined.map(\.frameID), [1])
    }

    func testDomainAndAppChips() {
        let rows = [
            hit(id: 1, ms: 1, bundle: "dev.a", domain: "foo.com", display: "A"),
            hit(id: 2, ms: 2, bundle: "dev.a", domain: "bar.com", display: "A"),
            hit(id: 3, ms: 3, bundle: "dev.b", domain: "foo.com", display: "B"),
            hit(id: 4, ms: 4, bundle: "dev.b", domain: nil, display: "B"),
        ]
        let domains = SearchResultFiltering.domainChips(from: rows)
        XCTAssertEqual(domains.map(\.domain), ["foo.com", "bar.com"])
        XCTAssertEqual(domains.first?.count, 2)

        let apps = SearchResultFiltering.appChips(from: rows)
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps.map(\.count), [2, 2])
    }
}
