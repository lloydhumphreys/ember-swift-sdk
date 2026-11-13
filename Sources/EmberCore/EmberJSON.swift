import Foundation

/// JSON as Ember writes it. Dates are ISO 8601 strings, as JavaScript's `toISOString` writes them
/// (`2026-10-12T10:00:00.000Z`), though a date without fractional seconds reads just as well, since
/// some of the server's dates come from SQLite without them.
public enum EmberJSON {
    /// A decoder for anything the server sends: HTTP answers and socket frames alike.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    /// An encoder for anything sent to the server, writing dates with milliseconds as the web does.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    /// A date as Ember writes one, or nil for anything else.
    public static func date(from text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    /// `date` as JavaScript's `toISOString` writes it: UTC, with milliseconds.
    public static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// `encodeURIComponent`, as the web's addresses escape a value: everything but ASCII letters, digits
/// and `-_.!~*'()` becomes its UTF-8 bytes, percent-escaped in upper case.
func encodeURIComponent(_ value: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(value.utf8.count)
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "!"), UInt8(ascii: "~"),
             UInt8(ascii: "*"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
            escaped.unicodeScalars.append(Unicode.Scalar(byte))
        default:
            escaped += String(format: "%%%02X", byte)
        }
    }
    return escaped
}

/// Whether `a` sorts before `b` as JavaScript's `<` compares strings: by UTF-16 code unit. Ids are
/// compared this way upstream, and Swift's own `<` can differ outside ASCII.
func jsLess(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

/// Whether id `a` sorts before `b` as the server sorts them: `jsLess` on their strings.
func jsLess<ID: EmberIdentifier>(_ a: ID, _ b: ID) -> Bool {
    jsLess(a.rawValue, b.rawValue)
}
