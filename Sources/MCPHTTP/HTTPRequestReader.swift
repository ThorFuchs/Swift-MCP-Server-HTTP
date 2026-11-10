// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOHTTPServer

/// Consume raw bytes without repairing UTF-8 or collecting an unbounded String.
enum HTTPRequestReader {
    static func collect(_ reader: consuming NIOHTTPServer.Reader, maximumBytes: Int) async throws -> Data {
        var reader = reader
        var data = Data()
        var done = false
        while !done {
            try Task.checkCancellation()
            do { try await reader.read { buffer, final in
                guard buffer.count <= maximumBytes - data.count else { throw HTTPAdmission.Failure.tooLarge }
                for index in 0..<buffer.count { data.append(buffer[index]) }
                if let final {
                    // Mirrored credentials/metadata cannot arrive after admission in trailers.
                    guard final == nil || final!.isEmpty else { throw HTTPAdmission.Failure.malformed }
                    done = true
                }
            } } catch {
                switch error { case .first(let failure): throw failure; case .second(let failure): throw failure }
            }
        }
        return data
    }
}
