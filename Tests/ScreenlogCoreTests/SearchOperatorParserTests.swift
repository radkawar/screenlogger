import XCTest

@testable import ScreenlogCore

final class SearchOperatorParserTests: XCTestCase {
    func testInvalidConstraintsCannotSilentlyBroadenSearch() {
        for query in [
            "invoice date:2026-02-30",
            "invoice since:2026-13-01",
            "invoice before:not-a-date",
            "invoice since:2026-10-20 before:2026-10-10",
            "invoice date:2026-10-15 since:2026-10-16",
            "invoice app:Mail app:Safari",
            "invoice site:",
            #"invoice app:"""#,
            #"invoice app:"unfinished"#,
        ] {
            XCTAssertNotNil(SearchOperatorParser.parse(query).validationIssue, query)
        }
    }

    func testCompatibleDateConstraintsAndQuotedValuesRemainUsable() {
        for query in [
            "invoice since:2026-10-15 before:2026-10-15",
            "invoice date:2026-10-15 since:2026-10-01 before:2026-10-31",
            "invoice date:2024-02-29",
            #"invoice app:"Visual Studio Code" site:example.com"#,
        ] {
            XCTAssertNil(SearchOperatorParser.parse(query).validationIssue, query)
        }
    }

    func testParseSiteAndAppStripFromFTS() {
        let p = SearchOperatorParser.parse("invoice site:en.wikipedia.org app:Safari")
        XCTAssertEqual(p.ftsText, "invoice")
        XCTAssertEqual(p.siteFilter, "en.wikipedia.org")
        XCTAssertEqual(p.appFilter, "Safari")
        XCTAssertTrue(p.highlightTokens.contains("invoice"))
    }

