import EmberTesting
import Foundation
import Synchronization
import Testing
@testable import EmberSDK

/// `SystemNetworkPath` shares one monitor between everyone listening to it, started by the first
/// and cancelled when the last leaves.
@Suite(.timeLimit(.minutes(1))) struct SystemNetworkPathTests {
    let monitors = FakePathMonitors()
    let path: SystemNetworkPath

    init() {
        let monitors = monitors
        path = SystemNetworkPath(makeMonitor: { monitors.make() })
    }

    @Test func manyListenersShareOneMonitor() {
        let streams = (0..<50).map { _ in path.availability() }
        withExtendedLifetime(streams) {
            #expect(monitors.made == 1)
            #expect(monitors.all.allSatisfy { $0.started == 1 && $0.cancelled == 0 })
            #expect(path.hub.listenerCount == 50)
        }
    }

    @Test func copiesShareAMonitorAndSeparateValuesDont() {
        let copy = path
        let other = SystemNetworkPath(makeMonitor: { monitors.make() })
        let streams = [path.availability(), copy.availability(), other.availability()]
        withExtendedLifetime(streams) {
            #expect(copy.hub === path.hub)
            #expect(monitors.made == 2)
        }
    }

    @Test func theFirstListenerHearsTheFirstReport() async {
        var first = path.availability().makeAsyncIterator()
        monitors.latest?.push(false)
        #expect(await first.next() == false)
    }

    @Test func aLateListenerHearsTheLastValueAtOnce() async {
        var early = path.availability().makeAsyncIterator()
        monitors.latest?.push(true)
        #expect(await early.next() == true)
        monitors.latest?.push(false)
        #expect(await early.next() == false)

        // No report after it starts listening: it hears what's known already.
        var late = path.availability().makeAsyncIterator()
        #expect(await late.next() == false)
        #expect(monitors.made == 1)
    }

    @Test func everyoneHearsEachChangeOnce() async {
        var listeners = (0..<5).map { _ in path.availability().makeAsyncIterator() }
        let monitor = monitors.latest
        monitor?.push(true)
        monitor?.push(true)
        monitor?.push(false)
        monitor?.push(true)
        for index in listeners.indices {
            #expect(await listeners[index].next() == true)
            #expect(await listeners[index].next() == false)
            #expect(await listeners[index].next() == true)
        }
    }

    @Test func theLastListenerLeavingCancelsTheMonitor() {
        var streams = (0..<3).map { _ in path.availability() }
        let monitor = monitors.latest
        streams.removeLast()
        streams.removeLast()
        #expect(monitor?.cancelled == 0)
        #expect(path.hub.isMonitoring)
        streams.removeAll()
        #expect(monitor?.cancelled == 1)
        #expect(!path.hub.isMonitoring)
        #expect(path.hub.listenerCount == 0)
    }

    @Test func aCancelledTaskLeaves() async {
        let task = Task { [path] in
            for await _ in path.availability() {}
        }
        while path.hub.listenerCount == 0 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(path.hub.listenerCount == 0)
        #expect(monitors.latest?.cancelled == 1)
    }

    @Test func listeningAgainStartsAFreshMonitorAndIgnoresTheOldOne() async {
        var first: AsyncStream<Bool>.Iterator? = path.availability().makeAsyncIterator()
        let old = monitors.latest
        old?.push(true)
        #expect(await first?.next() == true)
        first = nil
        #expect(old?.cancelled == 1)

        var again = path.availability().makeAsyncIterator()
        #expect(monitors.made == 2)
        let fresh = monitors.latest
        #expect(fresh !== old)
        #expect(fresh?.started == 1)
        // The old monitor's late report is dropped, and the last value didn't outlive it.
        old?.push(true)
        fresh?.push(false)
        #expect(await again.next() == false)
    }

    @Test func listeningAndLeavingFromManyTasksAtOnceIsSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<400 {
                group.addTask { [path, monitors] in
                    let listener = path.availability()
                    if index.isMultiple(of: 3) { monitors.latest?.push(index.isMultiple(of: 2)) }
                    if index.isMultiple(of: 5) { await Task.yield() }
                    withExtendedLifetime(listener) {}
                }
            }
        }
        #expect(path.hub.listenerCount == 0)
        #expect(!path.hub.isMonitoring)
        #expect(monitors.made >= 1)
        #expect(monitors.all.allSatisfy { $0.started == 1 && $0.cancelled == 1 })
    }

    @Test func theSystemEnvironmentUsesTheSharedPath() throws {
        let environment = EmberEnvironment.system(cookies: EphemeralCookieStorage())
        let network = try #require(environment.network as? SystemNetworkPath)
        #expect(network.hub === SystemNetworkPath.shared.hub)
    }
}

/// Monitors that report only when a test pushes, counting how many were made, started and cancelled.
final class FakePathMonitors: Sendable {
    private let monitors = Mutex<[FakePathMonitor]>([])

    func make() -> any PathMonitor {
        let monitor = FakePathMonitor()
        monitors.withLock { $0.append(monitor) }
        return monitor
    }

    var all: [FakePathMonitor] { monitors.withLock { $0 } }
    var made: Int { all.count }
    var latest: FakePathMonitor? { all.last }
}

final class FakePathMonitor: PathMonitor {
    private struct State {
        var report: (@Sendable (Bool) -> Void)?
        var started = 0
        var cancelled = 0
    }

    private let state = Mutex(State())

    var started: Int { state.withLock { $0.started } }
    var cancelled: Int { state.withLock { $0.cancelled } }

    func start(_ report: @escaping @Sendable (Bool) -> Void) {
        state.withLock {
            $0.report = report
            $0.started += 1
        }
    }

    func cancel() {
        state.withLock { $0.cancelled += 1 }
    }

    /// Reports `available`, as the system would from its own queue. A cancelled monitor still can,
    /// as a report already on its way would.
    func push(_ available: Bool) {
        state.withLock { $0.report }?(available)
    }
}
