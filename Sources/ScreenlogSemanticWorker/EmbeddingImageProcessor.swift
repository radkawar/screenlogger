// Architecture: Hugging Face Transformers 637b76e40bac9398965086863a818f2dd1e7bfd1,
// Gemma4 image processor (Apache-2.0). RGB8 resampling arithmetic follows
// PyTorch v2.9.0 UpSampleKernel.cpp (BSD-3-Clause): Keys cubic, antialias,
// separable signed fixed-point coefficients and saturation after each pass.
import Foundation

struct EmbeddingPreparedImage {
    let pixels: [Float]
    let positions: [Int32]
    let width: Int
    let height: Int
    var patchCount: Int { (width / 16) * (height / 16) }
    var softTokenCount: Int { patchCount / 9 }
}

enum EmbeddingImageProcessor {
    static func targetSize(width: Int, height: Int, maxSoftTokens: Int) throws -> (width: Int, height: Int) {
        guard width > 0, height > 0, width <= 2048, height <= 2048,
            [70, 140, 280, 560, 1120].contains(maxSoftTokens)
        else {
            throw EmbeddingModelError.invalid("Unsupported image dimensions or soft-token budget")
        }
        let targetPixels = maxSoftTokens * 9 * 256
        let factor = sqrt(Double(targetPixels) / Double(width * height))
        var w = Int(floor(factor * Double(width) / 48)) * 48
        var h = Int(floor(factor * Double(height) / 48)) * 48
        if h == 0 {
            h = 48
            w = min((width / height) * 48, maxSoftTokens * 48)
        } else if w == 0 {
            w = 48
            h = min((height / width) * 48, maxSoftTokens * 48)
        }
        guard w > 0, h > 0, w * h <= targetPixels else {
            throw EmbeddingModelError.invalid("Image resize exceeds patch budget")
        }
        return (w, h)
    }

    private struct Filter {
        let start: Int
        let weights: [Int]
    }

    private static func cubic(_ value: Double) -> Double {
        let x = abs(value)
        if x < 1 { return ((1.5 * x - 2.5) * x) * x + 1 }
        if x < 2 { return ((-0.5 * x + 2.5) * x - 4) * x + 2 }
        return 0
    }

    private static func filters(input: Int, output: Int) -> (filters: [Filter], precision: Int) {
        let scale = Double(input) / Double(output)
        let support = 2 * max(scale, 1)
        let inverseScale = 1 / max(scale, 1)
        var starts = [Int]()
        var floating = [[Double]]()
        starts.reserveCapacity(output)
        floating.reserveCapacity(output)
        var maximum = 0.0
        for index in 0..<output {
            let center = scale * (Double(index) + 0.5)
            let start = max(Int(center - support + 0.5), 0)
            let end = min(Int(center + support + 0.5), input)
            var weights = (start..<end).map { cubic((Double($0) - center + 0.5) * inverseScale) }
            let total = weights.reduce(0, +)
            for i in weights.indices {
                weights[i] /= total
                maximum = max(maximum, weights[i])
            }
            starts.append(start)
            floating.append(weights)
        }
        var precision = 0
        while precision < 22 {
            if Int(0.5 + maximum * Double(1 << (precision + 1))) >= (1 << 15) { break }
            precision += 1
        }
        let multiplier = Double(1 << precision)
        let result = floating.enumerated().map { index, weights in
            Filter(
                start: starts[index],
                weights: weights.map {
                    let value = $0 * multiplier
                    return Int(value < 0 ? value - 0.5 : value + 0.5)
                })
        }
        return (result, precision)
    }

    static func prepare(rgb: Data, width: Int, height: Int, maxSoftTokens: Int = 280) throws -> EmbeddingPreparedImage {
        let size = try targetSize(width: width, height: height, maxSoftTokens: maxSoftTokens)
        guard rgb.count == width * height * 3 else {
            throw EmbeddingModelError.invalid("Invalid RGB8 byte count")
        }
        let patchWidth = size.width / 16
        let patchHeight = size.height / 16
        var pixels = [Float](repeating: 0, count: size.width * size.height * 3)
        var positions = [Int32]()
        positions.reserveCapacity(patchWidth * patchHeight * 2)
        for y in 0..<patchHeight {
            for x in 0..<patchWidth {
                positions.append(Int32(x))
                positions.append(Int32(y))
            }
        }
        // Only the horizontal intermediate is materialized. The vertical pass writes
        // directly into patch-major RGB order, with no resized full-image copy.
        rgb.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            var horizontal = [UInt8]()
            if size.width != width {
                let bank = filters(input: width, output: size.width)
                horizontal = [UInt8](repeating: 0, count: height * size.width * 3)
                for y in 0..<height {
                    for x in 0..<size.width {
                        let filter = bank.filters[x]
                        for channel in 0..<3 {
                            var sum = 1 << (bank.precision - 1)
                            for k in filter.weights.indices {
                                sum += Int(source[(y * width + filter.start + k) * 3 + channel]) * filter.weights[k]
                            }
                            horizontal[(y * size.width + x) * 3 + channel] = UInt8(clamping: sum >> bank.precision)
                        }
                    }
                }
            }
            let vertical = size.height == height ? nil : filters(input: height, output: size.height)
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let destination = (((y / 16) * patchWidth + x / 16) * 256 + (y % 16) * 16 + x % 16) * 3
                    for channel in 0..<3 {
                        let value: UInt8
                        if let vertical {
                            let filter = vertical.filters[y]
                            var sum = 1 << (vertical.precision - 1)
                            for k in filter.weights.indices {
                                let index = ((filter.start + k) * size.width + x) * 3 + channel
                                sum += Int(horizontal.isEmpty ? source[index] : horizontal[index]) * filter.weights[k]
                            }
                            value = UInt8(clamping: sum >> vertical.precision)
                        } else {
                            let index = (y * size.width + x) * 3 + channel
                            value = horizontal.isEmpty ? source[index] : horizontal[index]
                        }
                        pixels[destination + channel] = Float(value) * (1 / Float(255))
                    }
                }
            }
        }
        return EmbeddingPreparedImage(pixels: pixels, positions: positions, width: size.width, height: size.height)
    }
}
