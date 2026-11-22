// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let probes = ["ConnectionDropProbe", "ConnectionTransferProbe", "ReaderDropProbe", "ReaderCollectProbe"]

let package = Package(
    name: "HTTPLinkReproducer",
    platforms: [.macOS("27.0")],
    products: probes.map { .library(name: $0, type: .dynamic, targets: [$0]) },
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-http-server.git", exact: "0.5.0", traits: []),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", exact: "0.2.0", traits: []),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
    ],
    targets: probes.map {
        .target(name: $0, dependencies: [
            .product(name: "NIOHTTPServer", package: "swift-http-server"),
            .product(name: "BasicContainers", package: "swift-collections"),
        ])
    },
    swiftLanguageModes: [.v6]
)
