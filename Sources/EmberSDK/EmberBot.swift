import Foundation

/// A bot's way into one room, through the server's keyed bot API (`/rooms/<room id>/<bot key>/messages`).
///
/// The key is all a bot has: there is no session, no cookie and no socket. A bot posts text, HTML or a
/// file to the room it is in, and boosts a message there. It is made from a server address, a room id
/// and the bot's key, and it sends through the SDK's `HTTPTransport`, so a test hands it
/// EmberTesting's `MockHTTPTransport`.
///
/// The key is in every request's address and nowhere else: it is never in a description, a debug
/// print, a mirror or an error. Every method fails with `EmberError`, whose `message` is the server's
/// own words when it gave any. The server answers some refusals with no body at all, such as 422 for
/// a blank message and 404 for a bot that isn't in the room, and those read as their status's wording.
public struct EmberBot: Sendable {
    /// The server's origin, such as `https://chat.example.com`.
    public let origin: URL
    /// The room the bot posts to.
    public let roomID: RoomID
    /// Where requests go.
    public let transport: any HTTPTransport

    private let key: String

    /// A bot for `roomID` on the server at `origin`, whose key is `key`: the `<id>-<token>` text the
    /// server shows when the bot is made. Requests go through `transport`, which defaults to a
    /// `URLSession` that keeps no cookies.
    public init(origin: URL, roomID: RoomID, key: String, transport: any HTTPTransport = URLSessionHTTPTransport(session: URLSessionHTTPTransport.makeSession())) {
        self.origin = Self.bareOrigin(origin)
        self.roomID = roomID
        self.key = key
        self.transport = transport
    }

    /// A message the bot posted.
    public struct PostedMessage: Equatable, Sendable {
        /// The message's id.
        public var id: String
        /// Where the server shows the message: its permalink, from the answer's `Location`.
        public var url: URL

        public init(id: String, url: URL) {
            self.id = id
            self.url = url
        }
    }

    /// A boost the bot added, as the server answers it.
    public struct Boost: Decodable, Equatable, Sendable {
        /// The boost's id.
        public var id: String
        /// What the boost says, trimmed by the server.
        public var content: String
        /// The id of the message it is on.
        public var messageID: String

        public init(id: String, content: String, messageID: String) {
            self.id = id
            self.content = content
            self.messageID = messageID
        }

        private enum CodingKeys: String, CodingKey { case id, content, message }
        private struct Target: Decodable { var id: String }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            content = try container.decode(String.self, forKey: .content)
            messageID = try container.decode(Target.self, forKey: .message).id
        }
    }

    // MARK: Posting

    /// Posts text typed in plain, escaped as `RoomSession.send(text:)` escapes it, so `<b>` shows as
    /// typed, with each line on its own. The server reads a body as the message's markup whatever its
    /// type, so the escaped markup is what's sent, typed `text/html`. Throws `.invalid`, sending
    /// nothing, for text that's blank or over `Limits.message` characters.
    @discardableResult
    public func post(text: String) async throws -> PostedMessage {
        let message = try PlainTextMessage(text)
        return try await post(html: message.body)
    }

    /// `POST /rooms/:room/:key/messages` with `html` as the body, typed `text/html`.
    @discardableResult
    public func post(html: String) async throws -> PostedMessage {
        try await postBody(html, type: "text/html; charset=utf-8")
    }

    /// Posts a file as the bot's message: a multipart form with the bytes as its `attachment`, as
    /// `curl -F "attachment=@file"` sends one. `contentType` is what the server uses when the bytes
    /// don't say what they are.
    @discardableResult
    public func post(file: Data, named name: String, contentType: String = "application/octet-stream") async throws -> PostedMessage {
        let form = MultipartForm(field: "attachment", filename: name, contentType: contentType, data: file)
        var request = try messagesRequest("POST")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request, body: form.body)
        return try posted(response, data: data)
    }

    /// Posts the file at `url`, named as it is, as `post(file:named:contentType:)` does. Throws when
    /// the file can't be read.
    @discardableResult
    public func post(fileAt url: URL, contentType: String = "application/octet-stream") async throws -> PostedMessage {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw EmberError.unreadableFile
        }
        return try await post(file: data, named: url.lastPathComponent, contentType: contentType)
    }

    /// `POST /rooms/:room/:key/messages/:id/boosts` with `content` as the body: boosts the message
    /// as the bot. The server trims the content, and refuses one that is blank or longer than
    /// `Limits.boost`.
    @discardableResult
    public func boost(_ messageID: String, with content: String) async throws -> Boost {
        var request = try request("POST", path: "messages/\(Self.segment(messageID))/boosts")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request, body: Data(content.utf8))
        do {
            return try JSONDecoder().decode(Boost.self, from: data)
        } catch {
            throw EmberError.unreadable(status: response.statusCode)
        }
    }

    // MARK: Requests

    private func postBody(_ body: String, type: String) async throws -> PostedMessage {
        var request = try messagesRequest("POST")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request, body: Data(body.utf8))
        return try posted(response, data: data)
    }

    private func messagesRequest(_ method: String) throws -> URLRequest {
        try request(method, path: "messages")
    }

    /// A request to `path` under the bot's address. Its URL is built here from parts, so the key
    /// can't reach another route.
    private func request(_ method: String, path: String) throws -> URLRequest {
        let address = "/rooms/\(Self.segment(roomID))/\(Self.segment(key))/\(path)"
        guard let url = URL(string: address, relativeTo: origin)?.absoluteURL else {
            throw EmberError(status: 0, message: "That isn’t an address on this server.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Sends `request` with `body` and answers a 2xx; anything else throws the server's `EmberError`.
    /// A transport that failed says only which server couldn't be reached.
    private func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.upload(request, body: body, progress: { _ in })
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw CancellationError() }
            throw EmberError.unreachable(origin)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw EmberError.refusal(status: response.statusCode, data: data)
        }
        return (data, response)
    }

    /// The message a 201's `Location` names: its permalink, `…/rooms/<room>/@<message id>`.
    private func posted(_ response: HTTPURLResponse, data: Data) throws -> PostedMessage {
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: origin)?.absoluteURL,
              let marker = location.range(of: "/@", options: .backwards)
        else { throw EmberError.unreadable(status: response.statusCode) }
        let id = String(location[marker.upperBound...]).removingPercentEncoding ?? ""
        guard !id.isEmpty else { throw EmberError.unreadable(status: response.statusCode) }
        return PostedMessage(id: id, url: url)
    }

    /// `EmberClient.segment`, with a segment of only dots escaped too, so it can't be read as `.` or `..`.
    private static func segment(_ text: String) -> String {
        let escaped = EmberClient.segment(text)
        return !escaped.isEmpty && escaped.allSatisfy { $0 == "." } ? escaped.replacingOccurrences(of: ".", with: "%2E") : escaped
    }

    private static func bareOrigin(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url ?? url
    }
}

// MARK: - Keeping the key out

extension EmberBot: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "EmberBot(\(origin.absoluteString), room: \(roomID))" }
    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin, "roomID": roomID], displayStyle: .struct)
    }
}

// MARK: - The form a file goes in

/// One `multipart/form-data` field holding a file.
private struct MultipartForm {
    let contentType: String
    let body: Data

    init(field: String, filename: String, contentType fileType: String, data: Data) {
        let boundary = "ember-\(UUID().uuidString)"
        contentType = "multipart/form-data; boundary=\(boundary)"
        let name = filename
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
        let type = fileType.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        self.body = body
    }
}
