import Foundation

/// Link previews: reading the opengraph embed attachment (attachments.ts `opengraphEmbedFromNode`)
/// and the rule that a message that is only a link shows just its preview (previews.ts).
enum PreviewReader {
    static let attachmentTag = "action-text-attachment"
    static let mentionContentType = "application/vnd.campfire.mention"
    static let embedContentType = "application/vnd.actiontext.opengraph-embed"
    private static let twitterAvatarPrefix = "https://pbs.twimg.com/profile_images"

    /// The `RichPreview` an attachment makes, or nil for an empty one (no title, address, text or image).
    static func preview(from attachment: HTMLNode, host: String) -> RichPreview? {
        let embed = embedDetails(attachment, host: host)
        let title: String
        if let filename = embed.filename {
            title = truncate(filename, 280)
        } else {
            title = embed.href ?? ""
        }
        let description = truncate(embed.description ?? "", 560)
        if title.isEmpty, embed.href == nil, description.isEmpty, embed.image == nil { return nil }
        return RichPreview(
            title: title,
            href: embed.href,
            description: description,
            image: embed.image,
            isAvatar: embed.image?.hasPrefix(twitterAvatarPrefix) ?? false
        )
    }

    struct Embed {
        var href: String?
        var image: String?
        var filename: String?
        var description: String?
    }

    /// Trix writes the details as attributes when `filename` names a file; Lexxy writes markup in `content`.
    static func embedDetails(_ attachment: HTMLNode, host: String) -> Embed {
        let filename = attachment.attribute("filename")
        if let filename, !isBlank(filename) {
            return Embed(
                href: webURL(attachment.attribute("href"), host: host),
                image: webURL(attachment.attribute("url"), host: host),
                filename: filename,
                description: attachment.attribute("caption")
            )
        }
        return embedFromContent(attachment.attribute("content") ?? "", host: host)
    }

    /// The first `.og-embed__title` (its first link), the first image inside an `.og-embed__image` and
    /// the first `.og-embed__description`, as the server's `attributes_from_content` finds them.
    private static func embedFromContent(_ content: String, host: String) -> Embed {
        guard let root = try? HTMLTreeBuilder.parse(content) else { return Embed() }
        let elements = root.descendantElements()
        let title = elements.first { hasClass($0, "og-embed__title") }
        let link = title?.descendantElements().first { $0.name == "a" }
        let image = elements.first { element in
            element.name == "img" && elements.contains { ancestor in
                hasClass(ancestor, "og-embed__image") && ancestor.descendantElements().contains { $0 === element }
            }
        }
        let description = elements.first { hasClass($0, "og-embed__description") }
        let named = link ?? title
        return Embed(
            href: webURL(link?.attribute("href"), host: host),
            image: webURL(image?.attribute("src"), host: host),
            filename: named.map { strip($0.textContent) },
            description: description.map { strip($0.textContent) }
        )
    }

    private static func hasClass(_ element: HTMLNode, _ name: String) -> Bool {
        (element.attribute("class") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).contains { $0 == name }
    }

    // MARK: Addresses

    /// `web_url`: an absolute http(s) address on a named host that is not the server's own, so a preview
    /// cannot point at the app itself. Nil otherwise.
    static func webURL(_ value: String?, host: String) -> String? {
        guard let value, !isBlank(value), let uri = SimpleURI(value) else { return nil }
        guard uri.scheme == "http" || uri.scheme == "https", let uriHost = uri.host, isNamedHost(uriHost) else { return nil }
        return canonicalHost(uriHost) == canonicalHost(host) ? nil : value
    }

    /// `named_host?`: a dotted name whose last label has a letter and is not a hexadecimal number.
    private static func isNamedHost(_ host: String) -> Bool {
        if isBlank(host) || host.contains("%") || !host.contains(".") { return false }
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        while labels.last?.isEmpty == true { labels.removeLast() }
        guard let label = labels.last else { return false }
        return label.unicodeScalars.contains { $0.isASCIILetter } && !label.lowercased().hasPrefix("0x")
    }

    private static func canonicalHost(_ host: String) -> String {
        var lowered = host.lowercased()
        if lowered.hasSuffix(".") { lowered.removeLast() }
        return lowered
    }

    // MARK: Solo unfurl

