// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DialogueKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "DialogueKit", targets: ["DialogueKit"]),
        .library(name: "DialogueKitOpenAI", targets: ["DialogueKitOpenAI"]),
    ],
    targets: [
        .target(name: "DialogueKit"),
        .testTarget(name: "DialogueKitTests", dependencies: ["DialogueKit"]),
        .target(name: "DialogueKitOpenAI", dependencies: ["DialogueKit"]),
        .testTarget(name: "DialogueKitOpenAITests", dependencies: ["DialogueKitOpenAI"]),
    ]
)
