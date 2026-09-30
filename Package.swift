// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MarkdownEditor",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MarkdownCore"),
        .executableTarget(name: "MarkdownEditor", dependencies: ["MarkdownCore"]),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore", "MarkdownEditor"]),
    ]
)
