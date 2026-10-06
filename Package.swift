// swift-tools-version: 6.0

import Foundation
import PackageDescription

let tailscaleKit: Target = if let path = ProcessInfo.processInfo.environment["TAILSCALEKIT_XCFRAMEWORK"] {
    .binaryTarget(name: "TailscaleKit", path: path)
} else {
    .binaryTarget(
        name: "TailscaleKit",
        url: "https://github.com/ohwhen/TailnetSession/releases/download/tailscalekit-59d4bb8/TailscaleKit.xcframework.zip",
        checksum: "0000000000000000000000000000000000000000000000000000000000000000"
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
