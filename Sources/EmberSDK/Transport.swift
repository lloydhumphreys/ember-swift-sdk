import Foundation

/// The one way the SDK makes an HTTP request. `EmberClient` speaks only to this, so tests and
/// previews hand it a stand-in (EmberTesting's `MockHTTPTransport`) and nothing touches the network.
///
/// A transport sends the request as it is and answers whatever the server said, any status included:
/// it throws only when there was no answer at all. Cookies are `EmberClient`'s business, not the
/// transport's.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and answers the server's body and response, whatever its status.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Sends `body` as the request's body, telling `progress` the bytes sent so far as they go.
    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    /// Sends `body` as the request's `httpBody`, and counts all of it sent once the server has
    /// answered: a transport that can't tell any sooner still uploads.
    public func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.httpBody = body
        let answer = try await send(request)
        progress(body.count)
        return answer
    }
}

/// The real transport: a `URLSession`.
///
/// `EmberClient` attaches and keeps cookies itself, so a session given here should leave cookies
/// alone (`httpShouldSetCookies = false`), as `URLSessionHTTPTransport.makeSession()` does.
public struct URLSessionHTTPTransport: HTTPTransport {
    /// The session requests go through.
    public let session: URLSession

    /// A transport on `session`.
    public init(session: URLSession) {
        self.session = session
    }

    /// A session that leaves cookies to `EmberClient` and doesn't cache, for the SDK's own use.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    /// Sends `request` on the session. A redirect to another origin goes without the request's
    /// `Cookie`, `Origin` and `Sec-Fetch-Site`, which are for the server it was sent to.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Uploads `body` on the session, telling `progress` the bytes sent as the task reports them.
    /// Redirects are guarded as `send` guards them.
    public func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.httpBody = nil
        let (data, response) = try await session.upload(for: request, from: body, delegate: UploadProgress(progress))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        progress(body.count)
        return (data, http)
    }
}

/// Hears an upload task's bytes go, and guards its redirects as `RedirectGuard` does.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let progress: @Sendable (Int) -> Void

    init(_ progress: @escaping @Sendable (Int) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(Int(totalBytesSent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        RedirectGuard.guarded(request, from: task.originalRequest?.url)
    }
}

/// Strips a request's own server's headers from a redirect that leaves it, since URLSession carries
/// headers set by hand across.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        Self.guarded(request, from: task.originalRequest?.url)
    }

    /// `request` without the headers that were for `from`'s server, when it goes somewhere else.
    static func guarded(_ request: URLRequest, from: URL?) -> URLRequest {
        guard let from, let to = request.url, !EmberClient.sameOrigin(from, to) else { return request }
        var request = request
        for header in ["Cookie", "Origin", "Sec-Fetch-Site"] { request.setValue(nil, forHTTPHeaderField: header) }
        return request
    }
}

/// Why a socket ended, as far as it's known: the close code the server sent, or the HTTP status it
/// answered the upgrade with instead of letting the socket in. Both nil when the network dropped it.
public struct SocketClosed: Error, Equatable, Sendable {
    /// The WebSocket close code, such as `SocketClose.revoked` (4003).
    public var closeCode: Int?
    /// The status an upgrade was refused with, such as 401 when the session is gone.
    public var httpStatus: Int?

    /// Why a socket ended.
    public init(closeCode: Int? = nil, httpStatus: Int? = nil) {
        self.closeCode = closeCode
        self.httpStatus = httpStatus
    }
}

/// One live WebSocket, as `ReconnectingSocket` drives it.
public protocol SocketConnection: Sendable {
    /// Waits until the server has let the socket in, throwing `SocketClosed` when it refuses or the
    /// socket ends first. A connection that can't tell may return at once (the default does).
    func waitUntilOpen() async throws
    /// Sends one text frame.
    func send(_ text: String) async throws
    /// The next text frame. Throws `SocketClosed` once the socket has ended.
    func receive() async throws -> String
    /// Closes the socket from this side. Anything waiting on it then throws `SocketClosed`.
    func close()
}

extension SocketConnection {
    /// Counts the socket as open at once; the first `receive` then says whether it really is.
    public func waitUntilOpen() async throws {}
}

/// Opens sockets. `ReconnectingSocket` asks it for each attempt, so a test hands it EmberTesting's
/// `MockSocketConnector` and scripts the server's side.
public protocol SocketConnector: Sendable {
    /// Starts connecting to `request`'s address and answers the connection at once; it opens later.
    func connect(_ request: URLRequest) -> any SocketConnection
}

/// The real connector: `URLSessionWebSocketTask`s on a session.
///
/// It sends the request's headers as they are (`EmberClient` sets `Origin` and `Cookie`), so the
/// session shouldn't attach cookies of its own.
public struct URLSessionSocketConnector: SocketConnector {
    /// The session sockets open on.
    public let session: URLSession

    /// A connector on `session`.
    public init(session: URLSession) {
        self.session = session
    }

    /// Starts a WebSocket task for `request`.
    public func connect(_ request: URLRequest) -> any SocketConnection {
        URLSessionSocketConnection(task: session.webSocketTask(with: request))
    }
}

/// A `URLSessionWebSocketTask` as a `SocketConnection`. The task's own delegate says when it opens
/// and how it ended, which is how a refused upgrade's status and a close code are told apart.
final class URLSessionSocketConnection: NSObject, SocketConnection, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var opened = false
    private var ended: SocketClosed?
    private var openWaiters: [CheckedContinuation<Void, any Error>] = []

    init(task: URLSessionWebSocketTask) {
        self.task = task
        super.init()
        task.delegate = self
        // Larger than the server's biggest frame (a page of long messages), which the default 1 MiB isn't always.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    func waitUntilOpen() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if let ended {
                    lock.unlock()
                    continuation.resume(throwing: ended)
                } else if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    openWaiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            close()
        }
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw end(with: closure())
        }
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            throw end(with: closure())
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        end(with: SocketClosed())
    }

    /// How the task ended, as far as it says.
    private func closure() -> SocketClosed {
        let code = task.closeCode.rawValue
        let status = (task.response as? HTTPURLResponse)?.statusCode
        return SocketClosed(closeCode: code == 0 ? nil : code, httpStatus: status == 101 ? nil : status)
    }

    /// Records the first way it ended, which wins over what's learnt later, and wakes anyone waiting.
    @discardableResult
    private func end(with closed: SocketClosed) -> SocketClosed {
        lock.lock()
        let first = ended ?? closed
        ended = first
        let waiters = openWaiters
        openWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume(throwing: first) }
        return first
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        opened = true
        let waiters = openWaiters
        openWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        end(with: SocketClosed(closeCode: closeCode.rawValue == 0 ? nil : closeCode.rawValue))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        end(with: closure())
    }
}
