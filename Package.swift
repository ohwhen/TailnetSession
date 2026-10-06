// swift-tools-version: 6.0

import Foundation
import PackageDescription

let tailscaleKit: Target = if let path = ProcessInfo.processInfo.environment["TAILSCALEKIT_XCFRAMEWORK"] {
    .binaryTarget(name: "TailscaleKit", path: path)
} else {
    .binaryTarget(
        name: "TailscaleKit",
        url: "https://github.com/ohwhen/TailnetSession/releases/download/tailscalekit-59d4bb8/TailscaleKit.xcframework.zip",
        checksum: "a6c98036b53e4f67aa5cf88e3bd056d620636b7a19993c2d8fc3a2faab0832fb"
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
