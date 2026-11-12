import Foundation
import Network

/// Whether the device has a network, as it changes. A socket waiting to reconnect listens to it, so it
/// tries again as soon as the network is back rather than when its backoff runs out.
public protocol NetworkPathSource: Sendable {
    /// Whether a network is available now, and again each time that changes, until the stream is
    /// dropped.
    func availability() -> AsyncStream<Bool>
}

/// The device's own network, as `NWPathMonitor` sees it.
public struct SystemNetworkPath: NetworkPathSource {
    /// The device's network.
    public init() {}

    public func availability() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "EmberSDK.SystemNetworkPath"))
        }
    }
}

/// A network that's always there, for sockets made without saying where to hear about it.
@usableFromInline struct SteadyNetworkPath: NetworkPathSource {
    @usableFromInline init() {}

    @usableFromInline func availability() -> AsyncStream<Bool> {
        AsyncStream { $0.yield(true) }
    }
}
