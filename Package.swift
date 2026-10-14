// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Screenlog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScreenlogCore", targets: ["ScreenlogCore"]),
        .executable(name: "screenlog", targets: ["ScreenlogCLI"]),
        .executable(name: "screenlog-performance", targets: ["ScreenlogPerformance"]),
    ],
    targets: [
        .target(
            name: "ScreenlogCore",
            path: "Sources/ScreenlogCore",
            exclude: ["Exclusions/Data"],
            resources: [
                // The same authority Xcode uses for app/framework metadata.
                .copy("Resources/ProductVersion.xcconfig")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("VisionKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Combine"),
                .linkedFramework("CoreData"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Accessibility"),
                .linkedFramework("IOKit"),
                .linkedFramework("MetricKit"),
                .linkedFramework("OSLog"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("StoreKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .executableTarget(
            name: "ScreenlogCLI",
            dependencies: ["ScreenlogCore"],
            path: "Sources/ScreenlogCLI",
            exclude: [],
            sources: [
                "CLIActivityCommands.swift",
                "CLIActivityDocuments.swift",
                "CLIArgumentParsing.swift",
                "CLIEntry.swift",
                "CLIMonitoringCommands.swift",
                "CLIQueryCommands.swift",
                "CLISemanticCommands.swift",
                "CLISemanticDocuments.swift",
                "CLIStatusDocuments.swift",
                "SkillInstaller.swift",
            ],
            resources: [
                // Bundled for `screenlog skill install` (also under repo Resources/skill/)
                .copy("skill")
            ]
        ),
        .executableTarget(
            name: "ScreenlogPerformance",
            dependencies: ["ScreenlogCore"],
            path: "Tools/ScreenlogPerformance",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ScreenlogCoreTests",
            dependencies: ["ScreenlogCore"],
            path: "Tests/ScreenlogCoreTests"
        ),
        .testTarget(
            name: "ScreenlogCLITests",
            dependencies: ["ScreenlogCLI"],
            path: "Tests/ScreenlogCLITests"
        ),
    ]
)
