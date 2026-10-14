import Combine
import ScreenlogCore
import XCTest

final class SemanticSearchPresentationTests: XCTestCase {
    func testRelatedSearchRequiresConsentInstalledModelsAndAnIndex() {
        let ready = SemanticFeatureStatus(
            enabled: true, phase: .ready, modelInstalled: true,
            index: .init(indexedSources: 1)
        )
        XCTAssertTrue(SemanticSearchPresentation.canSearch(status: ready))
        var status = ready
        status.enabled = false
        XCTAssertFalse(SemanticSearchPresentation.canSearch(status: status))
        status = ready
        status.modelInstalled = false
        XCTAssertFalse(SemanticSearchPresentation.canSearch(status: status))
        status = ready
        status.index.indexedSources = 0
        XCTAssertFalse(SemanticSearchPresentation.canSearch(status: status))
        for phase in [
            SemanticSearchPhase.disabled, .modelMissing, .downloading, .verifying, .failed, .unsupported,
        ] {
            status = ready
            status.phase = phase
            XCTAssertFalse(SemanticSearchPresentation.canSearch(status: status), "\(phase)")
        }
    }

    func testPartialIndexesRemainSearchableWhileIndexingOrWaiting() {
        for phase in [SemanticSearchPhase.ready, .indexing, .paused] {
            let status = SemanticFeatureStatus(
                enabled: true, phase: phase, modelInstalled: true,
                index: .init(pendingSources: 200, indexedSources: 3, failedSources: 1)
            )
            XCTAssertTrue(SemanticSearchPresentation.canSearch(status: status), "\(phase)")
        }
    }

    func testEngineSetterBlocksUnavailableRelatedWithoutChangingExact() {
        var selection = LibrarySearchEngineSelection()
        XCTAssertFalse(selection.select(.related))
        XCTAssertEqual(selection.engine, .exact)
        XCTAssertFalse(selection.select(.exact))
        selection.updateAvailability(true)
        XCTAssertTrue(selection.select(.related))
        XCTAssertEqual(selection.engine, .related)
    }

    func testLosingAvailabilityReturnsToExactAndDoesNotSwitchBackAutomatically() {
        var selection = LibrarySearchEngineSelection()
        selection.updateAvailability(true)
        selection.select(.related)
        XCTAssertTrue(selection.updateAvailability(false))
        XCTAssertEqual(selection.engine, .exact)
        XCTAssertFalse(selection.updateAvailability(false))
        XCTAssertFalse(selection.select(.related))
        XCTAssertFalse(selection.updateAvailability(true))
        XCTAssertEqual(selection.engine, .exact)
    }

    func testQueuedRelatedSelectionIsRejectedAfterAvailabilityChanges() {
        var selection = LibrarySearchEngineSelection()
        selection.updateAvailability(true)
        let queuedRevision = selection.availabilityRevision
        selection.updateAvailability(false)
        selection.updateAvailability(true)
        XCTAssertFalse(selection.select(.related, availabilityRevision: queuedRevision))
        XCTAssertEqual(selection.engine, .exact)
        XCTAssertTrue(selection.select(.related, availabilityRevision: selection.availabilityRevision))
        XCTAssertTrue(selection.select(.exact, availabilityRevision: queuedRevision))
    }

    func testChangingEnabledSourcesInvalidatesMeaningEvenWhenContentRemainsSupported() {
        for initialMode in SemanticSearchMode.allCases {
            for nextMode in SemanticSearchMode.allCases where nextMode != initialMode {
                var selection = LibrarySearchEngineSelection()
                selection.updateAvailability(true, mode: initialMode)
                selection.select(.related)
                let revision = selection.availabilityRevision

                XCTAssertTrue(selection.updateAvailability(true, mode: nextMode))
                XCTAssertEqual(selection.engine, .related)
                XCTAssertEqual(selection.relatedMode, nextMode)
                XCTAssertNotEqual(selection.availabilityRevision, revision)
                XCTAssertFalse(selection.updateAvailability(true, mode: nextMode))
                XCTAssertTrue(SemanticSearchPresentation.allowsContent(.all, mode: nextMode))
            }
        }
    }

    func testQueuedMeaningSelectionIsRejectedAfterSourcesChangeWithoutAvailabilityLoss() {
        var selection = LibrarySearchEngineSelection()
        selection.updateAvailability(true, mode: .both)
        let revision = selection.availabilityRevision
        XCTAssertFalse(selection.updateAvailability(true, mode: .images))
        XCTAssertFalse(selection.select(.related, availabilityRevision: revision))
        XCTAssertEqual(selection.engine, .exact)
        XCTAssertTrue(selection.select(.related, availabilityRevision: selection.availabilityRevision))
    }

    func testObservedSourceModeIsAuthoritativeBeforePublishedStorageChanges() throws {
        final class StatusSource: ObservableObject {
            @Published var mode = SemanticSearchMode.both
        }
        let source = StatusSource()
        var selection = LibrarySearchEngineSelection()
        var storedModeDuringPublication: SemanticSearchMode?
        let subscription = source.$mode.sink { mode in
            storedModeDuringPublication = source.mode
            selection.updateAvailability(true, mode: mode)
        }
        selection.select(.related)
        source.mode = .images

        XCTAssertEqual(storedModeDuringPublication, .both)
        let observedMode = try XCTUnwrap(selection.relatedMode)
        XCTAssertEqual(observedMode, .images)
        XCTAssertFalse(SemanticSearchPresentation.allowsContent(.transcripts, mode: observedMode))
        XCTAssertEqual(SemanticSearchPresentation.supportedContent(.transcripts, mode: observedMode), .all)
        withExtendedLifetime(subscription) {}
    }

