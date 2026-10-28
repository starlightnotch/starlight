// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Starlight",
    // Process taps (14.2) and their permission prompt (14.4), for the other side of meetings.
    platforms: [.macOS("14.4")],
    dependencies: [
        // Parakeet speech recognition on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7"),
        // Auto-updates: the standard for Mac apps outside the App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // llama.cpp b11577, for the local cleanup model.
        // build.sh downloads and checksum-verifies it into Vendor/.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .executableTarget(
            name: "Starlight",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                "llama",
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
