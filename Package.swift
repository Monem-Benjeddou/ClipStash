// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClipStash",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClipStash", path: "Sources/ClipStash")
    ]
)
