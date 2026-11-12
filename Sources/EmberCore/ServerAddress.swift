import Foundation

/// Turns what someone typed for their server into its origin, and back into something to show.
public enum ServerAddress {
    /// What someone typed, as the server's origin: adds `https://`, or `http://` for an address on
    /// this device or the local network (see `isLocal(_:)`), which rarely has a certificate; keeps an
    /// explicit scheme and any port but the scheme's own, and drops any path, query and fragment.
    /// nil when there's no host, or the scheme isn't http or https.
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
        origin.port = parsed.port == defaultPort(of: origin.scheme) ? nil : parsed.port
        return origin.url
    }

    /// `url`'s origin as a browser writes it, and as Ember compares the `Origin` header: the scheme
    /// and host lowercased, no port when it's the scheme's own, and no path, query, fragment or
    /// credentials. `https://Chat.Example.com:443/ember/` is `https://chat.example.com`.
    public static func normalizedOrigin(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = components.scheme?.lowercased()
        if let host = components.percentEncodedHost { components.percentEncodedHost = host.lowercased() }
        if components.port == defaultPort(of: components.scheme) { components.port = nil }
        components.percentEncodedPath = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    /// `host` or `host:port`, for showing.
    public static func display(_ origin: URL) -> String {
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let host = components.percentEncodedHost, !host.isEmpty
        else { return origin.absoluteString }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }

    /// Whether `host` is on this device or the local network, where a server rarely has a
    /// certificate: `localhost` and `*.localhost`, `*.local`, a loopback address (127/8, ::1), and a
    /// private or link-local IPv4 address (10/8, 172.16/12, 192.168/16, 169.254/16).
    public static func isLocal(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let name = bare.hasSuffix(".") ? String(bare.dropLast()) : bare
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        if name == "::1" { return true }
        guard let octets = ipv4(name) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Whether `origin` asks for plain `http` to a host App Transport Security won't let an app reach
    /// that way: anything that isn't local (`isLocal(_:)`) or a bare name with no dot, which an app
    /// allowing local networking may load. Nothing is sent to such an address, so an app can say
    /// https is needed rather than that the server couldn't be reached.
    public static func needsHTTPS(_ origin: URL) -> Bool {
        guard origin.scheme?.lowercased() == "http",
              let host = URLComponents(url: origin, resolvingAgainstBaseURL: false)?.percentEncodedHost?.lowercased(),
              !host.isEmpty
        else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLocal(bare) { return false }
        let isName = !bare.contains(":") && ipv4(bare) == nil
        return !(isName && !bare.contains("."))
    }

    /// The four numbers of a dotted IPv4 address, or nil when `text` isn't one.
    private static func ipv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(part), (0...255).contains(number) else { return nil }
            return number
        }
        return numbers.count == 4 ? numbers : nil
    }

    private static func defaultPort(of scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https", "wss": return 443
        case "http", "ws": return 80
        default: return nil
        }
    }
}
