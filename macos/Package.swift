// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GroqVoice",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device ASR: Parakeet TDT 0.6B v3 compiled to CoreML (Neural Engine).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "GroqVoice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/GroqVoice"
        )
    ]
)
