import Foundation
import XCTest

@testable import ScreenlogCore

final class TimedCapturePausePreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "screenlog.timed-pause.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testValidFuturePauseRoundTrips() {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        let resumeAt = startedAt.addingTimeInterval(3_600)
        TimedCapturePausePreference.save(
            startedAt: startedAt,
            resumeAt: resumeAt,
            to: defaults
        )

        XCTAssertEqual(
            TimedCapturePausePreference.restoredResumeDate(
                from: defaults,
                now: startedAt.addingTimeInterval(900)
            ),
            resumeAt
        )
    }

    func testExpiredPauseIsCleared() {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        TimedCapturePausePreference.save(
            startedAt: startedAt,
            resumeAt: startedAt.addingTimeInterval(3_600),
            to: defaults
        )

        XCTAssertNil(
            TimedCapturePausePreference.restoredResumeDate(
                from: defaults,
                now: startedAt.addingTimeInterval(3_601)
            )
        )
        assertPauseStateCleared()
    }

    func testBackwardClockJumpReanchorsOriginalDuration() throws {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        TimedCapturePausePreference.save(
            startedAt: startedAt,
            resumeAt: startedAt.addingTimeInterval(3_600),
            to: defaults
        )
        let movedBackNow = startedAt.addingTimeInterval(-600)

        let restored = try XCTUnwrap(
            TimedCapturePausePreference.restoredResumeDate(
                from: defaults,
                now: movedBackNow
            )
        )

        XCTAssertEqual(restored, movedBackNow.addingTimeInterval(3_600))
        XCTAssertEqual(
            defaults.double(forKey: ProductPreferenceKey.timedCapturePauseStartedAt),
            movedBackNow.timeIntervalSince1970
        )
    }

    func testMalformedOrImplausiblyLongPauseIsCleared() {
        defaults.set(Double.nan, forKey: ProductPreferenceKey.timedCapturePauseStartedAt)
        defaults.set(20_000.0, forKey: ProductPreferenceKey.timedCapturePauseResumeAt)
        XCTAssertNil(TimedCapturePausePreference.restoredResumeDate(from: defaults))
        assertPauseStateCleared()

        let startedAt = Date(timeIntervalSince1970: 10_000)
        TimedCapturePausePreference.save(
            startedAt: startedAt,
            resumeAt: startedAt.addingTimeInterval(
                TimedCapturePausePreference.maximumDuration + 1
            ),
            to: defaults
        )
        assertPauseStateCleared()
    }

    private func assertPauseStateCleared() {
        XCTAssertNil(defaults.object(forKey: ProductPreferenceKey.timedCapturePauseStartedAt))
        XCTAssertNil(defaults.object(forKey: ProductPreferenceKey.timedCapturePauseResumeAt))
    }
}
