// Model-specific implementation of Gemma4 vision / EmbeddingGemma2 projection.
// Reference: Hugging Face Transformers 637b76e40bac9398965086863a818f2dd1e7bfd1,
// modeling_gemma4.py (Copyright 2026 HuggingFace Team, Apache-2.0).
import Foundation
import MLX
import MLXNN

final class EmbeddingVisionModel {
    private let precision: DType
    private let patchProjection: EmbeddingLinear
    private let positionTable: MLXArray
    private let projection: EmbeddingLinear
    private let layers: [Layer]

    // Gemma4 uses direct learned RMS scales, not Gemma's (1 + weight).
    static func normalized(_ input: MLXArray, weight: MLXArray? = nil) -> MLXArray {
        let x = input.asType(.float32)
        var result = x * pow((x * x).mean(axis: -1, keepDims: true) + 1e-6, -0.5)
        if let weight { result = result * weight }
        return result.asType(input.dtype)
    }

    private struct Layer {
        let query: EmbeddingLinear
        let key: EmbeddingLinear
        let value: EmbeddingLinear
        let output: EmbeddingLinear
        let gate: EmbeddingLinear
        let up: EmbeddingLinear
        let down: EmbeddingLinear
        let inputNorm: MLXArray
        let attentionNorm: MLXArray
        let feedForwardNorm: MLXArray
        let outputNorm: MLXArray
        let queryNorm: MLXArray
        let keyNorm: MLXArray

        init(weights: EmbeddingWeights, index: Int) throws {
            let prefix = "vision_tower.encoder.layers.\(index)."
            query = try weights.linear(prefix + "self_attn.q_proj.linear.weight", shape: [768, 768])
            key = try weights.linear(prefix + "self_attn.k_proj.linear.weight", shape: [768, 768])
            value = try weights.linear(prefix + "self_attn.v_proj.linear.weight", shape: [768, 768])
            output = try weights.linear(prefix + "self_attn.o_proj.linear.weight", shape: [768, 768])
            gate = try weights.linear(prefix + "mlp.gate_proj.linear.weight", shape: [3072, 768])
            up = try weights.linear(prefix + "mlp.up_proj.linear.weight", shape: [3072, 768])
            down = try weights.linear(prefix + "mlp.down_proj.linear.weight", shape: [768, 3072])
            inputNorm = try weights.tensor(prefix + "input_layernorm.weight", shape: [768], precision: .float32)
            attentionNorm = try weights.tensor(prefix + "post_attention_layernorm.weight", shape: [768], precision: .float32)
            feedForwardNorm = try weights.tensor(prefix + "pre_feedforward_layernorm.weight", shape: [768], precision: .float32)
            outputNorm = try weights.tensor(prefix + "post_feedforward_layernorm.weight", shape: [768], precision: .float32)
            queryNorm = try weights.tensor(prefix + "self_attn.q_norm.weight", shape: [64], precision: .float32)
            keyNorm = try weights.tensor(prefix + "self_attn.k_norm.weight", shape: [64], precision: .float32)
        }

        func callAsFunction(_ input: MLXArray, cosine: MLXArray, sine: MLXArray) -> MLXArray {
            let count = input.dim(0)
            let x = EmbeddingVisionModel.normalized(input, weight: inputNorm)
            let q = EmbeddingVisionModel.normalized(query(x).reshaped([count, 12, 64]), weight: queryNorm)
            let k = EmbeddingVisionModel.normalized(key(x).reshaped([count, 12, 64]), weight: keyNorm)
            let v = EmbeddingVisionModel.normalized(value(x).reshaped([count, 12, 64]))
            let rotatedQ = EmbeddingVisionModel.rotated(q, cosine: cosine, sine: sine)
            let rotatedK = EmbeddingVisionModel.rotated(k, cosine: cosine, sine: sine)
            // No padding or causal mask: every patch in a singleton image is valid.
            let attended = MLXFast.scaledDotProductAttention(
                queries: rotatedQ.transposed(1, 0, 2).expandedDimensions(axis: 0),
                keys: rotatedK.transposed(1, 0, 2).expandedDimensions(axis: 0),
                values: v.transposed(1, 0, 2).expandedDimensions(axis: 0),
                scale: 1, mask: nil
            )
            .reshaped([12, count, 64]).transposed(1, 0, 2).reshaped([count, 768])
            let residual = input + EmbeddingVisionModel.normalized(output(attended), weight: attentionNorm)
            let ff = EmbeddingVisionModel.normalized(residual, weight: feedForwardNorm)
            return residual + EmbeddingVisionModel.normalized(down(geluApproximate(gate(ff)) * up(ff)), weight: outputNorm)
        }
    }

