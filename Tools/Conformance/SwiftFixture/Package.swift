// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription
let package = Package(
    name: "SwiftConformanceServer", platforms: [.macOS("27.0")],
    dependencies: [
        .package(name: "Swift-MCP-Server-HTTP", path: "../../.."),
        .package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", branch: "main"),
        .package(url: "https://github.com/ThorFuchs/Swift-JSON.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.12.1"),
    ],
    targets: [
        .target(name: "ConformanceFixture", dependencies: [
            .product(name: "MCPTasks", package: "Swift-MCP-Server"),
            .product(name: "MCPProtocol", package: "Swift-MCP-Server"),
            .product(name: "MCPServer", package: "Swift-MCP-Server"),
            .product(name: "MCPHTTP", package: "Swift-MCP-Server-HTTP"),
            .product(name: "MCPServiceLifecycle", package: "Swift-MCP-Server"),
            .product(name: "JSON", package: "swift-json"),
        ]),
        .executableTarget(name: "SwiftConformanceServer", dependencies: ["ConformanceFixture",
            .product(name: "MCPTasks", package: "Swift-MCP-Server"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "MCPServiceLifecycle", package: "Swift-MCP-Server"),
            .product(name: "MCPHTTP", package: "Swift-MCP-Server-HTTP"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "FixtureTests", dependencies: ["ConformanceFixture",
            .product(name: "MCPProtocol", package: "Swift-MCP-Server"),
            .product(name: "MCPServer", package: "Swift-MCP-Server"),
            .product(name: "MCPServerTesting", package: "Swift-MCP-Server"),
            .product(name: "JSON", package: "swift-json"),
        ]),
    ], swiftLanguageModes: [.v6]
)