    func testUnfinishedQuotedOperatorRemainsADraft() {
        let p = SearchOperatorParser.parse(#"invoice app:"Visual Studio "#)
        XCTAssertEqual(p.ftsText, "invoice")
        XCTAssertNil(p.appFilter)
        XCTAssertNil(p.rawApp)
        XCTAssertEqual(
            SearchOperatorParser.typingContext(for: #"invoice app:"Visual Studio "#),
            .appValue(partial: "Visual Studio ")
        )
    }

    func testParseDateToday() {
        let p = SearchOperatorParser.parse("notes date:today")
        XCTAssertEqual(p.ftsText, "notes")
        XCTAssertNotNil(p.dayStartMs)
        XCTAssertNotNil(p.dayEndMs)
        XCTAssertLessThanOrEqual(p.dayStartMs!, p.dayEndMs!)
    }

    func testParseSinceBefore() {
        let p = SearchOperatorParser.parse("x since:2026-01-01 before:2026-01-31")
        XCTAssertEqual(p.ftsText, "x")
        XCTAssertNotNil(p.sinceMs)
        XCTAssertNotNil(p.beforeMs)
        XCTAssertLessThan(p.sinceMs!, p.beforeMs!)
    }

    func testDayFiltersIncludeFinalMillisecondAcrossDaylightSavingTime() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let nextDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let nextMidnight = Int64(nextDay.timeIntervalSince1970 * 1000)
        for key in ["date", "before"] {
            let parsed = SearchOperatorParser.parse(
                "notes \(key):2026-11-01", calendar: calendar, timeZone: zone
            )
            XCTAssertTrue(
                SearchOperatorParser.matchesTimeBounds(
                    FTSResult(frameID: 1, timestampMs: nextMidnight - 1), parsed: parsed
                )
            )
            XCTAssertFalse(
                SearchOperatorParser.matchesTimeBounds(
                    FTSResult(frameID: 2, timestampMs: nextMidnight), parsed: parsed
                )
            )
        }
    }

    func testTypingContextOperators() {
        XCTAssertEqual(SearchOperatorParser.typingContext(for: ""), .operators(partial: ""))
        XCTAssertEqual(SearchOperatorParser.typingContext(for: "hello "), .operators(partial: ""))
        XCTAssertEqual(SearchOperatorParser.typingContext(for: "ap"), .operators(partial: "ap"))
        if case .appValue(let p) = SearchOperatorParser.typingContext(for: "app:Saf") {
            XCTAssertEqual(p, "Saf")
        } else {
            XCTFail("expected appValue")
        }
        if case .siteValue(let p) = SearchOperatorParser.typingContext(for: "foo site:wiki") {
            XCTAssertEqual(p, "wiki")
        } else {
            XCTFail("expected siteValue")
        }
        XCTAssertEqual(SearchOperatorParser.typingContext(for: "invoice"), .freeText)
    }

    func testAutocompleteRowsOperatorsAndValues() {
        let apps = [("Safari", "com.apple.Safari"), ("Ghostty", "com.mitchellh.ghostty")]
        let sites = ["en.wikipedia.org", "github.com", "news.ycombinator.com"]

        let empty = SearchOperatorParser.autocompleteRows(for: "", appCatalog: apps, siteCatalog: sites)
        let emptyOps = empty.compactMap { row -> SearchOperatorKind? in
            if case .op(let k) = row { return k }
            return nil
        }
        XCTAssertEqual(emptyOps.count, SearchOperatorKind.allCases.count)
        // Empty input previews catalog sites and apps.
        XCTAssertTrue(
            empty.contains {
                if case .site = $0 { return true }
                return false
            })
        XCTAssertTrue(
            empty.contains {
                if case .app = $0 { return true }
                return false
            })

        let appRows = SearchOperatorParser.autocompleteRows(for: "app:Saf", appCatalog: apps, siteCatalog: sites)
        XCTAssertEqual(appRows.count, 1)
        if case .app(let name, let bid) = appRows[0] {
            XCTAssertEqual(name, "Safari")
            XCTAssertEqual(bid, "com.apple.Safari")
        } else {
            XCTFail("expected app row")
        }

        let siteRows = SearchOperatorParser.autocompleteRows(for: "site:git", appCatalog: apps, siteCatalog: sites)
        XCTAssertEqual(siteRows.count, 1)
        if case .site(let d) = siteRows[0] {
            XCTAssertEqual(d, "github.com")
        } else {
            XCTFail("expected site row")
        }

        // Free text stays quiet unless a catalog value actually matches. Advanced
        // operators appear only when the user types an operator prefix or space.
        let free = SearchOperatorParser.autocompleteRows(for: "saf", appCatalog: apps, siteCatalog: sites)
        XCTAssertFalse(
            free.contains {
                if case .op(.app) = $0 { return true }
                return false
            })
        XCTAssertTrue(
            free.contains {
                if case .app(let n, _) = $0 { return n == "Safari" }
                return false
            })

        XCTAssertTrue(
            SearchOperatorParser.autocompleteRows(
                for: "navigation",
                appCatalog: apps,
                siteCatalog: sites
            ).isEmpty
        )

        let afterSpace = SearchOperatorParser.autocompleteRows(
            for: "invoice ",
            appCatalog: apps,
            siteCatalog: sites
        )
        XCTAssertTrue(
            afterSpace.contains {
                if case .op(.app) = $0 { return true }
                return false
            }
        )
    }

    func testInsertAndCompleteValue() {
        XCTAssertEqual(SearchOperatorParser.insertOperator(.site, into: ""), "site:")
        XCTAssertEqual(SearchOperatorParser.insertOperator(.app, into: "hello "), "hello app:")
        XCTAssertEqual(SearchOperatorParser.completeValue("Safari", into: "app:Saf"), "app:Safari ")
        XCTAssertEqual(SearchOperatorParser.completeValue("github.com", into: "x site:git"), "x site:github.com ")
        XCTAssertEqual(SearchOperatorParser.completeValue("today", into: "date:"), "date:today ")
    }

    func testApplyValueSuggestionFreeTextAndMidOp() {
        // A free-text filter token is replaced by app:Name.
        XCTAssertEqual(
            SearchOperatorParser.applyValueSuggestion(.app, value: "Safari", into: "invoice a"),
            "invoice app:Safari "
        )
        XCTAssertEqual(
            SearchOperatorParser.applyValueSuggestion(.site, value: "github.com", into: "git"),
            "site:github.com "
        )
        // Mid op:value still completes in place.
        XCTAssertEqual(
            SearchOperatorParser.applyValueSuggestion(.app, value: "Safari", into: "app:Saf"),
            "app:Safari "
        )
        XCTAssertEqual(
            SearchOperatorParser.applyValueSuggestion(.date, value: "today", into: "notes "),
            "notes date:today "
        )
        XCTAssertEqual(
            SearchOperatorParser.applyValueSuggestion(
                .app,
                value: "Visual Studio Code",
                into: #"notes app:"Visual Stu"#
            ),
            #"notes app:"Visual Studio Code" "#
        )
    }

    func testRemoveOperator() {
        let q = "invoice app:Safari site:github.com"
        let noApp = SearchOperatorParser.removeOperator(.app, from: q)
        XCTAssertFalse(noApp.contains("app:"))
        XCTAssertTrue(noApp.contains("site:github.com"))
        XCTAssertTrue(noApp.contains("invoice"))
    }

    func testReplacingOperatorPreservesTermsAndOtherFilters() {
        XCTAssertEqual(
            SearchOperatorParser.replacingOperator(
                .date,
                value: "2026-07-31",
                in: "quarterly planning app:Safari"
            ),
            "quarterly planning app:Safari date:2026-07-31"
        )
        XCTAssertEqual(
            SearchOperatorParser.replacingOperator(
                .date,
                value: "yesterday",
                in: "quarterly date:today planning"
            ),
            "quarterly planning date:yesterday"
        )
    }

    /// Dismissible chip path: quoted multi-word app + date must strip cleanly end-to-end.
    func testRemoveOperatorQuotedAppAndDate() {
        let q = #"notes app:"System Settings" date:today site:en.wikipedia.org"#
        let noApp = SearchOperatorParser.removeOperator(.app, from: q)
        XCTAssertFalse(noApp.lowercased().contains("app:"))
        XCTAssertFalse(noApp.contains("System Settings"))
        XCTAssertTrue(noApp.contains("date:today"))
        XCTAssertTrue(noApp.contains("site:en.wikipedia.org"))
        XCTAssertTrue(noApp.contains("notes"))

        let noDate = SearchOperatorParser.removeOperator(.date, from: noApp)
        XCTAssertFalse(noDate.contains("date:"))
        XCTAssertEqual(
            SearchOperatorParser.parse(noDate).ftsText,
            "notes"
        )
        XCTAssertEqual(SearchOperatorParser.parse(noDate).siteFilter, "en.wikipedia.org")
        XCTAssertNil(SearchOperatorParser.parse(noDate).appFilter)
        XCTAssertNil(SearchOperatorParser.parse(noDate).dayStartMs)
    }

    func testScopedClearQueriesKeepOnlyTheRequestedCriteria() {
        let query = #"design review app:"System Settings" site:example.com date:today"#

        XCTAssertEqual(
            SearchOperatorParser.retainingOnlyValidOperators(in: query),
            #"app:"System Settings" site:example.com date:today"#
        )
        XCTAssertEqual(
            SearchOperatorParser.removingAllOperators(from: query),
            "design review"
        )
    }

    func testClearSearchDoesNotPromoteInvalidOrUnfinishedFilters() {
        XCTAssertEqual(
            SearchOperatorParser.retainingOnlyValidOperators(
                in: #"design app:"Visual Studio "#
            ),
            ""
        )
        XCTAssertEqual(
            SearchOperatorParser.retainingOnlyValidOperators(
                in: "design date:not-a-date site:example.com"
            ),
            "site:example.com"
        )
    }

    func testMatchesSiteAndApp() {
        let hit = FTSResult(
            frameID: 1,
            timestampMs: 1_700_000_000_000,
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            domain: "en.wikipedia.org"
        )
        XCTAssertTrue(SearchOperatorParser.matchesApp(hit, appFilter: "Safari"))
        XCTAssertTrue(SearchOperatorParser.matchesSite(hit, siteFilter: "wikipedia.org"))
        let google = FTSResult(frameID: 2, timestampMs: 1, domain: "google.com")
        XCTAssertFalse(SearchOperatorParser.matchesSite(google, siteFilter: "mail.google.com"))
    }

    func testFuzzyAppFilterKeepsSafariBundle() {
        let hits = [
            FTSResult(
                frameID: 1,
                timestampMs: 100,
                bundleID: "com.apple.Safari",
                displayName: "Safari",
                domain: "en.wikipedia.org",
                snippet: "invoice"
            ),
            FTSResult(
                frameID: 2,
                timestampMs: 200,
                bundleID: "com.hnc.Discord",
                displayName: "Discord",
                snippet: "invoice"
            ),
        ]
        let kept = hits.filter { SearchOperatorParser.matchesApp($0, appFilter: "Safari") }
        XCTAssertEqual(kept.map(\.frameID), [1])
    }

    func testMatchesTimeBounds() {
        var p = ParsedSearchQuery()
        p.sinceMs = 1000
        p.beforeMs = 2000
        XCTAssertTrue(
            SearchOperatorParser.matchesTimeBounds(
                FTSResult(frameID: 1, timestampMs: 1500), parsed: p
            ))
        XCTAssertFalse(
            SearchOperatorParser.matchesTimeBounds(
                FTSResult(frameID: 2, timestampMs: 500), parsed: p
            ))
    }

    func testDateAutocompleteIncludesPickDate() {
        let rows = SearchOperatorParser.autocompleteRows(
            for: "date:",
            appCatalog: [],
            siteCatalog: []
        )
        XCTAssertTrue(
            rows.contains {
                if case .dateValue("today") = $0 { return true }
                return false
            })
        XCTAssertTrue(
            rows.contains {
                if case .dateValue("yesterday") = $0 { return true }
                return false
            })
        XCTAssertTrue(
            rows.contains {
                if case .pickDate = $0 { return true }
                return false
            })
    }

    func testIncompleteISODateIsNotPresentedAsActionable() {
        let rows = SearchOperatorParser.autocompleteRows(
            for: "date:2026-07",
            appCatalog: [],
            siteCatalog: []
        )
        XCTAssertEqual(rows, [.pickDate])

        let complete = SearchOperatorParser.autocompleteRows(
            for: "date:2026-07-31",
            appCatalog: [],
            siteCatalog: []
        )
        XCTAssertEqual(complete, [.dateValue("2026-07-31"), .pickDate])
    }

    func testSQLTimeBoundsMergeDateSinceBefore() {
        var p = ParsedSearchQuery()
        p.dayStartMs = 1000
        p.dayEndMs = 5000
        p.sinceMs = 2000
        p.beforeMs = 4000
        let b = SearchOperatorParser.sqlTimeBounds(from: p)
        XCTAssertEqual(b.fromTimestampMs, 2000)  // max(dayStart, since)
        XCTAssertEqual(b.toTimestampMs, 4000)  // min(dayEnd, before)

        var sinceOnly = ParsedSearchQuery()
        sinceOnly.sinceMs = 99
        let s = SearchOperatorParser.sqlTimeBounds(from: sinceOnly)
        XCTAssertEqual(s.fromTimestampMs, 99)
        XCTAssertNil(s.toTimestampMs)

        let empty = ParsedSearchQuery()
        let e = SearchOperatorParser.sqlTimeBounds(from: empty)
        XCTAssertNil(e.fromTimestampMs)
        XCTAssertNil(e.toTimestampMs)
    }
}
