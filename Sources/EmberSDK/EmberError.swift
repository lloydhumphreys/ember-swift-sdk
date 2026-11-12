import Foundation

/// What every request and socket in the SDK fails with: the server's answer, or that there wasn't one.
///
/// Ember answers a refusal as `{ "error": message }`, sometimes with the form `field` it's about, and
/// the `message` is meant to be shown as it is.
public struct EmberError: Error, LocalizedError, Equatable, Sendable {
    /// What sort of failure it is, apart from its status.
    public enum Kind: Equatable, Sendable {
        /// The server didn't answer at all: offline, or the address is wrong.
        case unreachable
        /// The server answered with a status that isn't success; `status` is it.
        case http
        /// The server answered, but not in a shape the SDK could read; `status` is what it answered with.
        case undecodable
        /// A file on this device couldn't be read. Nothing was sent.
        case unreadableFile
        /// The SDK refused it before sending, as the server would have: too long, or no name.
        case invalid
        /// The room's socket answered with an error frame.
        case refused
        /// No answer came in time.
        case timedOut
    }

    /// The HTTP status; 0 when the server didn't answer at all, and for errors that aren't HTTP's.
    public var status: Int
    /// The server's `{ "error": … }`, or a short one of the SDK's own.
    public var message: String
    /// The server's `{ "field": … }`, when it names the form field the error is about.
    public var field: String?
    /// What sort of failure it is.
    public var kind: Kind

    /// An error with the given status, message and field: unreachable for status 0, an HTTP
    /// failure otherwise.
    public init(status: Int, message: String, field: String? = nil) {
        self.init(kind: status == 0 ? .unreachable : .http, status: status, message: message, field: field)
    }

    /// An error of the given kind.
    public init(kind: Kind, status: Int = 0, message: String, field: String? = nil) {
        self.kind = kind
        self.status = status
        self.message = message
        self.field = field
    }

    /// The server doesn't know this session any more (401): the app should go back to signing in.
    public var isSignedOut: Bool { status == 401 }
    /// The server didn't answer at all: offline, or the address is wrong.
    public var isUnreachable: Bool { kind == .unreachable }
    /// The message, as `LocalizedError` shows it.
    public var errorDescription: String? { message }
}

extension EmberError {
    /// What a request that never got an answer fails with.
    static func unreachable(_ origin: URL) -> EmberError {
        EmberError(status: 0, message: "Couldn’t reach \(origin.host() ?? origin.absoluteString).")
    }

    /// What an answer the SDK couldn't read fails with.
    static func unreadable(status: Int) -> EmberError {
        EmberError(kind: .undecodable, status: status, message: "The server’s answer couldn’t be read.")
    }

    /// What a file on this device that can't be read fails with.
    static let unreadableFile = EmberError(kind: .unreadableFile, message: "That file can’t be read.")

    /// The error a refusal's body describes, falling back to the status's own wording.
    static func refusal(status: Int, data: Data) -> EmberError {
        struct Body: Decodable {
            var error: String?
            var field: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let message = body?.error.flatMap { $0.isEmpty ? nil : $0 }
            ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalizedFirst
        return EmberError(status: status, message: message, field: body?.field)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
