import Foundation
import MLX
import MLXNN

// Architecture reimplemented from Hugging Face Transformers' EmbeddingGemma2
// (637b76e40bac9398965086863a818f2dd1e7bfd1), Copyright 2026 HuggingFace Team,
// Apache-2.0. Google checkpoint: 914f7f89142e33e77833254d9c9b90c3cef7303b.
// This owns inference, not a wrapper around a third-party model implementation.
private struct EmbeddingTextConfiguration: Decodable {
    struct Text: Decodable {
        struct Override: Decodable {
            let head_dim: Int
            let num_key_value_heads: Int
        }
        struct Rope: Decodable {
            let rope_theta: Float
            let rope_type: String
        }
        let model_type: String
        let dtype: String
        let hidden_size: Int
        let hidden_size_per_layer_input: Int
        let intermediate_size: Int
        let embedding_dim: Int
        let vocab_size: Int
        let num_hidden_layers: Int
        let num_attention_heads: Int
        let num_key_value_heads: Int
        let head_dim: Int
        let rms_norm_eps: Float
        let sliding_window: Int
        let max_position_embeddings: Int
        let attention_bias: Bool
        let attention_dropout: Float
        let hidden_activation: String
        let pad_token_id: Int
        let layer_types: [String]
        let per_layer_config: [String: Override]
        let rope_parameters: [String: Rope]
    }
    let model_type: String
    let text_config: Text
    let image_token_id: Int
    let audio_token_id: Int
    let video_token_id: Int
    let boi_token_id: Int
    let eoi_token_id: Int
    let boa_token_id: Int
    let eoa_token_index: Int

    func validate() throws {
        let t = text_config
        guard model_type == "embedding_gemma2", t.model_type == "embedding_gemma2_text",
            ["bfloat16", "float32"].contains(t.dtype),
            t.hidden_size == 512, t.hidden_size_per_layer_input == 512,
            t.intermediate_size == 2048, t.embedding_dim == 768, t.vocab_size == 262144,
            t.num_hidden_layers == 24, t.num_attention_heads == 4,
            t.num_key_value_heads == 2, t.head_dim == 256,
            t.rms_norm_eps == 1e-6, t.sliding_window == 512,
            t.max_position_embeddings == 262144,
            !t.attention_bias, t.attention_dropout == 0,
            t.hidden_activation == "gelu_pytorch_tanh", t.pad_token_id == 0,
            t.layer_types == (0..<24).map({ $0 % 6 == 5 ? "full_attention" : "sliding_attention" }),
            Set(t.per_layer_config.keys) == Set(["05", "11", "17", "23"]),
            t.per_layer_config.values.allSatisfy({ $0.head_dim == 512 && $0.num_key_value_heads == 1 }),
            Set(t.rope_parameters.keys) == Set(["full_attention", "sliding_attention"]),
            t.rope_parameters.values.allSatisfy({ $0.rope_type == "default" }),
            t.rope_parameters["full_attention"]?.rope_theta == 1_000_000,
            t.rope_parameters["sliding_attention"]?.rope_theta == 10_000,
            image_token_id == 258880, audio_token_id == 258881, video_token_id == 258884,
            boi_token_id == 255999, eoi_token_id == 258882,
            boa_token_id == 256000, eoa_token_index == 258883
        else {
            throw EmbeddingModelError.invalid("Unsupported EmbeddingGemma 2 text configuration.")
        }
    }
}

private struct EmbeddingTextNorm {
    let weight: MLXArray
    let epsilon: Float

    init(_ weights: EmbeddingWeights, _ name: String, width: Int, epsilon: Float) throws {
        weight = try weights.tensor(name, shape: [width], precision: .float32)
        self.epsilon = epsilon
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        (Self.normalizedFloat(input, epsilon: epsilon) * weight).asType(input.dtype)
    }

    static func normalizedFloat(_ input: MLXArray, epsilon: Float) -> MLXArray {
        let x = input.asType(.float32)
        // The primary reference explicitly uses pow(-0.5), with FP32 accumulation.
        return x * pow((x * x).mean(axis: -1, keepDims: true) + epsilon, -0.5)
    }
}

private struct EmbeddingTextRotary {
    let inverseFrequencies: MLXArray

