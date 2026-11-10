// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "ExampleHTTPServer",
    platforms: [.macOS("27.0")],
    dependencies: [.package(url: "https://github.com/swift-server/swift-http-server.git", revision: "0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9", traits: []),
        .package(url: "https://github.com/ThorFuchs/Swift-JSON.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.12.1"),
        .package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", branch: "main"),
        .package(name: "Swift-MCP-Server-HTTP", path: "../..")],
    targets: [.target(name: "ExampleSupport", dependencies: [
        .product(name: "MCPProtocol", package: "Swift-MCP-Server"), .product(name: "MCPServer", package: "Swift-MCP-Server"), .product(name: "JSON", package: "swift-json")]),
        .executableTarget(name: "ExampleHTTPServer", dependencies: ["ExampleSupport", .product(name: "NIOHTTPServer", package: "swift-http-server"),
        .product(name: "MCPProtocol", package: "Swift-MCP-Server"), .product(name: "JSON", package: "swift-json"),
        .product(name: "SystemPackage", package: "swift-system"), .product(name: "Logging", package: "swift-log"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "MCPServer", package: "Swift-MCP-Server"),
        .product(name: "MCPHTTP", package: "Swift-MCP-Server-HTTP"),
        .product(name: "MCPHTTPAuthorization", package: "Swift-MCP-Server-HTTP"),
        .product(name: "MCPServiceLifecycle", package: "Swift-MCP-Server"),
    ])],
    swiftLanguageModes: [.v6]
)
