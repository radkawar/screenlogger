import XCTest

@testable import ScreenlogCore

final class ProductVersionTests: XCTestCase {
    func testSharedProductVersionLoadsForClients() {
        XCTAssertNotEqual(ScreenlogCore.version, "unknown")
        XCTAssertNotEqual(ScreenlogCore.buildVersion, "unknown")
        XCTAssertNotNil(
            ScreenlogCore.version.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#,
                options: .regularExpression
            )
        )
        XCTAssertNotNil(Int(ScreenlogCore.buildVersion))
        XCTAssertGreaterThan(Int(ScreenlogCore.buildVersion) ?? 0, 0)
    }
}
