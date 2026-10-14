import Foundation
import XCTest

@testable import ScreenlogCore

final class ScreenlogProcessPreferencesTests: XCTestCase {
    private let token = "4ef32591-bf79-445d-8bbb-19026f8a5952"

    func testRoutedFixtureAcceptsOnlyTheMatchingIsolatedSuite() {
        let request = validRequest()

        XCTAssertEqual(
            ScreenlogProcessPreferences.routedUITestSuiteName(
                environment: request.environment,
                arguments: request.arguments,
                temporaryDirectory: request.temporaryDirectory
            ),
            "dev.screenlog.ui-tests.\(token)"
        )

        var routedEnvironment = request.environment
        routedEnvironment.removeValue(forKey: "SCREENLOG_UI_TEST_FIXTURE")
        routedEnvironment["SCREENLOG_UI_TEST_PREFERENCES_MODE"] = "isolated-v1"
        XCTAssertEqual(
            ScreenlogProcessPreferences.routedUITestSuiteName(
                environment: routedEnvironment,
                arguments: request.arguments,
                temporaryDirectory: request.temporaryDirectory
            ),
            "dev.screenlog.ui-tests.\(token)"
        )
    }

    func testRoutedFixtureRejectsMismatchedSuiteRootAndHome() {
        let request = validRequest()
        for key in ["SCREENLOG_UI_TEST_PREFERENCES_SUITE", "SCREENLOG_DATA_DIR", "CFFIXED_USER_HOME"] {
            var environment = request.environment
            environment[key] = "/unexpected"
            XCTAssertNil(
                ScreenlogProcessPreferences.routedUITestSuiteName(
                    environment: environment,
                    arguments: request.arguments,
                    temporaryDirectory: request.temporaryDirectory
                ),
                "Expected \(key) mismatch to fail closed"
            )
        }
    }

    func testRoutedFixtureRejectsMissingOrInvalidAuthentication() {
        let request = validRequest()
        XCTAssertNil(
            ScreenlogProcessPreferences.routedUITestSuiteName(
                environment: request.environment,
                arguments: [],
                temporaryDirectory: request.temporaryDirectory
            )
        )

        var environment = request.environment
        environment["SCREENLOG_UI_TEST_FIXTURE"] = "unknown"
        XCTAssertNil(
            ScreenlogProcessPreferences.routedUITestSuiteName(
                environment: environment,
                arguments: request.arguments,
                temporaryDirectory: request.temporaryDirectory
            )
        )
    }

    func testRoutedFixtureAcceptsTheFixedUITestRunnerContainer() {
        var request = validRequest()
        let root = URL(
            fileURLWithPath:
                "/Users/test/Library/Containers/dev.screenlog.ui-tests.xctrunner/Data/tmp/screenlogger-ui-tests/\(token)",
            isDirectory: true
        )
        request.environment["SCREENLOG_DATA_DIR"] = root.path
        request.environment["CFFIXED_USER_HOME"] =
            root.appendingPathComponent(
                "home",
                isDirectory: true
            ).path

        XCTAssertEqual(
            ScreenlogProcessPreferences.routedUITestSuiteName(
                environment: request.environment,
                arguments: request.arguments,
                temporaryDirectory: request.temporaryDirectory
            ),
            "dev.screenlog.ui-tests.\(token)"
        )
    }

    func testRoutedFixtureRejectsOtherContainerAndTokenLookalikes() {
        let request = validRequest()
        let roots = [
            "/Users/test/Library/Containers/dev.other-tests.xctrunner/Data/tmp/screenlogger-ui-tests/\(token)",
            "/Users/test/Library/Containers/dev.screenlog.ui-tests.xctrunner/Data/tmp/screenlogger-ui-tests/00000000-0000-4000-8000-000000000000",
            "/Users/test/Library/Containers/dev.screenlog.ui-tests.xctrunner/Data/tmp/not-screenlogger-ui-tests/\(token)",
        ]

        for path in roots {
            var environment = request.environment
            environment["SCREENLOG_DATA_DIR"] = path
            environment["CFFIXED_USER_HOME"] =
                URL(
                    fileURLWithPath: path,
                    isDirectory: true
                ).appendingPathComponent("home", isDirectory: true).path
            XCTAssertNil(
                ScreenlogProcessPreferences.routedUITestSuiteName(
                    environment: environment,
                    arguments: request.arguments,
                    temporaryDirectory: request.temporaryDirectory
                ),
                "Expected a lookalike runner root to fail closed: \(path)"
            )
        }
    }

    private func validRequest() -> (
        environment: [String: String],
        arguments: [String],
        temporaryDirectory: URL
    ) {
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp/screenlogger-preference-tests")
        let root =
            temporaryDirectory
            .appendingPathComponent("screenlogger-ui-tests", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        return (
            environment: [
                "SCREENLOG_UI_TEST_FIXTURE": "deterministic-navigation-v1",
                "SCREENLOG_UI_TEST_PREFERENCES_SUITE": "dev.screenlog.ui-tests.\(token)",
                "SCREENLOG_DATA_DIR": root.path,
                "CFFIXED_USER_HOME": root.appendingPathComponent("home", isDirectory: true).path,
            ],
            arguments: ["Screenlogger", "--screenlogger-ui-test-token", token],
            temporaryDirectory: temporaryDirectory
        )
    }
}
