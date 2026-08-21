import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ScreenlogCore
import SQLite3
import UniformTypeIdentifiers

@main
enum ScreenlogPerformanceMain {
    static func main() async {
        do {
            let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
            let report = try await BenchmarkRunner(configuration: configuration).run()
            try write(report: report, outputPath: configuration.outputPath)
            printSummary(report, outputPath: configuration.outputPath)
        } catch {
            FileHandle.standardError.write(Data("screenlog-performance: \(error)\n".utf8))
            Foundation.exit(2)
        }
    }

    private static func write(report: PerformanceBenchmarkReport, outputPath: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        let url = URL(fileURLWithPath: outputPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func printSummary(_ report: PerformanceBenchmarkReport, outputPath: String) {
        print("Screenlogger performance report")
        for evaluation in report.evaluations {
            let value = evaluation.observation?.value ?? .nan
            let unit: String = switch evaluation.budget.unit {
            case .milliseconds: "ms"
            case .percent: "%"
            case .mebibytes: "MiB"
            }
            let metric = evaluation.budget.metric.rawValue.padding(
                toLength: 27,
                withPad: " ",
                startingAt: 0
            )
            let paddedUnit = unit.padding(toLength: 4, withPad: " ", startingAt: 0)
            print(
                String(
                    format: "  %@ %8.2f %@  budget %8.2f  %@",
                    metric,
                    value,
                    paddedUnit,
                    evaluation.budget.limit,
                    evaluation.status.rawValue
                )
            )
        }
        print("Report: \(URL(fileURLWithPath: outputPath).standardizedFileURL.path)")
        print("Budgets are review thresholds; this command never fails on machine-dependent timing.")
    }
}

private struct Configuration {
    var frameCount = 50_000
    var iterations = 25
    var outputPath = "build/performance/latest.json"

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--frames":
                index += 1
                frameCount = try Self.integerValue(arguments, index: index, flag: argument, minimum: 100)
            case "--iterations":
                index += 1
                iterations = try Self.integerValue(arguments, index: index, flag: argument, minimum: 5)
            case "--output":
                index += 1
                guard arguments.indices.contains(index), !arguments[index].isEmpty else {
                    throw BenchmarkError.invalidArgument("--output requires a path")
                }
                outputPath = arguments[index]
            case "--help", "-h":
                print("Usage: swift run -c release screenlog-performance [--frames 50000] [--iterations 25] [--output path]")
                Foundation.exit(0)
            default:
                throw BenchmarkError.invalidArgument("unknown argument: \(argument)")
            }
            index += 1
        }
    }

    private static func integerValue(
        _ arguments: [String],
        index: Int,
        flag: String,
        minimum: Int
    ) throws -> Int {
        guard arguments.indices.contains(index),
              let value = Int(arguments[index]),
              value >= minimum else {
            throw BenchmarkError.invalidArgument("\(flag) requires an integer >= \(minimum)")
        }
        return value
    }
}

private struct BenchmarkRunner {
    let configuration: Configuration

    func run() async throws -> PerformanceBenchmarkReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-performance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = root.appendingPathComponent("benchmark-source.png", isDirectory: false)
        try createBenchmarkImage(at: imageURL)
        let store = try Store(root: root)
        let frameIDs = try seed(store: store, imagePath: imageURL.path)
        let expectedSearchResults = min(80, (configuration.frameCount + 4) / 5)
        guard let selectedFrame = try store.frame(id: frameIDs[frameIDs.count / 2]) else {
            throw BenchmarkError.fixture("seeded frame could not be loaded")
        }

        // Prime SQLite pages and prepared-code paths. These samples are not part
        // of the warm-search distribution.
        for _ in 0..<5 {
            _ = try store.searchLibrary(query: "quarterly planning", limit: expectedSearchResults)
        }

        var residentSamples = [ProcessSample.current().residentMiB]

