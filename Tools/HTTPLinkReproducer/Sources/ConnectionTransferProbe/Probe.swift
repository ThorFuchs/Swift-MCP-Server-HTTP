// SPDX-License-Identifier: Apache-2.0
import NIOHTTPServer

/// Control: this consumer always transfers Connection; it never drops it before transfer.
public func transferConnection(
    _ connection: consuming sending NIOHTTPServer.Connection,
    to body: @Sendable (_ connection: consuming sending NIOHTTPServer.Connection) async throws -> Void
) async throws {
    try await body(connection)
}