    func testRelatedContentFiltersRespectEnabledSources() {
        XCTAssertFalse(SemanticSearchPresentation.allowsContent(.transcripts, mode: .images))
        for mode in SemanticSearchMode.allCases {
            XCTAssertTrue(SemanticSearchPresentation.allowsContent(.all, mode: mode))
            XCTAssertTrue(SemanticSearchPresentation.allowsContent(.screenText, mode: mode))
        }
        XCTAssertTrue(SemanticSearchPresentation.allowsContent(.transcripts, mode: .text))
        XCTAssertTrue(SemanticSearchPresentation.allowsContent(.transcripts, mode: .both))
    }

    func testImagesOnlyMeaningSearchNormalizesAnExistingTranscriptFilter() {
        XCTAssertEqual(SemanticSearchPresentation.supportedContent(.transcripts, mode: .images), .all)
        XCTAssertFalse(SemanticSearchPresentation.allowsContent(.transcripts, mode: .images))
        XCTAssertEqual(SemanticSearchPresentation.supportedContent(.transcripts, mode: .text), .transcripts)
        XCTAssertEqual(SemanticSearchPresentation.supportedContent(.transcripts, mode: .both), .transcripts)
        XCTAssertEqual(SemanticSearchPresentation.supportedContent(.screenText, mode: .images), .screenText)
    }

    func testRelatedSearchRequiresDescriptionRatherThanOnlyFilters() {
        XCTAssertFalse(SemanticSearchPresentation.hasSearchDescription(SearchOperatorParser.parse("")))
        XCTAssertFalse(SemanticSearchPresentation.hasSearchDescription(SearchOperatorParser.parse("app:Safari")))
        XCTAssertFalse(SemanticSearchPresentation.hasSearchDescription(SearchOperatorParser.parse("since:2026-01-01")))
        XCTAssertTrue(SemanticSearchPresentation.hasSearchDescription(SearchOperatorParser.parse("diagram app:Safari")))
    }

    func testQueryCanNarrowBothSourcesWithoutChangingConsent() throws {
        XCTAssertEqual(try SemanticSearchPresentation.queryMode(.images, enabled: .both), .images)
        XCTAssertEqual(try SemanticSearchPresentation.queryMode(.text, enabled: .both), .text)
        XCTAssertEqual(try SemanticSearchPresentation.queryMode(nil, enabled: .both), .both)
        XCTAssertThrowsError(try SemanticSearchPresentation.queryMode(.text, enabled: .images))
        XCTAssertThrowsError(try SemanticSearchPresentation.queryMode(.images, enabled: .text))
        XCTAssertThrowsError(try SemanticSearchPresentation.queryMode(.both, enabled: .text))
    }

    func testExplicitTimeBoundsIntersectOperatorsRatherThanReplaceThem() throws {
        let parsed = SearchOperatorParser.parse("blue diagram since:2026-01-03 before:2026-01-10")
        let bounds = SearchOperatorParser.sqlTimeBounds(from: parsed)
        let lower = try XCTUnwrap(bounds.fromTimestampMs)
        let upper = try XCTUnwrap(bounds.toTimestampMs)
        XCTAssertEqual(SemanticSearchPresentation.lowerBound(lower, lower - 1), lower)
        XCTAssertEqual(SemanticSearchPresentation.lowerBound(lower, lower + 1), lower + 1)
        XCTAssertEqual(SemanticSearchPresentation.upperBound(upper, upper + 1), upper)
        XCTAssertEqual(SemanticSearchPresentation.upperBound(upper, upper - 1), upper - 1)
        XCTAssertEqual(SemanticSearchPresentation.lowerBound(nil, lower), lower)
        XCTAssertEqual(SemanticSearchPresentation.upperBound(upper, nil), upper)
    }

    func testFullInputIdentityIncludesTitleAndUnambiguousBoundaries() {
        let original = SemanticSearchPresentation.textIdentity(title: "ab", text: "c")
        XCTAssertEqual(original, SemanticSearchPresentation.textIdentity(title: "ab", text: "c"))
        XCTAssertNotEqual(original, SemanticSearchPresentation.textIdentity(title: "a", text: "bc"))
        XCTAssertNotEqual(original, SemanticSearchPresentation.textIdentity(title: "new title", text: "c"))
        XCTAssertNotEqual(original, SemanticSearchPresentation.textIdentity(title: "ab", text: "changed text"))
        XCTAssertNotEqual(
            SemanticSearchPresentation.textIdentity(title: nil, text: "body"),
            SemanticSearchPresentation.textIdentity(title: "", text: "body")
        )
    }

    func testRelatedRerankingKeepsExplicitSelectionAndTimelineAnchor() {
        var navigation = LibraryWorkspaceNavigationState()
        navigation.selectResult(42)
        navigation.reconcileSelection(currentResultIDs: [7, 42, 9], previousResultIDs: [42, 9, 7])
        XCTAssertEqual(navigation.selectedResultID, 42)
        XCTAssertEqual(navigation.resultViewportAnchorID, 42)
        navigation.reconcileSelection(currentResultIDs: [7, 9], previousResultIDs: [7, 42, 9])
        XCTAssertNotNil(navigation.selectedResultID)
        XCTAssertNotEqual(navigation.selectedResultID, 42)
    }
}
