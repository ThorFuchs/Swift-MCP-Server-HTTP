// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "Swift-MCP-Server-HTTP",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MCPHTTP", targets: ["MCPHTTP"]),
        .library(name: "MCPHTTPAuthorization", targets: ["MCPHTTPAuthorization"]),
    ],
    dependencies: [
        // Pre-1.0: follows the core's main branch; switches to `from: "1.0.0"` at the core release.
        .package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", branch: "main"),
        .package(url: "https://github.com/ThorFuchs/Swift-JSON.git", from: "1.8.0"),
        // Upstream SwiftNIO. Early EOF on macOS 27 needs apple/swift-nio#3783 (see README, Known issues).
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/swift-server/swift-http-server.git", revision: "0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9", traits: []),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", exact: "0.2.0", traits: []),
        // BasicContainers' borrowing iterators changed incompatibly in swift-collections 1.7.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.12.1"),
    ],
    targets: [
        .target(name: "MCPHTTP", dependencies: [
            .product(name: "MCPServer", package: "Swift-MCP-Server"), .product(name: "MCPProtocol", package: "Swift-MCP-Server"),
            .product(name: "JSON", package: "swift-json"), .product(name: "NIOHTTPServer", package: "swift-http-server"),
            .product(name: "NIOCore", package: "swift-nio"), .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
            .product(name: "BasicContainers", package: "swift-collections")]),
        .target(name: "MCPHTTPAuthorization", dependencies: ["MCPHTTP",
            .product(name: "MCPServer", package: "Swift-MCP-Server"), .product(name: "MCPProtocol", package: "Swift-MCP-Server"),
            .product(name: "JSON", package: "swift-json")]),
        .testTarget(name: "MCPHTTPTests", dependencies: ["MCPHTTPAuthorization", "MCPHTTP",
            .product(name: "MCPServiceLifecycle", package: "Swift-MCP-Server"), .product(name: "NIOHTTPServer", package: "swift-http-server"),
            .product(name: "MCPServerTesting", package: "Swift-MCP-Server"), .product(name: "MCPServer", package: "Swift-MCP-Server"),
            .product(name: "MCPProtocol", package: "Swift-MCP-Server"), .product(name: "JSON", package: "swift-json")],
            exclude: ["TEST_PLAN.md"], resources: [.copy("Resources")]),
        .testTarget(name: "MCPHTTPAuthorizationTests", dependencies: ["MCPHTTPAuthorization", "MCPHTTP",
            .product(name: "MCPProtocol", package: "Swift-MCP-Server"), .product(name: "MCPServer", package: "Swift-MCP-Server"),
            .product(name: "MCPServerTesting", package: "Swift-MCP-Server")],
            exclude: ["TEST_PLAN.md"]),
    ],
    swiftLanguageModes: [.v6]
)
