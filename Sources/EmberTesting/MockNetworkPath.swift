import Foundation
import EmberSDK
import Synchronization

/// A network a test takes away and brings back with `set(available:)`. Available until then.
public final class MockNetworkPath: NetworkPathSource {
    private struct State {
        var available: Bool
        var listeners: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state: Mutex<State>

    /// A network that's there, or not.
    public init(available: Bool = true) {
        state = Mutex(State(available: available))
    }

    /// Whether the network is there now.
    public var isAvailable: Bool {
        state.withLock { $0.available }
    }

    /// Takes the network away or brings it back, telling everyone listening when that's a change.
    public func set(available: Bool) {
        let listeners = state.withLock { state -> [AsyncStream<Bool>.Continuation] in
            guard state.available != available else { return [] }
            state.available = available
            return Array(state.listeners.values)
        }
        for listener in listeners { listener.yield(available) }
    }

    /// How many streams are listening.
    public var listenerCount: Int {
        state.withLock { $0.listeners.count }
    }

    public func availability() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let id = UUID()
        let available = state.withLock { state in
            state.listeners[id] = continuation
            return state.available
        }
        continuation.yield(available)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) }
        }
        return stream
    }
}
