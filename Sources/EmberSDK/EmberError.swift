import Foundation

/// What every request and socket in the SDK fails with: the server's answer, or that there wasn't one.
///
/// Ember answers a refusal as `{ "error": message }`, sometimes with the form `field` it's about, and
/// the `message` is meant to be shown as it is.
public struct EmberError: Error, LocalizedError, Equatable, Sendable {
    /// The HTTP status; 0 when the server didn't answer at all.
    public var status: Int
    /// The server's `{ "error": … }`, or a short one of the SDK's own.
    public var message: String
    /// The server's `{ "field": … }`, when it names the form field the error is about.
    public var field: String?

    /// An error with the given status, message and field.
    public init(status: Int, message: String, field: String? = nil) {
        self.status = status
        self.message = message
        self.field = field
    }

    /// The server doesn't know this session any more (401): the app should go back to signing in.
    public var isSignedOut: Bool { status == 401 }
    /// The server didn't answer at all: offline, or the address is wrong.
    public var isUnreachable: Bool { status == 0 }
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
        EmberError(status: status, message: "The server’s answer couldn’t be read.")
    }

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
