import Foundation

/// One socket that keeps itself connected: reconnects with backoff, pings every 25 s, and gives up
/// only when the server says the session or the room is gone, or refuses it outright. A port of the
/// web client's `reconnecting-socket.ts`.
///
/// Backoff starts over only once a connection has stayed open for `EmberTiming.stablePeriod`. While
/// the network is gone it waits without backing off further, and it tries again as soon as the
/// network is back.
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
        /// The upgrade was refused with `status`, a 4xx that trying again won't change (anything
        /// but 401, 408 and 429), such as 403 or 404 when the server doesn't take this origin.
        case refused(status: Int)
    }

    /// Where the socket is now.
    public private(set) var status: Status = .idle
    /// Hears every change of `status`.
    public var onStatus: (@MainActor (Status) -> Void)?
    /// Every text frame but `pong`, in order.
    public var onText: (@MainActor (String) -> Void)?
    /// Whether the network was there when last heard, while the socket is started.
    public private(set) var isNetworkAvailable = true
    /// Hears every change of `isNetworkAvailable`.
    var onNetwork: (@MainActor (Bool) -> Void)?

    /// The text of a ping, which the server answers `{"type":"pong"}`.
    public static let ping = #"{"type":"ping"}"#

    private let connector: any SocketConnector
    private let request: @MainActor () -> URLRequest
    private let timing: EmberTiming
    private let network: any NetworkPathSource
    /// Bumped by every `start()` and `stop()`, so a loop that's been stopped notices on waking.
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var connection: (any SocketConnection)?
    private var outbox: AsyncStream<String>.Continuation?
    private var attempt = 0
    /// The wait before the next try, which the network coming back cuts short.
    private var waiting: Task<Void, any Error>?

    /// A socket on `connector`. `request` is asked again for each attempt, so a room socket can name
    /// the latest `seq`. `timing` says how long it waits; tests pass one on a `ManualClock`.
    public convenience init(connector: any SocketConnector, timing: EmberTiming = .standard, request: @escaping @MainActor () -> URLRequest) {
        self.init(connector: connector, timing: timing, network: SteadyNetworkPath(), request: request)
    }

    /// A socket on `connector` that hears from `network` whether there's a network to try.
    public init(connector: any SocketConnector, timing: EmberTiming = .standard, network: any NetworkPathSource, request: @escaping @MainActor () -> URLRequest) {
        self.connector = connector
        self.timing = timing
        self.network = network
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
        waiting?.cancel()
        waiting = nil
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
        let watcher = Task { [weak self, network] in
            for await available in network.availability() {
                guard let self, self.isCurrent(generation) else { return }
                self.networkChanged(available)
            }
        }
        defer { watcher.cancel() }

        var delay: Duration? = nil
        // Whether the last connection ended at the server's asking (4001) without hearing a thing.
        var askedAgainUnheard = false
        while isCurrent(generation) {
            if let delay {
                set(.connecting)
                guard await wait(delay, generation) else { return }
            }
            set(.connecting)
            let ended = await connectOnce(generation)
            guard isCurrent(generation) else { return }
            tearDown()
            if ended.openFor >= timing.stablePeriod { attempt = 0 }
            var ending = ended.ending
            if ending == .now {
                // Asked twice running without a word between: the server's closing every socket as it
                // opens, so it's backed off from like any other failure.
                if askedAgainUnheard && !ended.heard { ending = .later }
                askedAgainUnheard = !ended.heard
            } else {
                askedAgainUnheard = false
            }
            switch ending {
            case .stop(let reason):
                generation == self.generation ? set(.stopped(reason)) : ()
                loop = nil
                return
            case .now:
                delay = timing.reconnectDelay()
            case .later where !isNetworkAvailable:
                // Nothing will get through until the network's back, which cuts this short; the
                // backoff isn't spent on it.
                delay = timing.backoffMax
            case .later:
                delay = timing.backoff(attempt: attempt)
                attempt += 1
            }
        }
    }

    /// Waits `delay`, or until the network comes back. False when the socket was stopped meanwhile.
    private func wait(_ delay: Duration, _ generation: Int) async -> Bool {
        let timing = timing
        let sleeper = Task { try await timing.sleep(for: delay) }
        waiting = sleeper
        await withTaskCancellationHandler {
            _ = await sleeper.result
        } onCancel: {
            sleeper.cancel()
        }
        if waiting == sleeper { waiting = nil }
        return isCurrent(generation)
    }

    private func networkChanged(_ available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        onNetwork?(available)
        if available, let waiting {
            attempt = 0
            waiting.cancel()
        }
    }

    private enum Ending: Equatable {
        case stop(StopReason)
        case now
        case later
    }

    /// How a connection ended, whether anything came from the server on it, and how long it was open.
    private struct Ended {
        var ending: Ending
        var heard = false
        var openFor: Duration = .zero
    }

    /// One connection, from asking for it to its end.
    private func connectOnce(_ generation: Int) async -> Ended {
        let connection = connector.connect(request())
        self.connection = connection

        guard await opens(connection) else {
            connection.close()
            return Ended(ending: isCurrent(generation) ? ending(of: lastClose) : .later)
        }
        guard isCurrent(generation) else { return Ended(ending: .later) }
        let openFor = timing.stopwatch()
        var heardAny = false

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
                guard isCurrent(generation) else { return Ended(ending: .later) }
                return Ended(ending: ending(of: error as? SocketClosed ?? SocketClosed()), heard: heardAny, openFor: openFor())
            }
            guard isCurrent(generation) else { return Ended(ending: .later) }
            heard.since = true
            heardAny = true
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
        if let status = closed.httpStatus, (400..<500).contains(status), status != 408, status != 429 {
            return .stop(.refused(status: status))
        }
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
