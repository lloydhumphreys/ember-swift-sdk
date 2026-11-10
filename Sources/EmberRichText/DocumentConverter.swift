import Foundation

/// Turns the parsed tree of a stored body into blocks, showing what `displayBody` (display.ts) lets
/// a message show: only the allowlisted elements (anything else contributes just its children), mentions
/// from their sgid, previews from their embed, and addresses linked as the server links them.
struct DocumentConverter {
    let host: String

    func blocks(from root: HTMLNode) -> [RichBlock] {
        let walker = Walker(host: host, inline: false, depth: 0)
        walker.walk(root.children, style: [], inLink: false)
        return walker.finish().blocks
    }
}

/// Tags that start a new line or block when they appear among inlines.
private let blockTags: Set<String> = [
    "p", "div", "address", "blockquote", "pre", "ul", "ol", "li", "dl", "dt", "dd", "hr", "table", "thead", "tbody", "tfoot",
    "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
]

/// Elements whose contents are never text a reader sees.
private let droppedTags: Set<String> = ["script", "style", "template", "svg", "math", "noscript", "iframe", "object", "title", "head"]

/// Schemes a link may keep. Each is in the server's `ALLOWED_PROTOCOLS` (packages/richtext/src/sanitize.ts), which also
/// allows `data` (only for a few image and text types), `fax`, `line` and `modem`; those are left out here, as nothing
/// opens them. A scheme the server strips (`file`, `feed`, `svn`) is not kept, so it comes out as plain text.
private let linkSchemes: Set<String> = [
    "ed2k", "ftp", "http", "https", "irc", "mailto", "news", "gopher", "nntp", "telnet", "webcal", "xmpp", "callto",
    "urn", "aim", "rsync", "tag", "ssh", "sftp", "rtsp", "afs", "tel", "sms",
]

/// Walks nodes, collecting blocks and the run of inlines that will become the next paragraph. In
/// `inline` mode (headings, links' contents, table cells) there are no blocks: block elements only
/// separate lines.
private final class Walker {
    /// Nesting of quotes, lists and tables beyond which they are read as plain flow, so a hostile body cannot exhaust the stack.
    static let maxStructuralDepth = 48

    let host: String
    let inline: Bool
    let depth: Int
    var blocks: [RichBlock] = []
    var run: [RichInline] = []
    /// A block boundary was crossed in inline mode, so the next content starts a new line.
    var pendingBreak = false

    init(host: String, inline: Bool, depth: Int) {
        self.host = host
        self.inline = inline
        self.depth = depth
    }

    private enum Work {
        case node(HTMLNode, RichStyle, Bool)
        case flush
    }

    func finish() -> (blocks: [RichBlock], inlines: [RichInline]) {
        flush()
        return (blocks, inline ? WhitespaceCollapser.collapse(run) : [])
    }

    /// Ends the paragraph being collected. In inline mode it only marks a line boundary.
    func flush() {
        if inline {
            pendingBreak = true
            return
        }
        let inlines = WhitespaceCollapser.collapse(run)
        run = []
        if !inlines.isEmpty { blocks.append(.paragraph(inlines)) }
    }

    private func add(_ item: RichInline) {
        if inline, pendingBreak {
            if !run.isEmpty { run.append(.lineBreak) }
            pendingBreak = false
        }
        run.append(item)
    }

    /// Visits nodes with an explicit stack rather than recursion, since a body can nest a few hundred levels.
    func walk(_ nodes: [HTMLNode], style: RichStyle, inLink: Bool) {
        var stack: [Work] = []
        push(nodes, style: style, inLink: inLink, onto: &stack)
        while let work = stack.popLast() {
            switch work {
            case .flush:
                flush()
            case .node(let node, let style, let inLink):
                visit(node, style: style, inLink: inLink, stack: &stack)
            }
        }
    }

    private func push(_ nodes: [HTMLNode], style: RichStyle, inLink: Bool, onto stack: inout [Work]) {
        for node in nodes.reversed() { stack.append(.node(node, style, inLink)) }
    }

    /// A block boundary, the node's children, a block boundary.
    private func pushAsBlock(_ node: HTMLNode, style: RichStyle, inLink: Bool, onto stack: inout [Work]) {
        flush()
        stack.append(.flush)
        push(node.children, style: style, inLink: inLink, onto: &stack)
    }

