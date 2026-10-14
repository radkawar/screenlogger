import CoreGraphics
import ImageIO
@testable import ScreenlogCore
import XCTest

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
        XCTAssertEqual(encoded.pixelWidth, 2)
        XCTAssertEqual(encoded.pixelHeight, 2)
    }

    func testUltraCapturePreservesNativePixels() {
        let size = ScreenCaptureService.captureOutputSize(
            nativeWidth: 6_016,
            nativeHeight: 3_384,
            maxDimension: CaptureQualityPreset.nativeResolutionMaxDimension
        )
        XCTAssertEqual(size.width, 6_016)
        XCTAssertEqual(size.height, 3_384)
    }

    func testStandardAndHighCaptureMatchStoredResolution() {
        let displays = [
            (width: 6_016, height: 3_384),
            (width: 3_840, height: 2_160),
        ]

        let standardSizes = displays.map {
            ScreenCaptureService.captureOutputSize(
                nativeWidth: $0.width,
                nativeHeight: $0.height,
                maxDimension: CaptureQualityPreset.standard.maxDimension
            )
        }
        XCTAssertEqual(standardSizes.map(\.width), [1_920, 1_920])
        XCTAssertEqual(standardSizes.map(\.height), [1_080, 1_080])

        let storedSizes = displays.map {
            ScreenCaptureService.outputSize(
                nativeWidth: $0.width,
                nativeHeight: $0.height,
                maxDimension: 1_920
            )
        }
        XCTAssertEqual(storedSizes.map(\.width), standardSizes.map(\.width))
        XCTAssertEqual(storedSizes.map(\.height), standardSizes.map(\.height))
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

    func testStoredStillIsDownscaledAfterNativeImageProcessing() async throws {
        let width = 8
        let height = 4
        let bytes = [UInt8](repeating: 127, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let service = ScreenCaptureService()
        service.maxDimension = 4

        let encoded = try await service.encodeStill(image)

        XCTAssertEqual(encoded.pixelWidth, 4)
        XCTAssertEqual(encoded.pixelHeight, 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let storedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(storedImage.width, 4)
        XCTAssertEqual(storedImage.height, 2)
    }

    func testStoredImageResizePreservesOrientationAndDropsOpaqueAlphaChannel() throws {
        let width = 4
        let height = 4
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            let pixel: [UInt8] = row < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
            for _ in 0..<width {
                bytes.append(contentsOf: pixel)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )

        let resized = try ScreenCaptureService.imageForStorage(image, maxDimension: 2)
        let resizedData = try XCTUnwrap(resized.dataProvider?.data)
        let resizedBytes = try XCTUnwrap(CFDataGetBytePtr(resizedData))

        XCTAssertEqual(resized.width, 2)
        XCTAssertEqual(resized.height, 2)
        XCTAssertEqual(resized.alphaInfo, .noneSkipFirst)
        // The little-endian XRGB context is stored as BGRX bytes.
        XCTAssertGreaterThan(resizedBytes[2], resizedBytes[0], "The top row should remain red.")
        let bottomRow = resized.bytesPerRow
        XCTAssertGreaterThan(
            resizedBytes[bottomRow],
            resizedBytes[bottomRow + 2],
            "The bottom row should remain blue."
        )
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

}
