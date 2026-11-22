// SPDX-License-Identifier: Apache-2.0
import Foundation
import BasicContainers
import NIOHTTPServer

public enum ReaderProbeFailure: Error { case bodyTooLarge, trailersNotAllowed }

/// The HTTP SDK's bounded collector reduced to only the upstream Reader dependency.
public func collectReader(_ reader: consuming NIOHTTPServer.Reader, maximumBytes: Int) async throws -> Data {
    guard maximumBytes >= 0 else { throw ReaderProbeFailure.bodyTooLarge }
    var reader = reader
    var data = Data()
    var done = false
    while !done {
        try Task.checkCancellation()
        do {
            try await reader.read { buffer, final in
                guard buffer.count <= maximumBytes - data.count else { throw ReaderProbeFailure.bodyTooLarge }
                for index in 0..<buffer.count { data.append(buffer[index]) }
                if let final {
                    guard final == nil || final!.isEmpty else { throw ReaderProbeFailure.trailersNotAllowed }
                    done = true
                }
            }
        } catch {
            switch error {
            case .first(let failure): throw failure
            case .second(let failure): throw failure
            }
        }
    }
    return data
}