    private func visit(_ node: HTMLNode, style: RichStyle, inLink: Bool, stack: inout [Work]) {
        if node.kind == .text {
            addText(node.text, style: style, inLink: inLink)
            return
        }
        let name = node.name
        if droppedTags.contains(name) { return }
        switch name {
        case "br":
            add(.lineBreak)
        case "a":
            visitLink(node, style: style, inLink: inLink, stack: &stack)
        case PreviewReader.attachmentTag:
            visitAttachment(node, style: style, inLink: inLink, stack: &stack)
        case "pre":
            visitPre(node)
        case "hr":
            flush()
            if !inline { blocks.append(.rule) }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            visitHeading(node, level: Int(String(name.dropFirst())) ?? 1, inLink: inLink, stack: &stack)
        case "blockquote":
            visitQuote(node, stack: &stack)
        case "ul", "ol":
            visitList(node, stack: &stack)
        case "table":
            visitTable(node, stack: &stack)
        default:
            if let flag = Self.styleFlag(name) {
                push(node.children, style: style.union(flag), inLink: inLink, onto: &stack)
            } else if blockTags.contains(name) {
                pushAsBlock(node, style: style, inLink: inLink, onto: &stack)
            } else {
                push(node.children, style: style, inLink: inLink, onto: &stack)
            }
        }
    }

    private static func styleFlag(_ name: String) -> RichStyle? {
        switch name {
        case "b", "strong": .bold
        case "i", "em", "cite", "dfn", "var": .italic
        case "s", "del", "strike": .strikethrough
        case "u", "ins": .underline
        case "code", "kbd", "samp", "tt": .code
        case "mark": .highlight
        case "sup": .superscript
        case "sub": .subscript
        default: nil
        }
    }

    // MARK: Text and links

    /// Plain text gets its addresses linked, as the server links them after sanitising. Not inside a link,
    /// and not inside code, where a native app has no way to show a link in monospace without losing the code.
    private func addText(_ text: String, style: RichStyle, inLink: Bool) {
        if inLink || style.contains(.code) {
            add(.text(text, style))
            return
        }
        for piece in Autolink.pieces(in: text) {
            if let href = piece.href {
                add(.link(url: href, [.text(piece.text, style)]))
            } else {
                add(.text(piece.text, style))
            }
        }
    }

    private func visitLink(_ node: HTMLNode, style: RichStyle, inLink: Bool, stack: inout [Work]) {
        guard !inLink, let href = node.attribute("href"), Self.isAllowedLink(href) else {
            push(node.children, style: style, inLink: true, onto: &stack)
            return
        }
        let children = inlines(of: node.children, style: style, inLink: true)
        if children.isEmpty { return }
        add(.link(url: href, children))
    }

