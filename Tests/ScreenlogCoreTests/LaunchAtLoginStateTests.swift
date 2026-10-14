import XCTest

@testable import ScreenlogCore

final class LaunchAtLoginStateTests: XCTestCase {
    func testEnabledValueAlwaysRepresentsSystemState() {
        XCTAssertFalse(LaunchAtLoginState.ready(isEnabled: false).isEnabled)
        XCTAssertTrue(LaunchAtLoginState.ready(isEnabled: true).isEnabled)
        XCTAssertFalse(LaunchAtLoginState.enabling(previouslyEnabled: false).isEnabled)
        XCTAssertTrue(LaunchAtLoginState.disabling(previouslyEnabled: true).isEnabled)
        XCTAssertFalse(LaunchAtLoginState.disabling(previouslyEnabled: false).isEnabled)
        XCTAssertFalse(LaunchAtLoginState.approvalRequired.isEnabled)
        XCTAssertFalse(
            LaunchAtLoginState.failed(
                operation: .enable,
                isEnabled: false,
                issue: .registrationFailed
            ).isEnabled
        )
        XCTAssertTrue(
            LaunchAtLoginState.failed(
                operation: .disable,
                isEnabled: true,
                issue: .removalFailed
            ).isEnabled
        )
    }

    func testOnlyTransitionsAreBusy() {
        XCTAssertTrue(LaunchAtLoginState.enabling(previouslyEnabled: false).isBusy)
        XCTAssertTrue(LaunchAtLoginState.disabling(previouslyEnabled: true).isBusy)
        XCTAssertFalse(LaunchAtLoginState.ready(isEnabled: false).isBusy)
        XCTAssertFalse(LaunchAtLoginState.approvalRequired.isBusy)
        XCTAssertFalse(
            LaunchAtLoginState.failed(
                operation: .refresh,
                isEnabled: false,
                issue: .serviceUnavailable
            ).isBusy
        )
    }

    func testRecoveryPreservesTheSafeOperation() {
        XCTAssertEqual(LaunchAtLoginState.approvalRequired.retryOperation, .refresh)
        XCTAssertEqual(
            LaunchAtLoginState.failed(
                operation: .enable,
                isEnabled: false,
                issue: .registrationFailed
            ).retryOperation,
            .enable
        )
        XCTAssertEqual(
            LaunchAtLoginState.failed(
                operation: .disable,
                isEnabled: true,
                issue: .removalFailed
            ).retryOperation,
            .disable
        )
        XCTAssertNil(LaunchAtLoginState.ready(isEnabled: true).retryOperation)
    }
}
