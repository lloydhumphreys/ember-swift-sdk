import Foundation

/// One socket that keeps itself connected: reconnects with backoff, pings every 25 s, and gives up
/// only when the server says the session or the room is gone. A port of the web client's
/// `reconnecting-socket.ts`.
///
/// It lives on the main actor, and its callbacks arrive there in order. `stop()` stops it wherever it
/// is, connecting or waiting to try again, and `start()` brings it back.
@MainActor public final class ReconnectingSocket {
    /// Where the socket is.
    public enum Status: Equatable, Sendable {
        /// Not started, or stopped by `stop()`.
        case idle
        /// Trying to connect, or waiting to try again.
        case connecting
        /// Connected.
        case open
        /// The server said not to come back; `start()` tries again anyway.
        case stopped(StopReason)
    }

    /// Why the server said not to come back.
    public enum StopReason: Equatable, Sendable {
        /// The session is gone: the upgrade was refused 401, or the socket closed as revoked (4003).
        case signedOut
        /// The room is gone, or you're no longer in it (4004).
        case notFound
    }

    /// Where the socket is now.
    public private(set) var status: Status = .idle
    /// Hears every change of `status`.
    public var onStatus: (@MainActor (Status) -> Void)?
    /// Every text frame but `pong`, in order.
    public var onText: (@MainActor (String) -> Void)?

    /// The text of a ping, which the server answers `{"type":"pong"}`.
    public static let ping = #"{"type":"ping"}"#

    private let connector: any SocketConnector
    private let request: @MainActor () -> URLRequest
    private let timing: EmberTiming
    /// Bumped by every `start()` and `stop()`, so a loop that's been stopped notices on waking.
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var connection: (any SocketConnection)?
    private var outbox: AsyncStream<String>.Continuation?
    private var attempt = 0

    /// A socket on `connector`. `request` is asked again for each attempt, so a room socket can name
    /// the latest `seq`. `timing` says how long it waits; tests pass one on a `ManualClock`.
    public init(connector: any SocketConnector, timing: EmberTiming = .standard, request: @escaping @MainActor () -> URLRequest) {
        self.connector = connector
        self.timing = timing
        self.request = request
    }

    /// A socket on `connector`, with the standard timing.
    public convenience init(connector: any SocketConnector, request: @escaping @MainActor () -> URLRequest) {
        self.init(connector: connector, timing: .standard, request: request)
    }

    /// Starts connecting. Nothing when already connecting or open.
    public func start() {
        switch status {
        case .connecting, .open: return
        case .idle, .stopped: break
        }
        generation += 1
        attempt = 0
        let generation = generation
        set(.connecting)
        loop = Task { [weak self] in await self?.run(generation) }
    }

    /// Closes the socket and stops trying; `status` becomes `.idle`. `start()` connects again.
    public func stop() {
        generation += 1
        tearDown()
        loop?.cancel()
        loop = nil
        set(.idle)
    }

    /// Sends `text` if the socket is open, in order with everything else sent. False when it isn't.
    @discardableResult
    public func send(_ text: String) -> Bool {
        guard status == .open, let outbox else { return false }
        outbox.yield(text)
        return true
    }

    // MARK: The loop

    private func run(_ generation: Int) async {
        var delay: Duration? = nil
        while isCurrent(generation) {
            if let delay {
                set(.connecting)
                do { try await timing.sleep(for: delay) } catch { return }
                guard isCurrent(generation) else { return }
            }
            set(.connecting)
            let ended = await connectOnce(generation)
            guard isCurrent(generation) else { return }
            tearDown()
            switch ended {
            case .stop(let reason):
                generation == self.generation ? set(.stopped(reason)) : ()
                loop = nil
                return
            case .now:
                attempt = 0
                delay = .zero
            case .later:
                delay = timing.backoff(attempt: attempt)
                attempt += 1
            }
        }
    }

    private enum Ending {
        case stop(StopReason)
        case now
        case later
    }