    init(directory: URL, precision: DType = .bfloat16) throws {
        guard precision == .bfloat16 || precision == .float32 else {
            throw EmbeddingModelError.invalid("Unsupported vision precision")
        }
        let object: [String: Any]
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EmbeddingModelError.invalid("Invalid vision configuration")
            }
            object = decoded
        } catch {
            throw EmbeddingModelError.invalid("Cannot read vision configuration")
        }
        guard object["model_type"] as? String == "embedding_gemma2",
            let config = object["vision_config"] as? [String: Any],
            let text = object["text_config"] as? [String: Any],
            text["hidden_size"] as? Int == 512,
            config["model_type"] as? String == "gemma4_vision",
            config["hidden_activation"] as? String == "gelu_pytorch_tanh",
            config["standardize"] as? Bool == false,
            config["use_clipped_linears"] as? Bool == false,
            config["attention_bias"] as? Bool == false,
            config["attention_dropout"] as? Double == 0,
            config["rms_norm_eps"] as? Double == 1e-6,
            let rope = config["rope_parameters"] as? [String: Any],
            rope["rope_type"] as? String == "axial", rope["rope_theta"] as? Double == 100
        else {
            throw EmbeddingModelError.invalid("Unsupported vision architecture")
        }
        let required = [
            "hidden_size": 768, "intermediate_size": 3072, "num_hidden_layers": 16,
            "num_attention_heads": 12, "num_key_value_heads": 12, "head_dim": 64,
            "patch_size": 16, "pooling_kernel_size": 3, "position_embedding_size": 10240,
        ]
        guard required.allSatisfy({ config[$0.key] as? Int == $0.value }),
            config["layer_types"] == nil, config["output_proj_dims"] == nil
        else {
            throw EmbeddingModelError.invalid("Unsupported vision dimensions")
        }
        self.precision = precision
        let weights = try EmbeddingWeights(directory: directory, filename: "vision.safetensors", precision: precision)
        patchProjection = try weights.linear("vision_tower.patch_embedder.input_proj.weight", shape: [768, 768])
        positionTable = try weights.tensor("vision_tower.patch_embedder.position_embedding_table", shape: [2, 10240, 768])
        projection = try weights.linear("embed_vision.embedding_projection.weight", shape: [512, 768])
        layers = try (0..<16).map { try Layer(weights: weights, index: $0) }
        try weights.validateComplete()
    }

    // Axis halves rotate independently: [x0..15,x16..31,y0..15,y16..31].
    static func rotated(_ input: MLXArray, cosine: MLXArray, sine: MLXArray) -> MLXArray {
        let quarters = split(input, parts: 4, axis: -1)
        let perpendicular = concatenated([-quarters[1], quarters[0], -quarters[3], quarters[2]], axis: -1)
        return input * cosine + perpendicular * sine
    }

    static func pooled(_ input: MLXArray, patchWidth: Int, patchHeight: Int) -> MLXArray {
        // The reference casts the FP32 spatial average back before sqrt(H) scaling.
        let average = input.asType(.float32)
            .reshaped([patchHeight / 3, 3, patchWidth / 3, 3, 768])
            .mean(axes: [1, 3]).reshaped([-1, 768]).asType(input.dtype)
        return (average.asType(.float32) * sqrt(Float(768))).asType(input.dtype)
    }

    func encode(_ image: EmbeddingPreparedImage) throws -> MLXArray {
        guard image.width > 0, image.height > 0, image.width % 48 == 0, image.height % 48 == 0,
            image.width <= 1120 * 48, image.height <= 1120 * 48,
            image.patchCount <= 1120 * 9,
            image.pixels.count == image.patchCount * 768,
            image.positions.count == image.patchCount * 2,
            image.pixels.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else {
            throw EmbeddingModelError.invalid("Invalid prepared image")
        }
        let width = image.width / 16
        let height = image.height / 16
        var xPositions = [Int32]()
        var yPositions = [Int32]()
        xPositions.reserveCapacity(image.patchCount)
        yPositions.reserveCapacity(image.patchCount)
        for i in 0..<image.patchCount {
            let x = Int32(i % width)
            let y = Int32(i / width)
            guard image.positions[2 * i] == x, image.positions[2 * i + 1] == y else {
                throw EmbeddingModelError.invalid("Invalid image patch order")
            }
            xPositions.append(x)
            yPositions.append(y)
        }
        let xIDs = MLXArray(xPositions)
        let yIDs = MLXArray(yPositions)
        let pixels = MLXArray(image.pixels).reshaped([image.patchCount, 768])
        var hidden = patchProjection((2 * (pixels - 0.5)).asType(precision))
        hidden = hidden + (positionTable[0].take(xIDs, axis: 0) + positionTable[1].take(yIDs, axis: 0))
        let frequencies = MLXArray((0..<16).map { Float(pow(100.0, -Double(2 * $0) / 32)) })
        let xAngles = xIDs.asType(.float32).expandedDimensions(axis: -1) * frequencies
        let yAngles = yIDs.asType(.float32).expandedDimensions(axis: -1) * frequencies
        let angles = concatenated([xAngles, xAngles, yAngles, yAngles], axis: -1)
        let cosine = cos(angles).asType(precision).expandedDimensions(axis: 1)
        let sine = sin(angles).asType(precision).expandedDimensions(axis: 1)
        for layer in layers { hidden = layer(hidden, cosine: cosine, sine: sine) }
        return projection(Self.normalized(Self.pooled(hidden, patchWidth: width, patchHeight: height)))
    }
}
