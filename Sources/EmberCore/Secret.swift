/// Text that lets someone in, such as a sign-in link's id or an invitation's link.
///
/// It prints as `<redacted>` in descriptions, debug prints, mirrors and `dump`. Only `revealed` gives
/// the text, for the one place it's meant to go. It can be read from the server but isn't `Encodable`,
/// so it can't end up in a log or a saved file by accident.
public struct Secret: Decodable, Hashable, Sendable {
    /// The text itself.
    public let revealed: String

    /// A secret holding `text`.
    public init(_ text: String) {
        revealed = text
    }

    public init(from decoder: any Decoder) throws {
        revealed = try decoder.singleValueContainer().decode(String.self)
    }
}

extension Secret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