    /// One connection, from asking for it to its end.
    private func connectOnce(_ generation: Int) async -> Ending {
        let connection = connector.connect(request())
        self.connection = connection

        guard await opens(connection) else {
            connection.close()
            return isCurrent(generation) ? ending(of: lastClose) : .later
        }
        guard isCurrent(generation) else { return .later }

        let (stream, continuation) = AsyncStream<String>.makeStream()
        outbox = continuation
        let sender = Task { [weak self] in
            for await text in stream {
                do {
                    try await connection.send(text)
                } catch {
                    // A write that fails means the connection is no good, whatever `receive()` thinks
                    // yet: end it, so the loop reconnects, and refuse what's sent meanwhile, since
                    // nothing would carry it. (Cancelled means this connection's over already, and the
                    // outbox may be the next one's.)
                    guard !Task.isCancelled else { return }
                    self?.outbox?.finish()
                    self?.outbox = nil
                    connection.close()
                    return
                }
            }
        }
        defer { sender.cancel() }

        set(.open)
        let heard = Heard()
        let heartbeat = Task { [timing] in
            while !Task.isCancelled {
                do { try await timing.sleep(for: timing.heartbeat) } catch { return }
                if !heard.since {
                    // The last ping went unanswered: the network dropped without closing the socket.
                    connection.close()
                    return
                }
                heard.since = false
                continuation.yield(Self.ping)
            }
        }
        defer { heartbeat.cancel() }

        while true {
            let text: String
            do {
                text = try await connection.receive()
            } catch {
                guard isCurrent(generation) else { return .later }
                return ending(of: error as? SocketClosed ?? SocketClosed())
            }
            guard isCurrent(generation) else { return .later }
            heard.since = true
            // Hearing from the server means it let this connection in, so the next close backs off from
            // the start again. (A server that closes a socket as soon as it opens keeps being backed off from.)
            attempt = 0
            if Self.isPong(text) { continue }
            onText?(text)
        }
    }

    /// The close the last failed open ended with.
    private var lastClose = SocketClosed()

    /// Whether `connection` opens within the connect timeout.
    private func opens(_ connection: any SocketConnection) async -> Bool {
        let timeout = timing.connectTimeout
        let timing = timing
        let result: Result<Bool, SocketClosed> = await withTaskGroup(of: Result<Bool, SocketClosed>?.self) { group in
            group.addTask {
                do {
                    try await connection.waitUntilOpen()
                    return .success(true)
                } catch {
                    return .failure(error as? SocketClosed ?? SocketClosed())
                }
            }
            group.addTask {
                do { try await timing.sleep(for: timeout) } catch { return nil }
                return .success(false)
            }
            var first: Result<Bool, SocketClosed>? = nil
            while first == nil, let next = await group.next() {
                first = next
                if next == nil && Task.isCancelled { break }
            }
            if first == .success(false) { connection.close() }
            group.cancelAll()
            return first ?? .success(false)
        }
        switch result {
        case .success(let opened):
            lastClose = SocketClosed()
            return opened
        case .failure(let closed):
            lastClose = closed
            return false
        }
    }

    private func ending(of closed: SocketClosed) -> Ending {
        if closed.httpStatus == 401 || closed.closeCode == SocketClose.revoked { return .stop(.signedOut) }
        if closed.closeCode == SocketClose.notFound { return .stop(.notFound) }
        if closed.closeCode == SocketClose.reconnect { return .now }
        return .later
    }

    private func tearDown() {
        outbox?.finish()
        outbox = nil
        connection?.close()
        connection = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    private func set(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        onStatus?(status)
    }

    static func isPong(_ text: String) -> Bool {
        guard text.count < 64, text.contains("pong") else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
        return object["type"] as? String == "pong"
    }
}

/// Whether anything has come from the server since the last ping. Set on the main actor and read by
/// the heartbeat, which runs there too.
@MainActor private final class Heard {
    var since = true
}
