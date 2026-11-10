import Foundation

/// The parse hit a limit (nesting too deep). `RichText.document` answers it with the plain text.
struct HTMLParseLimitError: Error {}

/// A parsed node. A class so the builder can append to a parent while holding a stack of open
/// elements; it never leaves this module and is only used on one thread, inside one call.
final class HTMLNode {
    enum Kind {
        case text
        case element
    }

    let kind: Kind
    var name: String
    var attributes: [HTMLAttribute]
    var text: String
    var children: [HTMLNode] = []

    init(element name: String, attributes: [HTMLAttribute] = []) {
        self.kind = .element
        self.name = name
        self.attributes = attributes
        self.text = ""
    }

    init(text: String) {
        self.kind = .text
        self.name = ""
        self.attributes = []
        self.text = text
    }

    func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    var isElement: Bool { kind == .element }

    /// All text below this node, as `textContent` reads it.
    var textContent: String {
        var out = ""
        var stack: [HTMLNode] = [self]
        // Iterative, so a deep tree cannot overflow the stack.
        while let node = stack.popLast() {
            if node.kind == .text {
                out += node.text
            } else {
                stack.append(contentsOf: node.children.reversed())
            }
        }
        return out
    }
}

/// Builds a tree from tokens with just enough of HTML5's implied-end-tag rules to read real
/// editor output and survive broken markup: paragraphs close before blocks, list items before list
/// items, table cells and rows before their siblings, anchors do not nest. It is iterative and
/// caps nesting, so hostile input cannot recurse without bound.
struct HTMLTreeBuilder {
    /// Matches the server's parser limit (`MAX_TREE_DEPTH`), above which it refuses a body.
    static let maxDepth = 400

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Tags whose start and end are ignored outright; their children stay.
    private static let transparentDocumentTags: Set<String> = ["html", "head", "body"]

    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    /// Start tags that close an open `<p>`.
    private static let closesParagraph: Set<String> = [
        "address", "blockquote", "div", "dl", "dd", "dt", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "li", "ol", "p",
        "pre", "table", "ul", "section", "article", "aside", "header", "footer", "nav", "main", "details", "summary",
    ]

    private static let tableStructure: Set<String> = ["table", "thead", "tbody", "tfoot", "tr"]
    private static let tableTags: Set<String> = [
        "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "colgroup", "col", "script", "style", "template",
    ]

    /// Elements an end tag (or an implied close) must not reach across.
    private static let scopeBoundaries: Set<String> = ["table", "td", "th", "caption"]

    private let root = HTMLNode(element: "#root")
    private var stack: [HTMLNode] = []
    private var dropNextLeadingNewline = false

    static func parse(_ html: String) throws -> HTMLNode {
        var builder = HTMLTreeBuilder()
        builder.stack = [builder.root]
        for token in HTMLTokenizer.tokenize(html) {
            try builder.consume(token)
        }
        return builder.root
    }

    private var current: HTMLNode { stack[stack.count - 1] }

    private mutating func consume(_ token: HTMLToken) throws {
        switch token {
        case .text(let text):
            insertText(text)
        case .start(let name, let attributes, _):
            try startTag(name, attributes)
        case .end(let name):
            endTag(name)
        }
    }

    // MARK: Text

    private mutating func insertText(_ raw: String) {
        var text = raw
        if dropNextLeadingNewline {
            dropNextLeadingNewline = false
            if text.hasPrefix("\n") { text.removeFirst() }
        }
        guard !text.isEmpty else { return }
        if HTMLTreeBuilder.tableStructure.contains(current.name) {
            // Whitespace between rows is nothing; text outside a cell gets a cell of its own, so no
            // text is lost (HTML5 would foster-parent it before the table).
            if text.allSatisfy(\.isHTMLWhitespaceCharacter) { return }
            impliedCell()
        }
        if let last = current.children.last, last.kind == .text {
            last.text += text
        } else {
            current.children.append(HTMLNode(text: text))
        }
    }

    /// Opens the row and cell that content directly inside table structure needs.
    private mutating func impliedCell() {
        if ["table", "thead", "tbody", "tfoot"].contains(current.name) {
            push(HTMLNode(element: "tr"))
        }
        if current.name == "tr" {
            push(HTMLNode(element: "td"))
        }
    }