    init(width: Int, base: Float) {
        inverseFrequencies = 1 / pow(base, MLXArray(stride(from: 0, to: width, by: 2)).asType(.float32) / Float(width))
    }

    func angles(length: Int, precision: DType) -> (cos: MLXArray, sin: MLXArray) {
        let positions = MLXArray(0..<length).asType(.float32).reshaped([length, 1])
        let frequencies = positions * inverseFrequencies
        let doubled = concatenated([frequencies, frequencies], axis: -1).expandedDimensions(axes: [0, 1])
        return (MLX.cos(doubled).asType(precision), MLX.sin(doubled).asType(precision))
    }

    static func apply(_ x: MLXArray, angles: (cos: MLXArray, sin: MLXArray)) -> MLXArray {
        let half = x.dim(-1) / 2
        let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
        return x * angles.cos + rotated * angles.sin
    }
}

private struct EmbeddingTextLayer {
    let fullAttention: Bool
    let headDimension: Int
    let keyValueHeads: Int
    let epsilon: Float
    let query: EmbeddingLinear
    let key: EmbeddingLinear
    let value: EmbeddingLinear
    let attentionOutput: EmbeddingLinear
    let gate: EmbeddingLinear
    let up: EmbeddingLinear
    let down: EmbeddingLinear
    let perLayerGate: EmbeddingLinear
    let perLayerProjection: EmbeddingLinear
    let inputNorm: EmbeddingTextNorm
    let queryNorm: EmbeddingTextNorm
    let keyNorm: EmbeddingTextNorm
    let attentionNorm: EmbeddingTextNorm
    let feedforwardInputNorm: EmbeddingTextNorm
    let feedforwardOutputNorm: EmbeddingTextNorm
    let perLayerOutputNorm: EmbeddingTextNorm
    let scalar: MLXArray

    init(weights: EmbeddingWeights, index: Int, epsilon: Float) throws {
        let prefix = "layers.\(index)."
        fullAttention = index % 6 == 5
        headDimension = fullAttention ? 512 : 256
        keyValueHeads = fullAttention ? 1 : 2
        self.epsilon = epsilon
        query = try weights.linear(prefix + "self_attn.q_proj.weight", shape: [4 * headDimension, 512])
        key = try weights.linear(prefix + "self_attn.k_proj.weight", shape: [keyValueHeads * headDimension, 512])
        value = try weights.linear(prefix + "self_attn.v_proj.weight", shape: [keyValueHeads * headDimension, 512])
        attentionOutput = try weights.linear(prefix + "self_attn.o_proj.weight", shape: [512, 4 * headDimension])
        gate = try weights.linear(prefix + "mlp.gate_proj.weight", shape: [2048, 512])
        up = try weights.linear(prefix + "mlp.up_proj.weight", shape: [2048, 512])
        down = try weights.linear(prefix + "mlp.down_proj.weight", shape: [512, 2048])
        perLayerGate = try weights.linear(prefix + "ple_block.per_layer_input_gate.weight", shape: [512, 512])
        perLayerProjection = try weights.linear(prefix + "ple_block.per_layer_projection.weight", shape: [512, 512])
        inputNorm = try EmbeddingTextNorm(weights, prefix + "input_layernorm.weight", width: 512, epsilon: epsilon)
        queryNorm = try EmbeddingTextNorm(weights, prefix + "self_attn.q_norm.weight", width: headDimension, epsilon: epsilon)
        keyNorm = try EmbeddingTextNorm(weights, prefix + "self_attn.k_norm.weight", width: headDimension, epsilon: epsilon)
        attentionNorm = try EmbeddingTextNorm(weights, prefix + "post_attention_layernorm.weight", width: 512, epsilon: epsilon)
        feedforwardInputNorm = try EmbeddingTextNorm(weights, prefix + "pre_feedforward_layernorm.weight", width: 512, epsilon: epsilon)
        feedforwardOutputNorm = try EmbeddingTextNorm(weights, prefix + "post_feedforward_layernorm.weight", width: 512, epsilon: epsilon)
        perLayerOutputNorm = try EmbeddingTextNorm(
            weights, prefix + "ple_block.post_per_layer_input_norm.weight", width: 512, epsilon: epsilon)
        scalar = try weights.tensor(prefix + "layer_scalar", shape: [1])
    }

