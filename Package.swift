// swift-tools-version: 6.0

import Foundation
import PackageDescription

let tailscaleKit: Target = if let path = ProcessInfo.processInfo.environment["TAILSCALEKIT_XCFRAMEWORK"] {
    .binaryTarget(name: "TailscaleKit", path: path)
} else {
    .binaryTarget(
        name: "TailscaleKit",
        url: "https://github.com/ohwhen/TailnetSession/releases/download/tailscalekit-ac7ed43/TailscaleKit.xcframework.zip",
        checksum: "e5e5dca5b31c83079921b09fdb65fa2519e3824672fd1bd0e74a573b8716d3c1"
    )
}

let package = Package(
    name: "TailnetSession",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "TailnetSession", targets: ["TailnetSession"]),
    ],
    targets: [
        tailscaleKit,
        .target(name: "TailnetSession", dependencies: ["TailscaleKit"]),
        .testTarget(name: "TailnetSessionTests", dependencies: ["TailnetSession"]),
    ],
    swiftLanguageModes: [.v6]
)
