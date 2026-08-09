import CoreGraphics
import ImageIO
import XCTest

@testable import ScreenlogCore

final class CaptureOnceFailureTests: XCTestCase {
    func testScreenloggerIsAlwaysAddedToCaptureFilter() {
        let result = ScreenloggerCapturePrivacy.includingScreenlogger(
            in: ["com.apple.Notes", "DEV.EXAMPLE.APP"]
        )

        XCTAssertTrue(ScreenloggerCapturePrivacy.isScreenlogger(bundleID: "dev.screenlog.app"))
        XCTAssertTrue(result.contains("dev.screenlog.app"))
        XCTAssertTrue(result.contains("dev.example.app"))
        XCTAssertEqual(result.count, 3)
    }

    func testRawImageCanBeEncodedOnceAtStorageBoundary() async throws {
        let bytes: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255,
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )

        let encoded = try await ScreenCaptureService().encodeStill(image)

        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertTrue(["heic", "jpg", "png"].contains(encoded.fileExtension))
        XCTAssertNotNil(CGImageSourceCreateWithData(encoded.data as CFData, nil))
    }

    func testCaptureResolutionPolicyPreservesNativePixelsForUltra() {
        let size = ScreenCaptureService.outputSize(
            nativeWidth: 6_016,
            nativeHeight: 3_384,
            maxDimension: 0
        )
        XCTAssertEqual(size.width, 6_016)
        XCTAssertEqual(size.height, 3_384)
    }

    func testCaptureResolutionPolicyDownscalesWithoutUpscaling() {
        let downscaled = ScreenCaptureService.outputSize(
            nativeWidth: 3_456,
            nativeHeight: 2_234,
            maxDimension: 2_880
        )
        XCTAssertEqual(downscaled.width, 2_880)
        XCTAssertEqual(downscaled.height, 1_862)

        let unchanged = ScreenCaptureService.outputSize(
            nativeWidth: 1_280,
            nativeHeight: 800,
            maxDimension: 1_920
        )
        XCTAssertEqual(unchanged.width, 1_280)
        XCTAssertEqual(unchanged.height, 800)
    }

    func testDisplayWindowFilteringKeepsOnlyIntersectingAndSpanningWindows() {
        let leftDisplay = CaptureDisplayRect(x: 0, y: 0, width: 1000, height: 800)
        let windows = [
            WindowBound(bundleID: "dev.left", x: 20, y: 20, width: 300, height: 300),
            WindowBound(bundleID: "dev.right", x: 1100, y: 20, width: 300, height: 300),
            WindowBound(bundleID: "dev.spanning", x: 900, y: 40, width: 300, height: 300),
        ]

        let visible = ScreenCaptureService.windows(windows, visibleOn: leftDisplay)

        XCTAssertEqual(visible.compactMap(\.bundleID), ["dev.left", "dev.spanning"])
    }

    func testDisplayWindowFilteringFallsBackToAllMetadataWithoutGeometry() {
        let windows = [WindowBound(bundleID: "dev.example", x: 0, y: 0, width: 100, height: 100)]
        XCTAssertEqual(ScreenCaptureService.windows(windows, visibleOn: nil).count, 1)
    }

    func testOperationalFailuresCarryOnlyStablePrivacySafeCopy() {
        let rawDetail = "/Users/person/Secret Project/private-frame.heic: encoding failed"
        let error = NSError(
            domain: rawDetail,
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: rawDetail]
        )
        let failure = CaptureOnceFailure.classify(error, pauseReason: nil)

        XCTAssertEqual(failure, .captureFailed)
        XCTAssertFalse(failure.userTitle.contains(rawDetail))
        XCTAssertFalse(failure.userMessage.contains(rawDetail))
        XCTAssertFalse(String(describing: failure).contains(rawDetail))
    }

    func testCaptureErrorsMapToTypedRecoveryStates() {
        XCTAssertEqual(CaptureOnceFailure.classify(CaptureError.noDisplay, pauseReason: nil), .displayUnavailable)
        XCTAssertEqual(CaptureOnceFailure.classify(CaptureError.encodeFailed, pauseReason: nil), .encodingFailed)
        XCTAssertEqual(CaptureOnceFailure.classify(CaptureError.notAuthorized, pauseReason: nil), .permissionRequired)
        XCTAssertEqual(CaptureOnceFailure.classify(CaptureError.diskFull, pauseReason: nil), .lowDiskSpace)
        XCTAssertEqual(
            CaptureOnceFailure.classify(CaptureError.excluded, pauseReason: .privateBrowsing),
            .privateBrowsing
        )
        XCTAssertEqual(
            CaptureOnceFailure.classify(CaptureError.excluded, pauseReason: .browserAddressUnavailable),
            .browserAddressUnavailable
        )
        XCTAssertEqual(CaptureOnceFailure.classify(CaptureError.excluded, pauseReason: nil), .excludedContent)
    }

    func testExpectedRecoveryMessagesRemainSpecific() {
        XCTAssertEqual(
            CaptureOnceFailure.permissionRequired.userMessage,
            "Allow Screen Recording and Accessibility in Permissions & Privacy, then try again."
        )
        XCTAssertEqual(
            CaptureOnceFailure.lowDiskSpace.userMessage,
            "Free up storage on this Mac, then retry the capture."
        )
        XCTAssertEqual(
            CaptureOnceFailure.privateBrowsing.userMessage,
            "Leave the private window or tab, then try again."
        )
        XCTAssertTrue(
            CaptureOnceFailure.browserAddressUnavailable.userMessage.contains(
                "Accessibility"
            )
        )
    }

    func testUnexpectedFailureUsesTruthfulGenericCopy() {
        XCTAssertEqual(CaptureOnceFailure.captureFailed.userTitle, "Capture couldn't be saved")
        XCTAssertEqual(
            CaptureOnceFailure.captureFailed.userMessage,
            "Screenlogger couldn't save this capture. Your existing Library remains available. Try again."
        )
    }
}
