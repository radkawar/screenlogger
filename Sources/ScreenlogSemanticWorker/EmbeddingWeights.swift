import Foundation
import MLX

// Native model-specific storage; affine q8 tensors stay packed for their entire lifetime.
// Packed row gathering follows MLX Swift 0.32.3 QuantizedEmbedding
// (Copyright 2024 Apple Inc., MIT); model storage and validation are owned here.
enum EmbeddingModelError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

private enum EmbeddingMatrix {
    case dense(MLXArray)
    case affine8(weight: MLXArray, scales: MLXArray, biases: MLXArray)
}

struct EmbeddingLinear {
    fileprivate let matrix: EmbeddingMatrix

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        switch matrix {
        case .dense(let weight):
            return matmul(input, weight.T)
        case .affine8(let weight, let scales, let biases):
            return quantizedMM(
                input, weight, scales: scales, biases: biases,
                transpose: true, groupSize: 64, bits: 8, mode: .affine)
        }
    }
}

struct EmbeddingLookup {
    fileprivate let matrix: EmbeddingMatrix

    func callAsFunction(_ ids: MLXArray) -> MLXArray {
        switch matrix {
        case .dense(let weight):
            return weight[ids]
        case .affine8(let weight, let scales, let biases):
            // Gather packed rows BEFORE dequantization: never expand the vocabulary matrix.
            let rows = ids.flattened()
            return dequantized(
                weight[rows], scales: scales[rows], biases: biases[rows],
                groupSize: 64, bits: 8, mode: .affine
            )
            .reshaped(ids.shape + [-1])
        }
    }
}

final class EmbeddingWeights {
    private struct Quantization: Decodable {
        let version: Int
        let bits: Int
        let groupSize: Int
        let mode: String
        let shapes: [String: [Int]]
    }

    private let arrays: [String: MLXArray]
    private let shapes: [String: [Int]]
    private let precision: DType
    private var consumed = Set<String>()
    private var consumedQuantization = Set<String>()

    init(
        directory: URL, filename: String, namespace: String? = nil,
        precision: DType = .bfloat16
    ) throws {
        guard precision == .bfloat16 || precision == .float32 else {
            throw EmbeddingModelError.invalid("Embedding inference requires BF16 or FP32.")
        }
        self.precision = precision
        func stripModel(_ name: String) -> String {
            name.hasPrefix("model.") ? String(name.dropFirst(6)) : name
        }
        var selected = [String: MLXArray]()
        let loaded: [String: MLXArray]
        do {
            loaded = try loadArrays(url: directory.appendingPathComponent(filename))
        } catch {
            throw EmbeddingModelError.invalid("Unable to load embedding weight tensors.")
        }
        for (rawName, array) in loaded {
            var name = stripModel(rawName)
            if let namespace {
                guard name.hasPrefix(namespace) else { continue }
                name = String(name.dropFirst(namespace.count))
            }
            guard !name.isEmpty, selected.updateValue(array, forKey: name) == nil else {
                throw EmbeddingModelError.invalid("Duplicate embedding weight name.")
            }
        }
        guard !selected.isEmpty else {
            throw EmbeddingModelError.invalid("No matching embedding weights.")
        }
        self.arrays = selected
        var normalizedShapes = [String: [Int]]()
        let metadataURL = directory.appendingPathComponent("quantization.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let metadata: Quantization
            do {
                metadata = try JSONDecoder().decode(Quantization.self, from: Data(contentsOf: metadataURL))
            } catch {
                throw EmbeddingModelError.invalid("Invalid embedding quantization metadata.")
            }
            guard metadata.version == 1, metadata.bits == 8,
                metadata.groupSize == 64, metadata.mode == "affine"
            else {
                throw EmbeddingModelError.invalid("Only affine q8 group-64 embedding weights are supported.")
            }
            for (rawName, shape) in metadata.shapes {
                var name = stripModel(rawName)
                if let namespace, name.hasPrefix(namespace) {
                    name = String(name.dropFirst(namespace.count))
                } else if namespace != nil,
                    ["language_model.", "vision_tower.", "embed_vision.", "audio_tower.", "embed_audio."]
                        .contains(where: { name.hasPrefix($0) })
                {
                    continue
                }
                guard shape.count == 2, shape.allSatisfy({ $0 > 0 }),
                    normalizedShapes.updateValue(shape, forKey: name) == nil
                else {
                    throw EmbeddingModelError.invalid("Invalid or duplicate embedding quantization shape.")
                }
            }
        }
        self.shapes = normalizedShapes
    }

    func linear(_ name: String, shape: [Int]) throws -> EmbeddingLinear {
        EmbeddingLinear(matrix: try matrix(name, shape: shape))
    }

    func embedding(_ name: String, shape: [Int]) throws -> EmbeddingLookup {
        EmbeddingLookup(matrix: try matrix(name, shape: shape))
    }

    func tensor(_ name: String, shape: [Int], precision: DType? = nil) throws -> MLXArray {
        let target = precision ?? self.precision
        guard target == .bfloat16 || target == .float32, shapes[name] == nil else {
            throw EmbeddingModelError.invalid("Invalid embedding tensor precision or quantization.")
        }
        let array = try take(name, shape: shape)
        guard array.dtype == .bfloat16 || array.dtype == .float32 else {
            throw EmbeddingModelError.invalid("Embedding tensor must use BF16 or FP32: \(name).")
        }
        return array.asType(target)
    }

    func validateComplete() throws {
        guard consumed == Set(arrays.keys), consumedQuantization == Set(shapes.keys) else {
            throw EmbeddingModelError.invalid("Unexpected or unused embedding weight or quantization entry.")
        }
    }

    private func take(_ name: String, shape: [Int]) throws -> MLXArray {
        guard shape.allSatisfy({ $0 > 0 }), let array = arrays[name], array.shape == shape,
            consumed.insert(name).inserted
        else {
            throw EmbeddingModelError.invalid("Missing, duplicate, or incorrectly shaped embedding tensor: \(name).")
        }
        return array
    }

    private func matrix(_ name: String, shape: [Int]) throws -> EmbeddingMatrix {
        guard shape.count == 2, shape.allSatisfy({ $0 > 0 }) else {
            throw EmbeddingModelError.invalid("Embedding matrices require two positive dimensions.")
        }
        guard let quantizedShape = shapes[name] else {
            return .dense(try tensor(name, shape: shape))
        }
        guard quantizedShape == shape, shape[1] % 64 == 0,
            consumedQuantization.insert(name).inserted
        else {
            throw EmbeddingModelError.invalid("Embedding q8 matrix shape mismatch: \(name).")
        }
        let packed = try take(name, shape: [shape[0], shape[1] / 4])
        let groupShape = [shape[0], shape[1] / 64]
        let scales = try take(name + ".scales", shape: groupShape)
        let biases = try take(name + ".biases", shape: groupShape)
        guard packed.dtype == .uint32,
            scales.dtype == .bfloat16 || scales.dtype == .float32,
            biases.dtype == scales.dtype
        else {
            throw EmbeddingModelError.invalid("Invalid packed q8 embedding tensor precision: \(name).")
        }
        return .affine8(weight: packed, scales: scales.asType(precision), biases: biases.asType(precision))
    }
}