    // MARK: Start tags

    private mutating func startTag(_ name: String, _ attributes: [HTMLAttribute]) throws {
        if HTMLTreeBuilder.transparentDocumentTags.contains(name) { return }
        dropNextLeadingNewline = false

        if HTMLTreeBuilder.tableStructure.contains(current.name), !HTMLTreeBuilder.tableTags.contains(name) {
            impliedCell()
        }

        switch name {
        case "li":
            closeThrough(["li"], stoppingAt: ["ul", "ol", "table", "td", "th"])
            closeParagraph()
        case "dd", "dt":
            closeThrough(["dd", "dt"], stoppingAt: ["dl", "table", "td", "th"])
            closeParagraph()
        case "tr":
            closeThrough(["tr"], stoppingAt: ["table"])
        case "td", "th":
            closeThrough(["td", "th"], stoppingAt: ["tr", "table"])
            ensureRowContext()
        case "thead", "tbody", "tfoot":
            closeThrough(["thead", "tbody", "tfoot"], stoppingAt: ["table"])
        case "a":
            closeThrough(["a"], stoppingAt: ["table", "td", "th", "caption"])
        default:
            if HTMLTreeBuilder.closesParagraph.contains(name) { closeParagraph() }
            if HTMLTreeBuilder.headings.contains(name), HTMLTreeBuilder.headings.contains(current.name) {
                stack.removeLast()
            }
        }

        let element = HTMLNode(element: name, attributes: attributes)
        current.children.append(element)
        // As in HTML, a self-closing flag on a non-void element is ignored.
        if HTMLTreeBuilder.voidElements.contains(name) { return }
        try pushChecked(element)
        if name == "pre" || name == "textarea" || name == "listing" { dropNextLeadingNewline = true }
    }

    /// A `td` outside a `tr` (directly in a table or section) gets a row.
    private mutating func ensureRowContext() {
        if current.name != "tr" && ["table", "thead", "tbody", "tfoot"].contains(current.name) {
            push(HTMLNode(element: "tr"))
        }
    }

    private mutating func push(_ element: HTMLNode) {
        current.children.append(element)
        stack.append(element)
    }

    private mutating func pushChecked(_ element: HTMLNode) throws {
        stack.append(element)
        // `stack` includes the root, so the element's depth is `stack.count - 1`.
        if stack.count - 1 > HTMLTreeBuilder.maxDepth { throw HTMLParseLimitError() }
    }

    /// Closes an open `<p>` (HTML5's "in button scope" check, with tables as the boundary).
    private mutating func closeParagraph() {
        closeThrough(["p"], stoppingAt: HTMLTreeBuilder.scopeBoundaries)
    }

    /// If one of `names` is open (looking down from the top, not past `boundaries`), pops through it.
    private mutating func closeThrough(_ names: Set<String>, stoppingAt boundaries: Set<String>) {
        var position = stack.count - 1
        while position >= 1 {
            let name = stack[position].name
            if names.contains(name) {
                stack.removeSubrange(position...)
                return
            }
            if boundaries.contains(name) { return }
            position -= 1
        }
    }

    // MARK: End tags

    private mutating func endTag(_ name: String) {
        if HTMLTreeBuilder.transparentDocumentTags.contains(name) { return }
        if name == "br" {
            // `</br>` is read as `<br>`.
            current.children.append(HTMLNode(element: "br"))
            return
        }
        if HTMLTreeBuilder.voidElements.contains(name) { return }
        var position = stack.count - 1
        while position >= 1 {
            let candidate = stack[position].name
            if candidate == name {
                stack.removeSubrange(position...)
                return
            }
            // Do not let a stray `</b>` reach out of a cell or table, `</td>` out of a row, or `</tr>` out of a table.
            switch name {
            case "tr", "thead", "tbody", "tfoot":
                if candidate == "table" { return }
            case "td", "th":
                if candidate == "tr" || candidate == "table" { return }
            default:
                if HTMLTreeBuilder.scopeBoundaries.contains(candidate) { return }
            }
            position -= 1
        }
    }
}

extension Character {
    var isHTMLWhitespaceCharacter: Bool {
        self == " " || self == "\t" || self == "\n" || self == "\u{0C}" || self == "\r"
    }
}
