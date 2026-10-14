import Foundation
import MLX
import XCTest

final class EmbeddingVisionTests: XCTestCase {
    func testGeometryPreservesBudgetAndPoolingGridForExtremeAspectRatios() throws {
        for (width, height) in [(1, 2048), (2048, 1), (1920, 1080), (1080, 1920), (1, 1)] {
            for budget in [70, 140, 280, 560, 1120] {
                let size = try EmbeddingImageProcessor.targetSize(width: width, height: height, maxSoftTokens: budget)
                XCTAssertEqual(size.width % 48, 0)
                XCTAssertEqual(size.height % 48, 0)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertLessThanOrEqual(size.width * size.height / (48 * 48), budget)
                let rotated = try EmbeddingImageProcessor.targetSize(width: height, height: width, maxSoftTokens: budget)
                XCTAssertEqual(size.width, rotated.height)
                XCTAssertEqual(size.height, rotated.width)
            }
        }
        XCTAssertThrowsError(try EmbeddingImageProcessor.targetSize(width: 0, height: 10, maxSoftTokens: 280))
        XCTAssertThrowsError(try EmbeddingImageProcessor.targetSize(width: 10, height: 10, maxSoftTokens: 281))
        XCTAssertThrowsError(try EmbeddingImageProcessor.prepare(rgb: Data(), width: 1, height: 1))
    }

    func testPatchOrderingAndRGBRescalingWithoutResize() throws {
        let side = 384
        var bytes = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                bytes[(y * side + x) * 3] = UInt8(x % 256)
                bytes[(y * side + x) * 3 + 1] = UInt8(y % 256)
                bytes[(y * side + x) * 3 + 2] = 255
            }
        }
        let image = try EmbeddingImageProcessor.prepare(rgb: Data(bytes), width: side, height: side, maxSoftTokens: 70)
        XCTAssertEqual(image.width, side)
        XCTAssertEqual(image.height, side)
        XCTAssertEqual(image.softTokenCount, 64)
        for patch in [0, 1, 23, 24, 575] {
            XCTAssertEqual(image.positions[patch * 2], Int32(patch % 24))
            XCTAssertEqual(image.positions[patch * 2 + 1], Int32(patch / 24))
            for pixel in [0, 15, 16, 255] {
                let x = (patch % 24) * 16 + pixel % 16
                let y = (patch / 24) * 16 + pixel / 16
                let offset = (patch * 256 + pixel) * 3
                XCTAssertEqual(image.pixels[offset], Float(x % 256) / 255, accuracy: 1e-7)
                XCTAssertEqual(image.pixels[offset + 1], Float(y % 256) / 255, accuracy: 1e-7)
                XCTAssertEqual(image.pixels[offset + 2], 1)
            }
        }
    }

    func testAntialiasedResizePreservesConstantChannels() throws {
        let rgb = Data((0..<(97 * 53)).flatMap { _ in [UInt8(17), 128, 249] })
        let image = try EmbeddingImageProcessor.prepare(rgb: rgb, width: 97, height: 53, maxSoftTokens: 70)
        for i in stride(from: 0, to: image.pixels.count, by: 3) {
            XCTAssertEqual(image.pixels[i], Float(17) / 255, accuracy: 1e-7)
            XCTAssertEqual(image.pixels[i + 1], Float(128) / 255, accuracy: 1e-7)
            XCTAssertEqual(image.pixels[i + 2], Float(249) / 255, accuracy: 1e-7)
        }
    }

    func testAxialRotationNeverMixesSpatialAxes() {
        let input = MLXArray((0..<64).map(Float.init)).reshaped([1, 1, 64])
        let rotated = EmbeddingVisionModel.rotated(input, cosine: MLXArray.zeros([1, 1, 64]), sine: MLXArray.ones([1, 1, 64]))
        let expected =
            (16..<32).map { -Float($0) } + (0..<16).map(Float.init)
            + (48..<64).map { -Float($0) } + (32..<48).map(Float.init)
        XCTAssertEqual(rotated.asArray(Float.self), expected)
    }

    func testPoolingUsesSpatialBlocksAndFloatAccumulation() {
        // Two adjacent 3x3 blocks, not two consecutive runs of nine patches.
        let values = (0..<18).flatMap { index in
            [Float](repeating: index % 6 < 3 ? 100_000 : 200_000, count: 768)
        }
        let input = MLXArray(values).reshaped([18, 768]).asType(.bfloat16)
        let result = EmbeddingVisionModel.pooled(input, patchWidth: 6, patchHeight: 3)
        let expected =
            (MLXArray([Float(100_000), 200_000]).asType(.bfloat16).asType(.float32)
            * sqrt(Float(768))).asType(.bfloat16).asType(.float32).asArray(Float.self)
        let output = result.asType(.float32).asArray(Float.self)
        XCTAssertEqual(result.shape, [2, 768])
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertEqual(output[0], expected[0])
        XCTAssertEqual(output[768], expected[1])
    }
}
