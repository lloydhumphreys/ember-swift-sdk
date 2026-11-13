import Foundation

/// A sign-in link someone pasted, as Ember's web shows one on a profile or a person's page:
/// `https://chat.example.com/session/transfers#token=<id>`. `EmberClient.signIn(transferID:)` signs in
/// with its id, on a client for its origin.
public struct SignInLink: Hashable, Sendable {
    /// The server the link is for, such as `https://chat.example.com`.
    public var origin: URL
    /// The id that signs in.
    public var transferID: Secret

    /// A link to `origin` with `transferID`.
    public init(origin: URL, transferID: Secret) {
        self.origin = origin
        self.transferID = transferID
    }

    /// The link in `text`, or nil when it isn't one: another address, no id, or anything but an
    /// http(s) link. Spaces and line breaks around it are ignored.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path == Self.path || components.path == Self.path + "/",
              let fragment = components.percentEncodedFragment,
              let url = components.url
        else { return nil }
        // The fragment reads as a query does, as the web's `URLSearchParams` reads it.
        var query = URLComponents()
        query.percentEncodedQuery = fragment
        guard let id = query.queryItems?.first(where: { $0.name == "token" })?.value,
              Self.isTransferID(id)
        else { return nil }
        self.init(origin: ServerAddress.normalizedOrigin(url), transferID: Secret(id))
    }

    /// The path a sign-in link opens.
    static let path = "/session/transfers"

    /// Whether `id` is shaped as the server makes one: letters, digits, dots, dashes and underscores.
    static func isTransferID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 512 && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }
}

extension SignInLink: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SignInLink(\(origin.absoluteString), transferID: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["origin": origin, "transferID": transferID], displayStyle: .struct) }
}
