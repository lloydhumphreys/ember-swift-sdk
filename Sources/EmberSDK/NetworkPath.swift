import Foundation
import Network
import Synchronization

/// Whether the device has a network, as it changes. A socket waiting to reconnect listens to it, so it
/// tries again as soon as the network is back rather than when its backoff runs out.
public protocol NetworkPathSource: Sendable {
    /// Whether a network is available now, and again each time that changes, until the stream is
    /// dropped.
    func availability() -> AsyncStream<Bool>
}

/// The device's own network, as `NWPathMonitor` sees it.
///
/// Every stream from one `SystemNetworkPath`, and from its copies, shares one `NWPathMonitor`: the
/// first listener starts it, the last one to leave cancels it, and the next listener after that
/// starts a new one. A listener hears the last known availability as soon as it starts listening,
/// then each change.
public struct SystemNetworkPath: NetworkPathSource {
    /// One monitor for the whole process, started by the first listener and cancelled when the last
    /// one leaves. `EmberEnvironment.system()` uses it, so every client made that way shares it.
    public static let shared = SystemNetworkPath()

    let hub: PathHub

    /// The device's network, with a monitor of its own, shared by this value's copies. Prefer
    /// `shared`.
    public init() {
        self.init(makeMonitor: { SystemPathMonitor() })
    }

    /// A network whose monitors `makeMonitor` makes, for tests that stand in for the system's.
    init(makeMonitor: @escaping @Sendable () -> any PathMonitor) {
        hub = PathHub(makeMonitor: makeMonitor)
    }

    public func availability() -> AsyncStream<Bool> {
        hub.subscribe()
    }
}

/// Something that watches the network and reports whether it's there. `start` mustn't call `report`
/// before it returns.
protocol PathMonitor: Sendable {
    func start(_ report: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

/// `NWPathMonitor`, reporting whether the path is satisfied.
final class SystemPathMonitor: PathMonitor, @unchecked Sendable {
    // NWPathMonitor is safe to use from any thread; it's only set up once, before `start`.
    private let monitor = NWPathMonitor()

    func start(_ report: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in report(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "EmberSDK.SystemNetworkPath"))
    }

    func cancel() {
        monitor.cancel()
    }
}

/// The listeners of one `SystemNetworkPath` and the monitor they share.
final class PathHub: Sendable {
    private struct State {
        var monitor: (any PathMonitor)?
        /// Bumped each time a monitor starts or stops, so a stopped one's late reports are ignored.
        var generation = 0
        /// What the running monitor last reported; nil before its first report.
        var last: Bool?
        var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let makeMonitor: @Sendable () -> any PathMonitor
    private let state = Mutex(State())

    init(makeMonitor: @escaping @Sendable () -> any PathMonitor) {
        self.makeMonitor = makeMonitor
    }

    deinit {
        state.withLock { $0.monitor }?.cancel()
    }

    /// How many streams are listening.
    var listenerCount: Int { state.withLock { $0.listeners.count } }

    /// Whether a monitor is running.
    var isMonitoring: Bool { state.withLock { $0.monitor != nil } }

    func subscribe() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let id = UUID()
        // Held strongly only for as long as this stream lives.
        continuation.onTermination = { _ in self.leave(id) }
        state.withLock { state in
            state.listeners[id] = continuation
            if let last = state.last { continuation.yield(last) }
            guard state.monitor == nil else { return }
            state.generation += 1
            let generation = state.generation
            let monitor = makeMonitor()
            state.monitor = monitor
            // Started under the lock, so it can't be cancelled before it starts. It reports later, on
            // its own queue.
            monitor.start { [weak self] available in
                self?.report(available, generation: generation)
            }
        }
        return stream
    }

    private func report(_ available: Bool, generation: Int) {
        state.withLock { state in
            guard generation == state.generation, state.monitor != nil, state.last != available else { return }
            state.last = available
            // Yielded under the lock so nobody hears an older value after a newer one.
            for listener in state.listeners.values { listener.yield(available) }
        }
    }

    private func leave(_ id: UUID) {
        let stopped = state.withLock { state -> (any PathMonitor)? in
            guard state.listeners.removeValue(forKey: id) != nil, state.listeners.isEmpty else { return nil }
            let monitor = state.monitor
            state.monitor = nil
            state.generation += 1
            state.last = nil
            return monitor
        }
        stopped?.cancel()
    }
}

/// A network that's always there, for sockets made without saying where to hear about it.
@usableFromInline struct SteadyNetworkPath: NetworkPathSource {
    @usableFromInline init() {}

    @usableFromInline func availability() -> AsyncStream<Bool> {
        AsyncStream { $0.yield(true) }
    }
}