    /// The sanitiser keeps a link's `href` only when it is relative or has a scheme it knows.
    static func isAllowedLink(_ href: String) -> Bool {
        // Browsers ignore control characters and spaces at the start, and inside the scheme.
        let cleaned = String(String.UnicodeScalarView(href.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
        guard let colon = cleaned.firstIndex(of: ":") else { return !cleaned.isEmpty }
        let scheme = cleaned[cleaned.startIndex..<colon].lowercased()
        // A colon after a slash, query or fragment belongs to a relative address.
        if scheme.contains("/") || scheme.contains("?") || scheme.contains("#") { return true }
        return linkSchemes.contains(scheme)
    }

    func inlines(of children: [HTMLNode], style: RichStyle, inLink: Bool) -> [RichInline] {
        let walker = Walker(host: host, inline: true, depth: depth + 1)
        walker.walk(children, style: style, inLink: inLink)
        return walker.finish().inlines
    }

    // MARK: Attachments

    private func visitAttachment(_ node: HTMLNode, style: RichStyle, inLink: Bool, stack: inout [Work]) {
        switch node.attribute("content-type") {
        case PreviewReader.mentionContentType?:
            if let id = Self.userId(fromSgid: node.attribute("sgid") ?? "") {
                add(.mention(userId: id))
            } else {
                add(.text("☒", style))
            }
        case PreviewReader.embedContentType?:
            // A card inside a heading or a cell has nowhere to go.
            guard !inline, let preview = PreviewReader.preview(from: node, host: host) else { return }
            flush()
            blocks.append(.preview(preview))
        default:
            // Other attachments are not in the allowlist, so only their children remain.
            push(node.children, style: style, inLink: inLink, onto: &stack)
        }
    }

    /// `userIdFromSgid`: 16 lowercase base-36 characters, or `ember`.
    static func userId(fromSgid sgid: String) -> String? {
        Composer.isValidUserId(sgid) ? sgid : nil
    }

    // MARK: Blocks

    private func visitPre(_ node: HTMLNode) {
        var code = Self.preformattedText(node)
        if code.hasSuffix("\n") { code.removeLast() }
        if inline {
            // No code block fits in a cell or heading; its lines stay, in code style.
            flush()
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if index > 0 { add(.lineBreak) }
                if !line.isEmpty { add(.text(String(line), .code)) }
            }
            flush()
            return
        }
        flush()
        let language = node.attribute("data-language").flatMap { $0.isEmpty ? nil : $0 }
        blocks.append(.codeBlock(language: language, code: code))
    }

    /// Text of a `<pre>`, with `<br>` as a newline, which no whitespace collapsing touches.
    private static func preformattedText(_ node: HTMLNode) -> String {
        var out = ""
        var stack: [HTMLNode] = node.children.reversed()
        while let current = stack.popLast() {
            if current.kind == .text {
                out += current.text
            } else if current.name == "br" {
                out += "\n"
            } else if !droppedTags.contains(current.name) {
                stack.append(contentsOf: current.children.reversed())
            }
        }
        return out
    }

    private func visitHeading(_ node: HTMLNode, level: Int, inLink: Bool, stack: inout [Work]) {
        if inline {
            pushAsBlock(node, style: [], inLink: inLink, onto: &stack)
            return
        }
        flush()
        let content = inlines(of: node.children, style: [], inLink: inLink)
        if !content.isEmpty { blocks.append(.heading(level: level, content)) }
    }

    private func visitQuote(_ node: HTMLNode, stack: inout [Work]) {
        if inline || depth >= Self.maxStructuralDepth {
            pushAsBlock(node, style: [], inLink: false, onto: &stack)
            return
        }
        flush()
        let inner = Walker(host: host, inline: false, depth: depth + 1)
        inner.walk(node.children, style: [], inLink: false)
        let content = inner.finish().blocks
        if !content.isEmpty { blocks.append(.quote(content)) }
    }

    private func visitList(_ node: HTMLNode, stack: inout [Work]) {
        if inline || depth >= Self.maxStructuralDepth {
            pushAsBlock(node, style: [], inLink: false, onto: &stack)
            return
        }
        flush()
        var items: [[RichBlock]] = []
        // Anything between items that is not an item (stray text, a nested list) is read as an item, so it is not lost.
        var stray: [HTMLNode] = []
        func flushStray() {
            guard !stray.isEmpty else { return }
            let inner = Walker(host: host, inline: false, depth: depth + 1)
            inner.walk(stray, style: [], inLink: false)
            let content = inner.finish().blocks
            if !content.isEmpty { items.append(content) }
            stray = []
        }
        for child in node.children {
            if child.isElement, child.name == "li" {
                flushStray()
                let inner = Walker(host: host, inline: false, depth: depth + 1)
                inner.walk(child.children, style: [], inLink: false)
                items.append(inner.finish().blocks)
            } else {
                stray.append(child)
            }
        }
        flushStray()
        guard !items.isEmpty else { return }
        let ordered = node.name == "ol"
        let start = ordered ? node.attribute("start").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } : nil
        blocks.append(.list(ordered: ordered, start: start, items: items))
    }

    private func visitTable(_ node: HTMLNode, stack: inout [Work]) {
        if depth >= Self.maxStructuralDepth {
            pushAsBlock(node, style: [], inLink: false, onto: &stack)
            return
        }
        // Rows in document order, from the table or its sections, but not from tables nested in cells.
        var rows: [HTMLNode] = []
        var stack: [HTMLNode] = node.children.reversed()
        while let current = stack.popLast() {
            guard current.isElement else { continue }
            switch current.name {
            case "tr": rows.append(current)
            case "thead", "tbody", "tfoot": stack.append(contentsOf: current.children.reversed())
            default: continue
            }
        }
        var header: [[RichInline]]?
        var body: [[[RichInline]]] = []
        for (index, row) in rows.enumerated() {
            let cells = row.children.filter { $0.isElement && ($0.name == "td" || $0.name == "th") }
            let contents = cells.map { inlines(of: $0.children, style: [], inLink: false) }
            if index == 0, !cells.isEmpty, cells.allSatisfy({ $0.name == "th" }) {
                header = contents
            } else {
                body.append(contents)
            }
        }
        if inline {
            // A table inside a heading or cell has no place; its cells read as lines.
            flush()
            for row in (header.map { [$0] } ?? []) + body {
                for cell in row where !cell.isEmpty {
                    for item in cell { add(item) }
                    flush()
                }
            }
            return
        }
        flush()
        if header == nil && body.isEmpty { return }
        blocks.append(.table(header: header, rows: body))
    }
}
