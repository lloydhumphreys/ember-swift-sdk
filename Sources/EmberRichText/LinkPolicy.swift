import Foundation

/// What a client may hand to the system when a person taps a link. `RichText` keeps more schemes than
/// this in a document (the server's safe list); the system should open fewer.
public enum LinkPolicy {
    /// Schemes a client should hand to the system when a person taps a link.
    public static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// Whether `url` is safe to open: its scheme is in `openableSchemes` (any case), and an http or https
    /// address names a host.
    public static func opens(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else { return false }
        if scheme == "http" || scheme == "https" { return !(url.host(percentEncoded: false) ?? "").isEmpty }
        return true
    }
}
