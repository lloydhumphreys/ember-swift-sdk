import Foundation
import EmberSDK

/// Hands out scripted sockets and remembers them, latest last. Safe to use from any thread.
public final class MockSocketConnector: SocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [MockSocketConnection] = []
    private var opensAtOnce: Bool
    private var script: (@Sendable (MockSocketConnection) -> Void)?

    /// A connector whose sockets open at once, or, with `autoOpen: false`, only when a test calls
    /// `open()` or `serverCloses(…)` on them.
    public init(autoOpen: Bool = true) {
        opensAtOnce = autoOpen
    }

    /// Every socket asked for, in order.
    public var connections: [MockSocketConnection] {
        lock.withLock { made }
    }

    /// The latest socket asked for.
    public var latest: MockSocketConnection? {
        connections.last
    }

    /// Whether sockets asked for from now on open at once.
    public var autoOpen: Bool {
        get { lock.withLock { opensAtOnce } }
        set { lock.withLock { opensAtOnce = newValue } }
    }

    /// Plays the server's side of each socket as it's asked for, such as sending a welcome. It runs
    /// before the connection is handed to the client, so anything it sends is waiting to be read.
    public func onConnect(_ script: @escaping @Sendable (MockSocketConnection) -> Void) {
        lock.withLock { self.script = script }
    }

    /// A scripted socket for `request`.
    public func connect(_ request: URLRequest) -> any SocketConnection {
        let (connection, script) = lock.withLock { () -> (MockSocketConnection, (@Sendable (MockSocketConnection) -> Void)?) in
            let connection = MockSocketConnection(request: request, open: opensAtOnce)
            made.append(connection)
            return (connection, self.script)
        }
        script?(connection)
        return connection
    }
}

/// One scripted socket: a test says what the server sends and how it ends, and reads what the
/// client sent. Safe to use from any thread.
public final class MockSocketConnection: SocketConnection, @unchecked Sendable {
    /// The request the client opened it with, headers included.
    public let request: URLRequest

    private let lock = NSLock()
    private var isOpen: Bool
    private var ended: SocketClosed?
    private var closedByClient = false
    private var sendFailure: SocketClosed?
    private var inbox: [String] = []
    private var outbox: [String] = []
    private var receivers: [CheckedContinuation<String, any Error>] = []
    private var openWaiters: [CheckedContinuation<Void, any Error>] = []

    /// A socket for `request`, open already or waiting for `open()`.
    public init(request: URLRequest, open: Bool = true) {
        self.request = request
        isOpen = open
    }

    /// What the client sent, in order.
    public var sent: [String] {
        lock.withLock { outbox }
    }

    /// What the client sent, read as frames, pings included; anything that isn't a JSON object
    /// with a `type` is left out.
    public var sentFrames: [SentFrame] {
        sent.compactMap(SentFrame.init(text:))
    }

    /// What the client sent, read as room frames; anything a room wouldn't take is left out.
    package var sentClientFrames: [ClientFrame] {
        sent.compactMap(ClientFrame.init(text:))
    }

    /// The `type` of each frame the client sent, in order, pings included.
    public var sentTypes: [String] {
        sent.compactMap { text in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String
        }
    }

    /// Whether the client closed it.
    public var isClosedByClient: Bool {
        lock.withLock { closedByClient }
    }

    /// Whether it has ended, from either side.
    public var hasEnded: Bool {
        lock.withLock { ended != nil }
    }

    /// Every send from now on throws, while the socket otherwise stays as it is, as a socket whose
    /// network has gone quiet can fail a write before it notices it's closed.
    public func failSends(with error: SocketClosed = SocketClosed()) {
        lock.withLock { sendFailure = error }
    }

    /// The server lets the socket in.
    public func open() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard ended == nil else { return [] }
            isOpen = true
            defer { openWaiters = [] }
            return openWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// The server sends a text frame. Nothing once the socket has ended.
    public func serverSends(_ text: String) {
        let receiver = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            guard ended == nil else { return nil }
            if receivers.isEmpty {
                inbox.append(text)
                return nil
            }
            return receivers.removeFirst()
        }
        receiver?.resume(returning: text)
    }

    /// The server ends the socket: with a close code once open, or by refusing the upgrade with an
    /// HTTP status. Neither stands for the network dropping it.
    public func serverCloses(code: Int? = nil, httpStatus: Int? = nil) {
        end(SocketClosed(closeCode: code, httpStatus: httpStatus), byClient: false)
    }

    public func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let ended {
                lock.unlock()
                continuation.resume(throwing: ended)
            } else if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                openWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func send(_ text: String) async throws {
        try lock.withLock {
            if let ended { throw ended }
            if let sendFailure { throw sendFailure }
            outbox.append(text)
        }
    }

    public func receive() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            lock.lock()
            if !inbox.isEmpty {
                let text = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: text)
            } else if let ended {
                lock.unlock()
                continuation.resume(throwing: ended)
            } else {
                receivers.append(continuation)
                lock.unlock()
            }
        }
    }

    public func close() {
        end(SocketClosed(), byClient: true)
    }

    private func end(_ closed: SocketClosed, byClient: Bool) {
        let (receivers, openWaiters) = lock.withLock { () -> ([CheckedContinuation<String, any Error>], [CheckedContinuation<Void, any Error>]) in
            guard ended == nil else { return ([], []) }
            ended = closed
            closedByClient = byClient
            // What the server sent before it closed is still read first, as a real socket's would be.
            defer {
                self.receivers = []
                self.openWaiters = []
            }
            return (self.receivers, self.openWaiters)
        }
        for receiver in receivers { receiver.resume(throwing: closed) }
        for waiter in openWaiters { waiter.resume(throwing: closed) }
    }
}

/// One frame a client sent on a socket, as its JSON fields: `type` says which, and the rest are
/// as the protocol names them (the `body` of a `message.create`, the `before` of a `history.before`).
public struct SentFrame: Hashable, Sendable {
    /// The protocol's name for the frame, such as `message.create`.
    public let type: String
    /// The frame's fields, `type` among them.
    public let fields: [String: JSONValue]
    /// The frame as sent.
    public let text: String

    /// Reads a frame as sent; nil when it isn't a JSON object with a `type`.
    public init?(text: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              case let .object(fields) = value, case let .string(type)? = fields["type"] else { return nil }
        self.type = type
        self.fields = fields
        self.text = text
    }

    /// The field named `key`, or nil when the frame doesn't have it.
    public subscript(key: String) -> JSONValue? {
        fields[key]
    }

    /// The field named `key` when it's a string, such as a `message.create`'s `body`.
    public func string(_ key: String) -> String? {
        if case let .string(value)? = fields[key] { value } else { nil }
    }
}
