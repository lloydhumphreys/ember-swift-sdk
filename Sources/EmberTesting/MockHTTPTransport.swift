import Foundation
import EmberSDK

/// Answers requests from stubs and records what was asked. Safe to use from any thread.
///
/// A stub's path matches a request's path, or its path and query when the stub has a `?`. The
/// latest stub for a request wins, so a test can change an answer partway through. A request no
/// stub matches is answered 404, as the server answers an unknown path.
public final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    /// What a stub answers.
    public struct Answer: Sendable {
        public var status: Int
        public var json: String
        public var headers: [String: String]

        /// An answer with `status`, `json` as its body, and any extra headers, such as `Set-Cookie`.
        public init(status: Int = 200, json: String, headers: [String: String] = [:]) {
            self.status = status
            self.json = json
            self.headers = headers
        }
    }

    private struct Stub {
        var method: String
        var path: String
        var answer: @Sendable (URLRequest) throws -> Answer
    }

    private let lock = NSLock()
    private var stubs: [Stub] = []
    private var recorded: [URLRequest] = []
    private var gates: [(method: String, path: String, gate: MockGate)] = []

    /// A transport with no stubs.
    public init() {}

    /// Answers `method path` with `status` and `json`.
    public func stub(_ method: String, _ path: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        let answer = Answer(status: status, json: json, headers: headers)
        stub(method, path, answer: { _ in answer })
    }

    /// Answers `method path` with whatever `answer` makes of the request. Throwing stands for the
    /// network failing.
    public func stub(_ method: String, _ path: String, _ answer: @escaping @Sendable (URLRequest) throws -> (status: Int, json: String)) {
        stub(method, path, answer: { request in
            let (status, json) = try answer(request)
            return Answer(status: status, json: json)
        })
    }

    /// Answers `method path` with whatever `answer` makes of the request, headers included.
    ///
    /// Disfavoured so a trailing closure that only throws picks the simpler overload above
    /// rather than being ambiguous between the two.
    @_disfavoredOverload
    public func stub(_ method: String, _ path: String, answer: @escaping @Sendable (URLRequest) throws -> Answer) {
        lock.withLock { stubs.append(Stub(method: method.uppercased(), path: path, answer: answer)) }
    }

    /// Holds the next request to `method path` until the test calls `release()` on the gate, so a
    /// test can make answers land in the order it wants. Each gate holds one request; the stub
    /// that answers it is the one that matches when it's released.
    public func hold(_ method: String, _ path: String) -> MockGate {
        let gate = MockGate()
        lock.withLock { gates.append((method.uppercased(), path, gate)) }
        return gate
    }

    /// Stands for a server that can't be reached: every request fails as the network does.
    public func failEverything() {
        stub("*", "*", answer: { _ in throw URLError(.cannotConnectToHost) })
    }

    /// Forgets every stub and every request.
    public func reset() {
        lock.withLock {
            stubs = []
            recorded = []
            gates = []
        }
    }

    /// Every request sent, in order, with the headers the client attached.
    public var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    /// The requests sent to `method path` (the path alone, or with its query when it has a `?`).
    public func requests(_ method: String, _ path: String) -> [URLRequest] {
        requests.filter { Self.matches(method: method.uppercased(), path: path, $0) }
    }

    /// The JSON body of the latest request to `method path`, as an object, for checking what was sent.
    public func lastBody(_ method: String, _ path: String) -> [String: Any]? {
        guard let body = requests(method, path).last?.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    /// The bodies sent to `method path`, in order: the raw bytes of an upload's parts, say.
    public func bodies(_ method: String, _ path: String) -> [Data] {
        requests(method, path).map { $0.httpBody ?? Data() }
    }

    /// Answers the three upload routes in `roomID` for `ticket`: the start with the ticket (201),
    /// each part but the last with 204, the last with `message` (201), and the preview with 204.
    public func stubUpload(in roomID: RoomID, ticket: UploadTicket, message: Message) {
        let uploads = "/api/rooms/\(roomID)/uploads"
        stub("POST", uploads, status: 201, json: Fixtures.uploadTicketJSON(ticket))
        for part in 1 ... max(ticket.parts, 1) {
            let path = "\(uploads)/\(ticket.id)/parts/\(part)"
            if part == max(ticket.parts, 1) {
                stub("PUT", path, status: 201, json: Fixtures.messageJSON(message))
            } else {
                stub("PUT", path, status: 204, json: "")
            }
        }
        stub("PUT", "\(uploads)/\(ticket.id)/preview", status: 204, json: "")
    }

    /// Records the request with `body` as its `httpBody`, answers it as `send` does, and reports the
    /// whole body sent once it's answered.
    public func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Int) -> Void) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.httpBody = body
        let answer = try await send(request)
        progress(body.count)
        return answer
    }

    /// Answers `request` from the latest stub that matches it.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let gate = lock.withLock { () -> MockGate? in
            recorded.append(request)
            guard let index = gates.firstIndex(where: { Self.matches(method: $0.method, path: $0.path, request) }) else { return nil }
            return gates.remove(at: index).gate
        }
        if let gate { await gate.pass() }
        let stub = lock.withLock {
            stubs.last { Self.matches(method: $0.method, path: $0.path, request) }
        }
        let answer = try stub?.answer(request) ?? Answer(status: 404, json: #"{"error":"Not found"}"#)
        var headers = answer.headers
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        let url = request.url ?? URL(string: "http://localhost")!
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(answer.json.utf8), response)
    }

    private static func matches(method: String, path: String, _ request: URLRequest) -> Bool {
        if method == "*" && path == "*" { return true }
        guard method == (request.httpMethod ?? "GET").uppercased(), let url = request.url else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let requestPath = components?.percentEncodedPath ?? url.path
        if path.contains("?") {
            return path == requestPath + "?" + (components?.percentEncodedQuery ?? "")
        }
        return path == requestPath
    }
}

/// A request held by `MockHTTPTransport.hold(_:_:)` until `release()`. Safe to use from any thread.
public final class MockGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var isReached = false
    private var held: CheckedContinuation<Void, Never>?
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Whether a request has reached the gate.
    public var hasRequest: Bool {
        lock.withLock { isReached }
    }

    /// Waits until a request reaches the gate.
    public func waitForRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isReached {
                lock.unlock()
                continuation.resume()
            } else {
                reachWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Lets the request through, now or when it comes.
    public func release() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isReleased = true
            defer { self.held = nil }
            return self.held
        }
        held?.resume()
    }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            isReached = true
            let waiters = reachWaiters
            reachWaiters = []
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                held = continuation
                lock.unlock()
            }
            for waiter in waiters { waiter.resume() }
        }
    }
}
