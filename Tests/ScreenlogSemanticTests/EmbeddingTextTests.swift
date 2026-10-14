import Foundation
import MLX
import XCTest

final class EmbeddingTextTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func metadata(_ shapes: [String: [Int]], at directory: URL, bits: Int = 8) throws {
        let object: [String: Any] = [
            "version": 1, "bits": bits, "groupSize": 64,
            "mode": "affine", "shapes": shapes,
        ]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent("quantization.json"))
    }

    func testPackedEmbeddingGathersRequestedRowsInOrderIncludingDuplicates() throws {
        let directory = try directory()
        // Each packed word is four independently stored unsigned q8 values.
        // Row r dequantizes to [1, 2, 3, 4] * (r + 1) - r, repeated 16 times.
        let words = MLXArray([UInt32](repeating: 0x0403_0201, count: 3 * 16), [3, 16])
        try MLX.save(
            arrays: [
                "model.language_model.embed_tokens.weight": words,
                "model.language_model.embed_tokens.weight.scales": MLXArray([Float(1), 2, 3], [3, 1]),
                "model.language_model.embed_tokens.weight.biases": MLXArray([Float(0), -1, -2], [3, 1]),
            ], url: directory.appendingPathComponent("model.safetensors"))
        try metadata(["embed_tokens.weight": [3, 64]], at: directory)
        let weights = try EmbeddingWeights(
            directory: directory, filename: "model.safetensors",
            namespace: "language_model.", precision: .float32)
        let lookup = try weights.embedding("embed_tokens.weight", shape: [3, 64])
        try weights.validateComplete()
        let result = lookup(MLXArray([Int32(2), 0, 2, 1], [2, 2]))
        XCTAssertEqual(result.shape, [2, 2, 64])
        let actual = result.asArray(Float.self)
        for (outputRow, sourceRow) in [2, 0, 2, 1].enumerated() {
            for column in 0..<64 {
                XCTAssertEqual(
                    actual[outputRow * 64 + column],
                    Float((column % 4 + 1) * (sourceRow + 1) - sourceRow), accuracy: 1e-6)
            }
        }
    }

    func testPackedLinearMatchesAffineDotProductsForBothAllowedPrecisions() throws {
        let directory = try directory()
        let values = (0..<(4 * 128)).map { Float(($0 * 17) % 79 - 39) / 16 }
        let dense = MLXArray(values, [4, 128])
        let (packed, scales, biases) = quantized(dense, groupSize: 64, bits: 8, mode: .affine)
        try MLX.save(
            arrays: [
                "projection.weight": packed,
                "projection.weight.scales": scales,
                "projection.weight.biases": try XCTUnwrap(biases),
            ],
            url: directory.appendingPathComponent("model.safetensors"))
        try metadata(["projection.weight": [4, 128]], at: directory)
        for precision: DType in [.float32, .bfloat16] {
            let weights = try EmbeddingWeights(directory: directory, filename: "model.safetensors", precision: precision)
            let linear = try weights.linear("projection.weight", shape: [4, 128])
            try weights.validateComplete()
            let input = MLXArray((0..<256).map { Float($0 % 13 - 6) / 8 }, [2, 128]).asType(precision)
            // A scalar FP64 oracle avoids reduced-precision GPU dense GEMM.
            // Keep q8 affine values in FP32, without an extra BF16 weight rounding.
            let unpacked = dequantized(
                packed, scales: scales.asType(precision).asType(.float32),
                biases: biases?.asType(precision).asType(.float32),
                groupSize: 64, bits: 8, mode: .affine
            ).asArray(Float.self)
            let inputs = input.asType(.float32).asArray(Float.self)
            var expected = [Float](repeating: 0, count: 8)
            for output in 0..<8 {
                let inputOffset = (output / 4) * 128
                let weightOffset = (output % 4) * 128
                var sum: Double = 0
                for column in 0..<128 {
                    sum += Double(inputs[inputOffset + column]) * Double(unpacked[weightOffset + column])
                }
                expected[output] = Float(sum)
            }
            let actual = linear(input).asType(.float32).asArray(Float.self)
            XCTAssertEqual(actual.count, expected.count)
            for (left, right) in zip(actual, expected) {
                XCTAssertEqual(left, right, accuracy: precision == .float32 ? 1e-4 : 0.125)
            }
        }
    }

    func testWeightLoaderRejectsFP16ShapeMetadataAndUnconsumedWeights() throws {
        let directory = try directory()
        try MLX.save(
            arrays: ["norm.weight": MLXArray.ones([4], dtype: .float16)],
            url: directory.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try EmbeddingWeights(directory: directory, filename: "model.safetensors", precision: .float16))
        let halfWeights = try EmbeddingWeights(directory: directory, filename: "model.safetensors")
        XCTAssertThrowsError(try halfWeights.tensor("norm.weight", shape: [4]))

        try MLX.save(
            arrays: [
                "norm.weight": MLXArray.ones([4], dtype: .bfloat16),
                "unexpected.weight": MLXArray.ones([1], dtype: .bfloat16),
            ],
            url: directory.appendingPathComponent("model.safetensors"))
        let extraWeights = try EmbeddingWeights(directory: directory, filename: "model.safetensors")
        XCTAssertThrowsError(try extraWeights.tensor("norm.weight", shape: [3]))
        _ = try extraWeights.tensor("norm.weight", shape: [4])
        XCTAssertThrowsError(try extraWeights.validateComplete())
        try metadata(["norm.weight": [4, 64]], at: directory, bits: 4)
        XCTAssertThrowsError(try EmbeddingWeights(directory: directory, filename: "model.safetensors"))
    }

    func testNormalizedNamespaceCollisionsAndOrphanQuantizationFailClosed() throws {
        let directory = try directory()
        try MLX.save(
            arrays: [
                "norm.weight": MLXArray.ones([4], dtype: .bfloat16),
                "model.norm.weight": MLXArray.ones([4], dtype: .bfloat16),
            ],
            url: directory.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try EmbeddingWeights(directory: directory, filename: "model.safetensors"))
        try MLX.save(
            arrays: ["norm.weight": MLXArray.ones([4], dtype: .bfloat16)],
            url: directory.appendingPathComponent("model.safetensors"))
        try metadata(["missing.weight": [4, 64]], at: directory)
        let weights = try EmbeddingWeights(directory: directory, filename: "model.safetensors")
        _ = try weights.tensor("norm.weight", shape: [4])
        XCTAssertThrowsError(try weights.validateComplete())
    }
}
