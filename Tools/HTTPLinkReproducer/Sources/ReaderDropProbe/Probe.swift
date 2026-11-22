// SPDX-License-Identifier: Apache-2.0
import NIOHTTPServer

/// Isolates external destruction of the public, noncopyable Reader, without reading it.
public func dropReader(_ reader: consuming NIOHTTPServer.Reader) async throws {
    try Task.checkCancellation()
}