    /// When the body is only the link its one preview is of, the link's text goes (`removeSoloUnfurledLinkText`):
    /// with divs (Trix), each div becomes the preview; otherwise (Lexxy) every paragraph without an attachment is dropped.
    static func removeSoloUnfurledLinkText(_ root: HTMLNode, plainText: String, host: String) {
        let all = root.descendantElements()
        let previews = all.filter { $0.name == attachmentTag && $0.attribute("content-type") == embedContentType }
        guard previews.count == 1, let preview = previews.first,
              let href = embedDetails(preview, host: host).href,
              let normalised = normalizeTweetURL(href),
              normalised == normalizeTweetURL(plainText)
        else { return }
        if all.contains(where: { $0.name == "div" }) {
            for div in all where div.name == "div" { div.children = [preview] }
        } else {
            for paragraph in all where paragraph.name == "p" && !paragraph.descendantElements().contains(where: { $0.name == attachmentTag }) {
                paragraph.children = []
                paragraph.name = "#removed"
            }
        }
    }

    /// `normalize_tweet_url`: x.com and twitter.com addresses compare equal, whatever their query or login;
    /// any other text is as it is.
    static func normalizeTweetURL(_ text: String) -> String? {
        if isBlank(text) || !(text.contains("x.com") || text.contains("twitter.com")) { return text }
        guard var uri = SimpleURI(text) else { return text }
        uri.userinfo = nil
        uri.query = nil
        if uri.host?.lowercased() == "x.com" { uri.host = "twitter.com" }
        return uri.description
    }

    // MARK: Strings

    static func isBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    /// Ruby's `strip`: NUL and ASCII whitespace at either end.
    static func strip(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        func isStripped(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value == 0 || scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0B}" || scalar == "\u{0C}" || scalar == "\r"
        }
        var start = 0
        var end = scalars.count
        while start < end, isStripped(scalars[start]) { start += 1 }
        while end > start, isStripped(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// Active Support's `truncate`, counting characters, with an ellipsis as the omission.
    static func truncate(_ value: String, _ length: Int) -> String {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count > length else { return value }
        return String(String.UnicodeScalarView(scalars[0..<(length - 1)])) + "…"
    }
}

/// Just enough of a URI to ask what `webUrl` and `normalizeTweetUrl` ask: scheme, userinfo, host,
/// port, path, query and fragment. Anything not ASCII, or without a scheme and `//`, does not parse.
struct SimpleURI: CustomStringConvertible {
    var scheme: String
    var userinfo: String?
    var host: String?
    var port: String?
    var path: String
    var query: String?
    var fragment: String?

    init?(_ value: String) {
        guard value.unicodeScalars.allSatisfy({ $0.value < 0x80 }) else { return nil }
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let scheme = value[value.startIndex..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCIILetter,
              scheme.unicodeScalars.allSatisfy({ $0.isASCIILetter || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        var rest = value[value.index(after: colon)...]
        guard rest.hasPrefix("//") else { return nil }
        rest = rest.dropFirst(2)
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        var query: String?
        if let question = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: question)...])
            rest = rest[..<question]
        }
        var authority = rest
        var path = ""
        if let slash = rest.firstIndex(of: "/") {
            authority = rest[..<slash]
            path = String(rest[slash...])
        }
        var userinfo: String?
        if let at = authority.lastIndex(of: "@") {
            userinfo = String(authority[..<at])
            authority = authority[authority.index(after: at)...]
        }
        var host = String(authority)
        var port: String?
        if !host.hasPrefix("["), let portColon = host.lastIndex(of: ":") {
            port = String(host[host.index(after: portColon)...])
            host = String(host[..<portColon])
        }
        self.scheme = scheme.lowercased()
        self.userinfo = userinfo
        self.host = host
        self.port = port
        self.path = path
        self.query = query
        self.fragment = fragment
    }

    var description: String {
        var out = scheme + "://"
        if let userinfo { out += userinfo + "@" }
        out += host ?? ""
        if let port, !port.isEmpty { out += ":" + port }
        out += path
        if let query { out += "?" + query }
        if let fragment { out += "#" + fragment }
        return out
    }
}

extension HTMLNode {
    /// Every element below this node, in document order, found without recursion.
    func descendantElements() -> [HTMLNode] {
        var out: [HTMLNode] = []
        var stack: [HTMLNode] = children.reversed()
        while let node = stack.popLast() {
            guard node.isElement else { continue }
            out.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return out
    }
}