    func callAsFunction(
        _ input: MLXArray, perLayerInput: MLXArray,
        angles: (cos: MLXArray, sin: MLXArray), mask: MLXArray?
    ) -> MLXArray {
        let length = input.dim(0)
        let normalized = inputNorm(input)
        let q = queryNorm(query(normalized).reshaped([1, length, 4, headDimension])).transposed(0, 2, 1, 3)
        let k = keyNorm(key(normalized).reshaped([1, length, keyValueHeads, headDimension])).transposed(0, 2, 1, 3)
        let rawValues = value(normalized).reshaped([1, length, keyValueHeads, headDimension])
        let v = EmbeddingTextNorm.normalizedFloat(rawValues, epsilon: epsilon)
            .asType(rawValues.dtype).transposed(0, 2, 1, 3)
        // Q/K RMS scales replace the usual inverse-square-root head scaling.
        let attended = MLXFast.scaledDotProductAttention(
            queries: EmbeddingTextRotary.apply(q, angles: angles),
            keys: EmbeddingTextRotary.apply(k, angles: angles), values: v, scale: 1, mask: mask
        )
        .transposed(0, 2, 1, 3).reshaped([length, 4 * headDimension])
        let afterAttention = input + attentionNorm(attentionOutput(attended))
        let feedforwardInput = feedforwardInputNorm(afterAttention)
        let afterFeedforward =
            afterAttention
            + feedforwardOutputNorm(
                down(geluApproximate(gate(feedforwardInput)) * up(feedforwardInput)))
        let perLayer = perLayerProjection(geluApproximate(perLayerGate(afterFeedforward)) * perLayerInput)
        return (afterFeedforward + perLayerOutputNorm(perLayer)) * scalar
    }
}

final class EmbeddingTextModel {
    let vocabularySize: Int
    let imageTokenID: Int
    private let configuration: EmbeddingTextConfiguration
    private let precision: DType
    private let tokenEmbedding: EmbeddingLookup
    private let embeddingScale: MLXArray
    private let perLayerScale: MLXArray
    private let perLayerProjection: EmbeddingLinear
    private let perLayerNorm: EmbeddingTextNorm
    private let finalNorm: EmbeddingTextNorm
    private let outputProjection: EmbeddingLinear
    private let layers: [EmbeddingTextLayer]
    private let localRotary: EmbeddingTextRotary
    private let globalRotary: EmbeddingTextRotary

