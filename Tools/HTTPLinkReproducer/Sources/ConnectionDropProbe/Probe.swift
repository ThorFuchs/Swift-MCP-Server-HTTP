// SPDX-License-Identifier: Apache-2.0
import NIOHTTPServer

public enum ConnectionProbeFailure: Error { case refused }

/// Models the original consumer's throwing admission before transferring Connection.
/// A public exported function keeps this path in a linked product without opening a socket.
public func rejectOrTransferConnection(
    _ connection: consuming sending NIOHTTPServer.Connection,
    reject: Bool,
    to body: @Sendable (_ connection: consuming sending NIOHTTPServer.Connection) async throws -> Void
) async throws {
    if reject { throw ConnectionProbeFailure.refused }
    try await body(connection)
}
