// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ConformanceFixture
import MCPTasks
import Logging
import MCPHTTP
import MCPServiceLifecycle
import ServiceLifecycle

@main struct SwiftConformanceServer {
    enum Finished: Sendable { case runtime, deadline, timerCancelled }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FIXTURE_FAILED\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let options = try FixtureOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let fixture = try await FixtureRuntime.make()
        let address = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let component = try TransportService(name: "referee-http", run: { ready in
            defer { address.continuation.finish() }
            do { try await fixture.transport.run { bound in address.continuation.yield(bound); try await ready() } }
            catch is CancellationError { }
        }, shutdown: { await fixture.transport.shutdown() })
        // The Tasks runtime owns all task work; cancelling it cancels and joins that work.
        let tasks = try TransportService(name: "tasks-runtime", run: { ready in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await FixtureTasks.runtime.run() }
                while !(await FixtureTasks.runtime.isRunning) { await Task.yield() }
                try await ready()
                try await group.waitForAll()
            }
        }, shutdown: { await FixtureTasks.runtime.shutdown() })
        let components = [tasks, component]
        let service = try ServerService(server: fixture.server, components: components)
        let logger = Logger(label: "referee-fixture", factory: { _ in SwiftLogNoOpLogHandler() })
        // Process signals are owned only by this standalone executable. Preserve
        // D29's nil candidate timers; the production service owns finite drain.
        var config = ServiceGroupConfiguration(services: [.init(service: service, successTerminationBehavior: .gracefullyShutdownGroup, failureTerminationBehavior: .cancelGroup)], logger: logger)
        config.gracefulShutdownSignals = [.sigterm, .sigint]
        config.maximumGracefulShutdownDuration = nil; config.maximumCancellationDuration = nil
        let lifecycle = ServiceGroup(configuration: config)
        do {
            try await withThrowingTaskGroup(of: Finished.self) { group in
                group.addTask { try await lifecycle.run(); return .runtime }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(1800)); await lifecycle.triggerGracefulShutdown(); return .deadline }
                    catch is CancellationError { return .timerCancelled }
                }
                do {
                    var iterator = address.stream.makeAsyncIterator()
                    guard let bound = await iterator.next() else { throw FixtureFailure.readiness }
                    let end = ContinuousClock.now.advanced(by: .seconds(5))
                    while await service.readiness.state != .ready {
                        try Task.checkCancellation(); guard ContinuousClock.now < end else { throw FixtureFailure.readiness }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    try options.publish(port: bound.port)
                    _ = try await group.next(); group.cancelAll(); try await group.waitForAll()
                } catch { service.requestShutdown(); group.cancelAll(); throw error }
            }
            let active = await fixture.server.activity, io = await fixture.transport.activity, report = await service.report
            guard report.started == components.count, report.joined == components.count, report.failure == nil,
                  active.active == 0, active.requests == 0, active.bufferedBytes == 0, active.eventBytes == 0, active.subscriptions == 0,
                  active.inspections == 0, active.queuedInspections == 0,
                  io.connections == 0, io.requests == 0 else { throw FixtureFailure.ownership }
            await fixture.clear()
            FileHandle.standardError.write(Data("FIXTURE_STOPPED started=\(report.started) joined=\(report.joined) active=\(active.active)\n".utf8))
        } catch { await fixture.clear(); throw error }
    }
}
