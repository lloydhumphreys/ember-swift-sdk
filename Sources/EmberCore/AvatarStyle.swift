import Foundation

// A port of packages/protocol/src/avatars.ts: Campfire's generated avatars, someone's initials in white
// on one of 18 colours picked by the CRC32 of their id.

/// How someone's generated avatar looks, to draw it while their served one loads, or in its place.
public enum AvatarStyle {
    /// The 18 colours, as `#RRGGBB`.
    public static let colours = [
        "#AF2E1B", "#CC6324", "#3B4B59", "#BFA07A", "#ED8008", "#ED3F1C", "#BF1B1B", "#736B1E", "#D07B53",
        "#736356", "#AD1D1D", "#BF7C2A", "#C09C6F", "#698F9C", "#7C956B", "#5D618F", "#3B3633", "#67695E",
    ]

    /// The colour of someone's avatar as hex, the one the CRC32 of their id picks.
    public static func hex(for userID: UserID) -> String {
        colours[Int(crc32(userID) % UInt32(colours.count))]
    }

    /// The colour of someone's avatar, each component from 0 to 1.
    public static func colour(for userID: UserID) -> (red: Double, green: Double, blue: Double) {
        let value = UInt32(hex(for: userID).dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// Campfire's `name.scan(/\b\w/).join`: every ASCII letter, digit or underscore that doesn't follow a
    /// letter, digit or underscore of any script, as many as there are. So "Élodie" has none, and
    /// "Élodie Ünal-Smith o'Brien 3po _x ñ" is "SoB3_". Three or more are squeezed to fit when drawn.
    public static func initials(of name: String) -> String {
        var found = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in name.unicodeScalars {
            if isASCIIWord(scalar), !(previous.map(isWord) ?? false) { found.append(scalar) }
            previous = scalar
        }
        return String(found)
    }

    /// The initials to draw in a small circle: Campfire's, but no more than `limit` of them, the
    /// first and then the last, so "David Heinemeier Hansson" is "DH" and "Dirk van den Berg" is
    /// "DB". A name Campfire finds none in, such as "Élodie", has its first letter or digit of any
    /// script instead, so the circle isn't left empty.
    public static func initials(of name: String, atMost limit: Int) -> String {
        guard limit > 0 else { return "" }
        let all = Array(initials(of: name))
        if all.isEmpty {
            return name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? ""
        }
        guard all.count > limit else { return String(all) }
        guard limit > 1 else { return String(all[0]) }
        return String(all.prefix(limit - 1) + [all[all.count - 1]])
    }

    /// zlib's CRC32 of `text` as UTF-8, which Ruby's `Zlib.crc32` gives too.
    static func crc32(_ text: String) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in text.utf8 {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func isASCIIWord(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_")
    }

    /// What Ruby's `\b` counts as part of a word: a letter or number of any script, or `_`.
    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || scalar.properties.isAlphabetic { return true }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
}