        var searchSamples: [Double] = []
        for _ in 0..<configuration.iterations {
            let elapsed = try measureMilliseconds {
                let results = try store.searchLibrary(
                    query: "quarterly planning",
                    limit: expectedSearchResults
                )
                guard results.count == expectedSearchResults else {
                    throw BenchmarkError.fixture(
                        "warm search returned \(results.count), expected \(expectedSearchResults)"
                    )
                }
            }
            searchSamples.append(elapsed)
            residentSamples.append(ProcessSample.current().residentMiB)
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstThumbnail = try measureMilliseconds {
            let image = ScreenlogPerformanceSignposts.measure(.firstThumbnailDecode) {
                FrameExtractor.previewCGImage(atPath: imageURL.path, maxPixelSize: 480)
            }
            guard image != nil else { throw BenchmarkError.fixture("thumbnail decode returned nil") }
        }
        residentSamples.append(ProcessSample.current().residentMiB)

        var extractionSamples: [Double] = []
        for _ in 0..<configuration.iterations {
            let elapsed = try await measureMilliseconds {
                let image = try await FrameExtractor.previewCGImage(
                    forFrame: selectedFrame,
                    store: store,
                    maxPixelSize: 1_280
                )
                guard image.width > 0, image.height > 0 else {
                    throw BenchmarkError.fixture("timeline extraction returned an empty image")
                }
            }
            extractionSamples.append(elapsed)
            residentSamples.append(ProcessSample.current().residentMiB)
            // Pacing models deliberate scrub movement rather than an artificial
            // tight decode loop that consumes one full core by construction.
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // CPU is measured independently from raw extraction latency. This models the real
        // latest-selection UI path: drag events arrive at 50 Hz, each replaces the pending
        // request, and only a selection that remains stable for the debounce window decodes.
        let scrubEventOffsets = (0..<configuration.iterations).map { $0 * 20 }
        guard TimelinePreviewPolicy.settledSelectionIndices(
            eventOffsetsMilliseconds: scrubEventOffsets
        ) == [configuration.iterations - 1] else {
            throw BenchmarkError.fixture("paced scrub policy did not coalesce to the final request")
        }
        let processStart = ProcessSample.current()
        let wallStart = ContinuousClock.now
        var pendingPreview: Task<CGImage, Error>?
        for index in 0..<configuration.iterations {
            pendingPreview?.cancel()
            pendingPreview = Task.detached(priority: .userInitiated) {
                try await Task.sleep(
                    for: .milliseconds(TimelinePreviewPolicy.selectionDebounceMilliseconds)
                )
                return try await FrameExtractor.previewCGImage(
                    forFrame: selectedFrame,
                    store: store,
                    maxPixelSize: TimelinePreviewPolicy.selectedMaxPixelSize
                )
            }
            if index + 1 < configuration.iterations {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        guard let finalPreview = try await pendingPreview?.value,
              finalPreview.width > 0,
              finalPreview.height > 0 else {
            throw BenchmarkError.fixture("paced scrub did not produce its final preview")
        }
        let wallSeconds = wallStart.duration(to: .now).seconds
        let processEnd = ProcessSample.current()
        residentSamples.append(processEnd.residentMiB)
        let cpuPercent = processEnd.cpuSeconds > processStart.cpuSeconds && wallSeconds > 0
            ? ((processEnd.cpuSeconds - processStart.cpuSeconds) / wallSeconds) * 100
            : 0

        let observations = [
            PerformanceObservation(
                metric: .warmLibrarySearch,
                statistic: "p95",
                unit: .milliseconds,
                value: PerformanceStatistics.percentile(searchSamples, percentile: 0.95) ?? 0,
                sampleCount: searchSamples.count,
                samples: searchSamples
            ),
            PerformanceObservation(
                metric: .firstThumbnailDecode,
                statistic: "first",
                unit: .milliseconds,
                value: firstThumbnail,
                sampleCount: 1,
                samples: [firstThumbnail]
            ),
            PerformanceObservation(
                metric: .timelineFrameExtraction,
                statistic: "p95",
                unit: .milliseconds,
                value: PerformanceStatistics.percentile(extractionSamples, percentile: 0.95) ?? 0,
                sampleCount: extractionSamples.count,
                samples: extractionSamples
            ),
            PerformanceObservation(
                metric: .processCPU,
                statistic: "paced-average",
                unit: .percent,
                value: cpuPercent,
                sampleCount: configuration.iterations
            ),
            PerformanceObservation(
                metric: .residentMemory,
                statistic: "peak",
                unit: .mebibytes,
                value: residentSamples.max() ?? processEnd.residentMiB,
                sampleCount: residentSamples.count,
                samples: residentSamples
            ),
        ]

        return PerformanceBenchmarkReport(
            environment: environment(),
            workload: [
                "build": "release",
                "frames": String(configuration.frameCount),
                "iterations": String(configuration.iterations),
                "image": "1920x1080 PNG",
                "search": "quarterly planning, \(expectedSearchResults) results, 5 unmeasured warmups",
                "timeline": "1280px still-backed raw extraction; 50Hz latest-selection scrub with 45ms debounce",
            ],
            observations: observations
        )
    }

    private func seed(store: Store, imagePath: String) throws -> [Int64] {
        try store.db.transaction {
            let statement = try store.db.prepare(
                """
                INSERT INTO frame(
                    timestamp, image_path, width, height, foreground, background, title, is_inactive
                ) VALUES(?, ?, 1920, 1080, ?, ?, ?, 0)
                """
            )
            defer { sqlite3_finalize(statement) }
            var frameIDs: [Int64] = []
            frameIDs.reserveCapacity(configuration.frameCount)
            let base = Int64(1_750_000_000_000)

            for index in 0..<configuration.frameCount {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                SQLiteBind.int64(statement, 1, base + Int64(index * 2_000))
                SQLiteBind.text(statement, 2, imagePath)
                let matching = index.isMultiple(of: 5)
                SQLiteBind.text(
                    statement,
                    3,
                    matching
                        ? "Quarterly planning launch checklist milestone \(index)"
                        : "Routine local activity notes item \(index)"
                )
                SQLiteBind.text(statement, 4, "Background context for deterministic benchmark")
                SQLiteBind.text(statement, 5, matching ? "Quarterly Planning" : "Daily Notes")
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw BenchmarkError.fixture("frame insert failed at index \(index)")
                }
                frameIDs.append(store.db.lastInsertRowID())
            }
            return frameIDs
        }
    }

    private func createBenchmarkImage(at url: URL) throws {
        let width = 1_920
        let height = 1_080
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw BenchmarkError.fixture("could not create image context") }

        context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for column in 0..<12 {
            let component = CGFloat(column) / 12
            context.setFillColor(CGColor(red: 0.2 + component * 0.4, green: 0.35, blue: 0.7 - component * 0.3, alpha: 1))
            context.fill(CGRect(x: column * 160, y: 100 + (column % 3) * 120, width: 120, height: 700))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else { throw BenchmarkError.fixture("could not create benchmark PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BenchmarkError.fixture("could not write benchmark PNG")
        }
    }

    private func environment() -> [String: String] {
        let process = ProcessInfo.processInfo
        return [
            "architecture": Self.machineArchitecture(),
            "logicalCores": String(process.activeProcessorCount),
            "macOS": process.operatingSystemVersionString,
            "model": Self.systemModel(),
            "physicalMemoryMiB": String(process.physicalMemory / 1_048_576),
            "swift": "release executable",
        ]
    }

    private static func machineArchitecture() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func systemModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}

private struct ProcessSample {
    let cpuSeconds: Double
    let residentMiB: Double

    static func current() -> ProcessSample {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000

        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        let resident = result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
        return ProcessSample(cpuSeconds: user + system, residentMiB: resident)
    }
}

private func measureMilliseconds<T>(_ operation: () throws -> T) rethrows -> Double {
    let start = ContinuousClock.now
    _ = try operation()
    return start.duration(to: .now).milliseconds
}

private func measureMilliseconds<T>(_ operation: () async throws -> T) async rethrows -> Double {
    let start = ContinuousClock.now
    _ = try await operation()
    return start.duration(to: .now).milliseconds
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    var milliseconds: Double { seconds * 1_000 }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case fixture(String)

    var description: String {
        switch self {
        case .invalidArgument(let message): return message
        case .fixture(let message): return "fixture error: \(message)"
        }
    }
}
