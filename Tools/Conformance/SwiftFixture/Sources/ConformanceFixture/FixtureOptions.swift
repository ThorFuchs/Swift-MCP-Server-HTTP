// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol

public enum FixtureFailure: Error, Sendable { case arguments, readiness, ownership }
public struct FixtureOptions: Sendable {
    public let readyFile: URL
    public let nonce: String
    public init(arguments: [String]) throws {
        guard arguments.count == 8 else { throw FixtureFailure.arguments }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard ["--host", "--port", "--ready-file", "--nonce"].contains(arguments[index]),
                  values.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else { throw FixtureFailure.arguments }
        }
        guard values["--host"] == "127.0.0.1", values["--port"] == "0", let path = values["--ready-file"],
              path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"), let nonce = values["--nonce"],
              (16...128).contains(nonce.utf8.count), nonce.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw FixtureFailure.arguments }
        self.readyFile = URL(fileURLWithPath: path); self.nonce = nonce
    }
    public func publish(port: Int) throws {
        guard (1...65535).contains(port) else { throw FixtureFailure.readiness }
        struct Ready: Encodable {
            let nonce: String
            let pid: Int32
            let protocolVersion = "2026-07-28"
            let url: String
            let readinessSchema = "swift-mcp-fixture-ready-v2"
            let schemaSHA256 = FrozenWireSchema.sha256
        }
        var limits = JSONLimits.balanced; limits[.outputBytes] = 4096
        let value = try JSONValueEncoder(options: .init(limits: limits)).encodeWithReport(Ready(nonce: nonce, pid: ProcessInfo.processInfo.processIdentifier, url: "http://127.0.0.1:\(port)/mcp")).result
        let bytes = try WireCodec.write(value, limits: limits).result
        let temp = readyFile.deletingLastPathComponent().appendingPathComponent(".ready-" + nonce + ".tmp")
        // Both operations refuse existing entries, including symlinks. The final
        // hard link atomically publishes complete bytes without overwriting work.
        try Data(bytes).write(to: temp, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        try FileManager.default.linkItem(at: temp, to: readyFile)
    }
}
