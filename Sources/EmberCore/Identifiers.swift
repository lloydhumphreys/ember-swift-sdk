import Foundation

/// An id the server gave something, as a type of its own, so one kind of id can't be passed where
/// another is wanted. It holds the server's string as given, never checked or changed, and reads and
/// writes as that bare string: in JSON, as a dictionary's key, in a path and in `"\(id)"`. Make one
/// from a literal, `"msg_\(n)"`, or a string you have, `MessageID(text)`; `rawValue` is the string.
public protocol EmberIdentifier: RawRepresentable, Codable, CodingKeyRepresentable, Hashable, Sendable, Comparable,
    CustomStringConvertible, CustomDebugStringConvertible, ExpressibleByStringInterpolation
    where RawValue == String, StringLiteralType == String {
    init(rawValue: String)
}

extension EmberIdentifier {
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(rawValue: codingKey.stringValue)
    }

    public var codingKey: CodingKey { IdentifierKey(stringValue: rawValue) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }

    /// The type and the string, as `MessageID("m1")`.
    public var debugDescription: String { "\(Self.self)(\(rawValue.debugDescription))" }
}

/// A dictionary key that is an id's string.
private struct IdentifierKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Someone: a person, a bot or the assistant.
public struct UserID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A room of any kind.
public struct RoomID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A message the room stored, a thread's parent and its replies among them.
public struct MessageID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The id a sender's app gives a message before the room stores it, which matches the two up.
public struct ClientMessageID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A boost on a message.
public struct BoostID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A file on its way up, as starting the upload answers it.
public struct UploadID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A file message's stored file.
public struct FileID: EmberIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