    init(directory: URL, precision: DType = .bfloat16) throws {
        guard precision == .bfloat16 || precision == .float32 else {
            throw EmbeddingModelError.invalid("Embedding inference requires BF16 or FP32.")
        }
        let config: EmbeddingTextConfiguration
        do {
            config = try JSONDecoder().decode(
                EmbeddingTextConfiguration.self,
                from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        } catch {
            throw EmbeddingModelError.invalid("Invalid embedding text configuration.")
        }
        try config.validate()
        configuration = config
        self.precision = precision
        vocabularySize = config.text_config.vocab_size
        imageTokenID = config.image_token_id
        let weights = try EmbeddingWeights(
            directory: directory, filename: "model.safetensors",
            namespace: "language_model.", precision: precision)
        let epsilon = config.text_config.rms_norm_eps
        tokenEmbedding = try weights.embedding("embed_tokens.weight", shape: [vocabularySize, 512])
        embeddingScale = MLXArray(Float(512).squareRoot()).asType(precision)
        perLayerScale = MLXArray(1 / Float(512).squareRoot()).asType(precision)
        perLayerProjection = try weights.linear("ple.per_layer_model_projection.weight", shape: [24 * 512, 512])
        perLayerNorm = try EmbeddingTextNorm(weights, "ple.per_layer_projection_norm.weight", width: 512, epsilon: epsilon)
        finalNorm = try EmbeddingTextNorm(weights, "norm.weight", width: 512, epsilon: epsilon)
        outputProjection = try weights.linear("embedding_projection.weight", shape: [768, 512])
        layers = try (0..<24).map { try EmbeddingTextLayer(weights: weights, index: $0, epsilon: epsilon) }
        localRotary = EmbeddingTextRotary(width: 256, base: 10_000)
        globalRotary = EmbeddingTextRotary(width: 512, base: 1_000_000)
        try weights.validateComplete()
    }

    func embed(tokenIDs: [Int], imageFeatures: MLXArray? = nil) throws -> [Float] {
        guard !tokenIDs.isEmpty, tokenIDs.count <= 8192,
            tokenIDs.allSatisfy({ $0 >= 0 && $0 < vocabularySize && $0 != configuration.text_config.pad_token_id }),
            !tokenIDs.contains(configuration.audio_token_id), !tokenIDs.contains(configuration.video_token_id),
            !tokenIDs.contains(configuration.boa_token_id), !tokenIDs.contains(configuration.eoa_token_index)
        else {
            throw EmbeddingModelError.invalid("Invalid or unsupported embedding input tokens.")
        }
        let imagePositions = tokenIDs.indices.filter { tokenIDs[$0] == imageTokenID }
        if let features = imageFeatures {
            guard !imagePositions.isEmpty, features.shape == [imagePositions.count, 512],
                features.dtype == precision, isFinite(features).all().item(Bool.self)
            else {
                throw EmbeddingModelError.invalid("Image feature count, shape, precision, or values do not match text placeholders.")
            }
        } else if !imagePositions.isEmpty || tokenIDs.contains(configuration.boi_token_id)
            || tokenIDs.contains(configuration.eoi_token_id)
        {
            throw EmbeddingModelError.invalid("Image tokens require image features.")
        }
        let ids = MLXArray(tokenIDs.map { Int32($0 == imageTokenID ? configuration.text_config.pad_token_id : $0) })
        var hidden = tokenEmbedding(ids) * embeddingScale
        if let imageFeatures {
            // Already projected into text space by the vision encoder: do NOT scale again.
            hidden[MLXArray(imagePositions.map(Int32.init))] = imageFeatures
        }
        let length = tokenIDs.count
        // Projection-only PLE must be derived once from the original merged inputs,
        // not from the evolving residual stream and not from token identities.
        let perLayerInputs = perLayerNorm((perLayerProjection(hidden) * perLayerScale).reshaped([length, 24, 512]))
        let localAngles = localRotary.angles(length: length, precision: precision)
        let globalAngles = globalRotary.angles(length: length, precision: precision)
        let localMask: MLXArray?
        if length > configuration.text_config.sliding_window + 1 {
            let positions = MLXArray(0..<length)
            localMask = lessEqual(
                abs(positions.expandedDimensions(axis: 0) - positions.expandedDimensions(axis: 1)),
                configuration.text_config.sliding_window)
        } else {
            localMask = nil
        }
        for (index, layer) in layers.enumerated() {
            hidden = layer(
                hidden, perLayerInput: perLayerInputs[0..., index, 0...],
                angles: layer.fullAttention ? globalAngles : localAngles,
                mask: layer.fullAttention ? nil : localMask)
        }
        // Match the primary reference's per-token projection BEFORE mean pooling.
        // SentenceTransformers af42679b98dee46267af508551b9d8d54ec3b2ab
        // accumulates the mean in FP32, then returns the input dtype to Normalize.
        let pooled = outputProjection(finalNorm(hidden)).asType(.float32).mean(axis: 0).asType(precision)
        let pooledFloat = pooled.asType(.float32)
        let norm = MLX.sqrt((pooledFloat * pooledFloat).sum()).asType(precision)
        let normalized = pooled / maximum(norm, MLXArray(Float(1e-12)).asType(precision))
        var vector = normalized.asType(.float32).asArray(Float.self)
        guard vector.count == 768, vector.allSatisfy(\.isFinite) else {
            throw EmbeddingModelError.invalid("Embedding inference produced nonfinite output.")
        }
        // BF16 division rounds the normalized coordinates. Re-unitize the public
        // FP32 vector without changing its direction, as required by cosine storage.
        let squaredNorm = vector.reduce(Float(0)) { $0 + $1 * $1 }
        guard squaredNorm.isFinite, squaredNorm > 0 else {
            throw EmbeddingModelError.invalid("Embedding inference produced an invalid norm.")
        }
        let inverseNorm = 1 / squaredNorm.squareRoot()
        for index in vector.indices { vector[index] *= inverseNorm }
        return vector
    }
}
