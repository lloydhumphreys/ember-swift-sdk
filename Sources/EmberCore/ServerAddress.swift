import Foundation

/// Turns what someone typed for their server into its origin, and back into something to show.
public enum ServerAddress {
    /// What someone typed, as the server's origin: adds `https://` (or `http://` for localhost,
    /// 127.0.0.1, [::1] and *.localhost, which rarely have certificates), keeps an explicit scheme and
    /// port, and drops any path, query and fragment. nil when there's no host, or the scheme isn't
    /// http or https.
    public static func origin(from typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let typedScheme = trimmed.range(of: "://") != nil
        guard let parsed = URLComponents(string: typedScheme ? trimmed : "https://" + trimmed),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parsed.host?.lowercased(), !host.isEmpty
        else { return nil }

        var origin = URLComponents()
        origin.scheme = typedScheme ? scheme : (isLocal(host) ? "http" : "https")
        // URLComponents wants an IPv6 host bracketed, the way it reads one.
        origin.percentEncodedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        origin.port = parsed.port
        return origin.url
    }

    /// `host` or `host:port`, for showing.
    public static func display(_ origin: URL) -> String {
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let host = components.percentEncodedHost, !host.isEmpty
        else { return origin.absoluteString }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }

    private static func isLocal(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare.hasSuffix(".localhost") || bare == "127.0.0.1" || bare == "::1"
    }
}
