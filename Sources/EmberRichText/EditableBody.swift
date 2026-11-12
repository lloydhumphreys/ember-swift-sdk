import Foundation

/// A stored message body as plain text that can be edited without losing the formatting of
/// anything the edit didn't touch.
///
/// `text` is one line per block (list items and table cells are lines too), `<br>` is a line
/// break, a mention reads as "@" and the person's name, and a link as its visible text. Images,
/// files and previews read as nothing and are never removed by an edit.
///
/// `body(editedTo:)` replaces only the smallest changed range of the body and keeps everything
/// outside it byte for byte:
/// - Typed text takes the formatting of the text it replaces. A pure insertion takes the formatting
///   of the character before it, or of the character after it at the start of a line. Typing just
///   after a link never extends the link.
/// - Elements wholly inside the removed range are removed. Deleting the line break between two
///   blocks moves the rest of the second block into the first.
/// - An edit that cuts into a mention keeps what is left of "@Name" as plain text.
/// - Typed line breaks are written as `<br>`, as `RichText.body(fromPlainText:)` writes them.
///
/// `body(editedTo:mentions:)` does the same and then makes a mention of each "@Name" of someone
/// chosen while editing, as the composer does.
///
/// A body this can't map (badly nested markup) reads as plain text, and any change to it is sent
/// as `RichText.body(fromPlainText:)`. Never traps.
public struct EditableBody: Sendable {
    public let body: String
    public let text: String
    let layout: Layout?
    private let mentionNames: [String: String]

    /// `mentionNames` maps a user id to the name a mention of them shows, as in `Message.mentions`.
    /// The stored mention markup carries only the id.
    public init(body: String, mentionNames: [String: String] = [:]) {
        self.body = body
        self.mentionNames = mentionNames
        if let layout = try? Layout(body, mentionNames: mentionNames) {
            self.layout = layout
            text = layout.units.map(\.text).joined()
        } else {
            layout = nil
            text = Self.plainReading(body, mentionNames: mentionNames)
        }
    }

    /// The body to save for `newText`, keeping the formatting of everything the edit didn't touch.
    public func body(editedTo newText: String) -> String {
        body(editedTo: newText, mentions: [:])
    }

    /// The body to save for `newText`, as `body(editedTo:)` writes it, with each "@" and name of
    /// someone in `mentions` that is still plain text made a mention of them, wherever it is, as
    /// `RichText.segments(_:mentions:)` finds them when composing.
    ///
    /// `mentions` maps a user id to the name written after the "@": the people chosen while
    /// editing. Mentions already in the body stay as they are, whoever they're of. A name inside a
    /// link or code, or one that runs into a mention, stays text. An id the server wouldn't accept
    /// as a mention changes nothing.
    ///
    /// A body this can't map is sent as `RichText.body(from: RichText.segments(newText, mentions:))`.
    public func body(editedTo newText: String, mentions: [String: String]) -> String {
        let people = mentions.filter { Composer.isValidUserId($0.key) && !$0.value.isEmpty }
        if newText == text, people.isEmpty || Composer.matches(newText, mentions: people).isEmpty { return body }
        if let result = splice(editedTo: newText, mentions: people) { return result }
        return people.isEmpty ? RichText.body(fromPlainText: newText) : RichText.body(from: RichText.segments(newText, mentions: people))
    }

    /// The edited body, or nil when the edit can't be mapped onto this body and loses its formatting.
    func splice(editedTo newText: String, mentions: [String: String] = [:]) -> String? {
        guard let layout else { return nil }
        var result = body
        if newText != text {
            guard let spliced = layout.splice(oldText: text, newText: newText) else { return nil }
            // Belt and braces: an edit that wouldn't read back as what was typed is not worth
            // keeping formatting for.
            let check = EditableBody(body: spliced, mentionNames: mentionNames)
            guard check.layout != nil, check.text == Self.normalisedLineBreaks(newText) else { return nil }
            result = spliced
        }
        return mentions.isEmpty ? result : Self.mentioning(mentions, in: result, names: mentionNames)
    }

    /// `body` with each "@" and name of someone in `mentions` that reads as plain text made a
    /// mention of them, or nil when the result wouldn't read back as it should.
    private static func mentioning(_ mentions: [String: String], in body: String, names known: [String: String]) -> String? {
        // A mention of someone the body already mentions reads with the name it already has.
        let names = known.merging(mentions) { existing, _ in existing }
        let reading = EditableBody(body: body, mentionNames: names)
        guard var layout = reading.layout else { return nil }
        let scalars = reading.text.unicodeScalars
        var expected = Array(scalars)
        var result = body
        // From the end, so the offsets of those still to do stay put.
        for match in Composer.matches(reading.text, mentions: mentions).reversed() {
            let start = scalars.distance(from: scalars.startIndex, to: match.range.lowerBound)
            let end = scalars.distance(from: scalars.startIndex, to: match.range.upperBound)
            guard let mentioned = layout.mentioning(start..<end, userId: match.userId) else { continue }
            guard let next = try? Layout(mentioned, mentionNames: names) else { return nil }
            expected.replaceSubrange(start..<end, with: ("@" + (names[match.userId] ?? match.name)).unicodeScalars)
            result = mentioned
            layout = next
        }
        let check = EditableBody(body: result, mentionNames: names)
        guard check.layout != nil, check.text.unicodeScalars.elementsEqual(expected) else { return nil }
        return result
    }

    static func normalisedLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Fallback reading

    /// What a body the layout can't map reads as: the display model's text, one line per block.
    private static func plainReading(_ body: String, mentionNames: [String: String]) -> String {
        guard let root = try? HTMLTreeBuilder.parse(body) else { return "" }
        let blocks = DocumentConverter(host: "").blocks(from: root)
        return lines(blocks, mentionNames).joined(separator: "\n")
    }

    private static func lines(_ blocks: [RichBlock], _ names: [String: String]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines): [string(inlines, names)]
            case .codeBlock(_, let code): [code]
            case .quote(let inner): lines(inner, names)
            case .list(_, _, let items): items.flatMap { lines($0, names) }
            case .table(let header, let rows): ((header.map { [$0] } ?? []) + rows).flatMap { $0.map { string($0, names) } }
            case .rule, .preview: []
            }
        }
    }

    private static func string(_ inlines: [RichInline], _ names: [String: String]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text, _): text
            case .link(_, let inner): string(inner, names)
            case .mention(let userId): "@" + (names[userId] ?? "")
            case .lineBreak: "\n"
            }
        }.joined()
    }
}

// MARK: - Layout

/// Where each visible character of a body comes from. Positions are offsets into the body's
/// Unicode scalars, always between tags, never inside one.
struct Layout: Sendable {
    struct Unit: Sendable {
        enum Kind: Sendable {
            case character
            /// A run of source whitespace holding a line break, which reads as one space.
            case formatting
            /// A literal `&` or `<` that isn't markup; text typed next to it could turn it into markup.
            case special
            case lineBreak
            case mention
            /// The line break between two blocks: from the first block tag after one line's content
            /// to the end of the last block tag before the next line's content.
            case blockBreak
        }

        var kind: Kind
        var text: String
        var source: Range<Int>
        var textStart = 0
        var textEnd = 0
    }

    struct Element: Sendable {
        var name: String
        var start: Range<Int>
        /// Nil for void elements.
        var end: Range<Int>?
        var isBlock: Bool { blockTags.contains(name) }
    }

    struct Unmappable: Error {}

    let source: [Unicode.Scalar]
    private(set) var units: [Unit] = []
    /// Each line's content region.
    private(set) var lines: [Range<Int>] = []
    private(set) var elements: [Element] = []
    /// Start of every block tag, in order.
    private(set) var boundaries: [Int] = []
    /// Images, files and other attachments that read as nothing: kept when an edit spans them.
    private(set) var keepers: [Range<Int>] = []

    init(_ body: String, mentionNames: [String: String]) throws {
        source = Array(body.unicodeScalars)
        let tokens = try Self.tokenize(source)
        let (tokenElement, endToken) = try buildElements(tokens)
        read(tokens, tokenElement: tokenElement, endToken: endToken, mentionNames: mentionNames)
        var offset = 0
        for index in units.indices {
            units[index].textStart = offset
            offset += units[index].text.unicodeScalars.count
            units[index].textEnd = offset
        }
    }

    // MARK: Tokens

    enum Token {
        case text(Range<Int>)
        case start(name: String, Range<Int>, selfClosing: Bool, attributes: [String: String])
        case end(name: String, Range<Int>)
        /// Comments, doctypes, raw text: nothing that reads.
        case other(Range<Int>)
    }

    private static func tokenize(_ src: [Unicode.Scalar]) throws -> [Token] {
        var tokens: [Token] = []
        var textStart = 0
        var i = 0
        let n = src.count
        func flush(_ upTo: Int) {
            if upTo > textStart { tokens.append(.text(textStart..<upTo)) }
        }
        func find(_ needle: String, from: Int) -> Int? {
            let pattern = Array(needle.unicodeScalars)
            var j = from
            while j + pattern.count <= n {
                if (0..<pattern.count).allSatisfy({ src[j + $0].asciiLowercased == pattern[$0] }) { return j }
                j += 1
            }
            return nil
        }
        while i < n {
            guard src[i] == "<", i + 1 < n else { i += 1; continue }
            let next = src[i + 1]
            if next.isASCIILetter {
                flush(i)
                let (name, end, selfClosing, attributes) = try startTag(src, at: i)
                tokens.append(.start(name: name, i..<end, selfClosing: selfClosing, attributes: attributes))
                i = end
                if rawTextTags.contains(name) {
                    guard let close = find("</" + name, from: i) else { throw Unmappable() }
                    if close > i { tokens.append(.other(i..<close)) }
                    i = close
                }
                textStart = i
            } else if next == "/" {
                flush(i)
                guard let close = find(">", from: i + 2) else { throw Unmappable() }
                if i + 2 < n, src[i + 2].isASCIILetter {
                    var j = i + 2
                    var name = ""
                    while j < close, !src[j].isHTMLSpace, src[j] != "/" {
                        name.unicodeScalars.append(src[j].asciiLowercased)
                        j += 1
                    }
                    tokens.append(.end(name: name, i..<close + 1))
                } else {
                    tokens.append(.other(i..<close + 1))
                }
                i = close + 1
                textStart = i
            } else if next == "!" || next == "?" {
                flush(i)
                let isComment = i + 3 < n && src[i + 2] == "-" && src[i + 3] == "-"
                guard let close = isComment ? find("-->", from: i + 4).map({ $0 + 3 }) : find(">", from: i + 2).map({ $0 + 1 }) else { throw Unmappable() }
                tokens.append(.other(i..<close))
                i = close
                textStart = i
            } else {
                i += 1
            }
        }
        flush(n)
        return tokens
    }

    /// Reads the start tag at `position`: its lowercased name, the offset after its `>`, whether it
    /// ends `/>`, and its attributes with entities decoded.
    private static func startTag(_ src: [Unicode.Scalar], at position: Int) throws -> (String, Int, Bool, [String: String]) {
        let n = src.count
        var j = position + 1
        var name = ""
        while j < n, !src[j].isHTMLSpace, src[j] != "/", src[j] != ">" {
            name.unicodeScalars.append(src[j].asciiLowercased)
            j += 1
        }
        var attributes: [String: String] = [:]
        while true {
            while j < n, src[j].isHTMLSpace { j += 1 }
            guard j < n else { throw Unmappable() }
            if src[j] == ">" { return (name, j + 1, false, attributes) }
            if src[j] == "/" {
                if j + 1 < n, src[j + 1] == ">" { return (name, j + 2, true, attributes) }
                j += 1
                continue
            }
            var attribute = ""
            repeat {
                attribute.unicodeScalars.append(src[j].asciiLowercased)
                j += 1
            } while j < n && !src[j].isHTMLSpace && src[j] != "/" && src[j] != ">" && src[j] != "="
            while j < n, src[j].isHTMLSpace { j += 1 }
            var value: [Unicode.Scalar] = []
            if j < n, src[j] == "=" {
                j += 1
                while j < n, src[j].isHTMLSpace { j += 1 }
                guard j < n else { throw Unmappable() }
                if src[j] == "\"" || src[j] == "'" {
                    let quote = src[j]
                    j += 1
                    while j < n, src[j] != quote { value.append(src[j]); j += 1 }
                    guard j < n else { throw Unmappable() }
                    j += 1
                } else {
                    while j < n, !src[j].isHTMLSpace, src[j] != ">" { value.append(src[j]); j += 1 }
                }
            }
            if attributes[attribute] == nil { attributes[attribute] = decodeAttribute(value) }
        }
    }

    private static func decodeAttribute(_ value: [Unicode.Scalar]) -> String {
        var out = ""
        var i = 0
        while i < value.count {
            if value[i] == "&", let (decoded, length) = HTMLEntities.decode(value, at: i, inAttribute: true) {
                out += decoded
                i += length
            } else {
                out.unicodeScalars.append(value[i])
                i += 1
            }
        }
        return out
    }

    // MARK: Elements

    /// Matches every start tag with its end tag. Anything a browser would have to repair (a stray
    /// or missing end tag, `/>` on an element that isn't void) makes the body unmappable, because
    /// a browser's repair can't be predicted from the source.
    private mutating func buildElements(_ tokens: [Token]) throws -> ([Int: Int], [Int: Int]) {
        var tokenElement: [Int: Int] = [:]
        var endToken: [Int: Int] = [:]
        var stack: [Int] = []
        for (index, token) in tokens.enumerated() {
            switch token {
            case .start(let name, let range, let selfClosing, _):
                tokenElement[index] = elements.count
                elements.append(Element(name: name, start: range, end: nil))
                if voidTags.contains(name) { continue }
                if selfClosing { throw Unmappable() }
                stack.append(elements.count - 1)
                if stack.count > HTMLTreeBuilder.maxDepth { throw Unmappable() }
            case .end(let name, let range):
                guard let top = stack.last, elements[top].name == name else { throw Unmappable() }
                elements[top].end = range
                endToken[top] = index
                stack.removeLast()
            case .text, .other:
                continue
            }
        }
        guard stack.isEmpty else { throw Unmappable() }
        return (tokenElement, endToken)
    }

    // MARK: Reading

    private struct Reader {
        var pendingBoundary = false
        var boundaryStart = 0
        var lastBoundaryEnd = 0
        var preDepth = 0
        var preContentStart: Int?
    }

    private mutating func read(_ tokens: [Token], tokenElement: [Int: Int], endToken: [Int: Int], mentionNames: [String: String]) {
        var reader = Reader()
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            switch tokens[index] {
            case .text(let range):
                readText(range, &reader)
            case .other:
                continue
            case .start(let name, let range, _, let attributes):
                guard let elementIndex = tokenElement[index] else { continue }
                let whole = range.lowerBound..<(elements[elementIndex].end?.upperBound ?? range.upperBound)
                if name == "br" {
                    emit(.lineBreak, "\n", range, &reader)
                } else if name == PreviewReader.attachmentTag || inlineAtomTags.contains(name) || droppedTags.contains(name) || blockAtomTags.contains(name) {
                    if name == PreviewReader.attachmentTag, attributes["content-type"] == PreviewReader.mentionContentType {
                        let name = attributes["sgid"].flatMap { mentionNames[$0] } ?? ""
                        emit(.mention, "@" + name, whole, &reader)
                    } else if blockAtomTags.contains(name) {
                        boundary(whole, &reader)
                    } else if !droppedTags.contains(name) {
                        keepers.append(whole)
                    }
                    if let end = endToken[elementIndex] { index = end }
                } else if blockTags.contains(name) {
                    boundary(range, &reader)
                    if name == "pre" {
                        reader.preDepth += 1
                        reader.preContentStart = range.upperBound
                    }
                }
            case .end(let name, let range):
                if blockTags.contains(name) {
                    boundary(range, &reader)
                    if name == "pre" { reader.preDepth = max(0, reader.preDepth - 1) }
                }
            }
        }
        if !lines.isEmpty {
            lines[lines.count - 1] = lines[lines.count - 1].lowerBound..<(reader.pendingBoundary ? reader.boundaryStart : source.count)
        }
    }

    private mutating func boundary(_ range: Range<Int>, _ reader: inout Reader) {
        boundaries.append(range.lowerBound)
        if !reader.pendingBoundary {
            reader.pendingBoundary = true
            reader.boundaryStart = range.lowerBound
        }
        reader.lastBoundaryEnd = range.upperBound
    }

    private mutating func emit(_ kind: Unit.Kind, _ text: String, _ range: Range<Int>, _ reader: inout Reader) {
        if units.isEmpty {
            lines.append(reader.lastBoundaryEnd..<reader.lastBoundaryEnd)
        } else if reader.pendingBoundary {
            units.append(Unit(kind: .blockBreak, text: "\n", source: reader.boundaryStart..<reader.lastBoundaryEnd))
            lines[lines.count - 1] = lines[lines.count - 1].lowerBound..<reader.boundaryStart
            lines.append(reader.lastBoundaryEnd..<reader.lastBoundaryEnd)
        }
        reader.pendingBoundary = false
        units.append(Unit(kind: kind, text: text, source: range))
    }

    private mutating func readText(_ range: Range<Int>, _ reader: inout Reader) {
        var i = range.lowerBound
        let end = range.upperBound
        // HTML drops the line break straight after `<pre>`; it belongs with the tag.
        if reader.preDepth > 0, reader.preContentStart == i, i < end, source[i] == "\n" || source[i] == "\r" {
            i += (source[i] == "\r" && i + 1 < end && source[i + 1] == "\n") ? 2 : 1
            if reader.lastBoundaryEnd == range.lowerBound { reader.lastBoundaryEnd = i }
        }
        reader.preContentStart = nil
        while i < end {
            let scalar = source[i]
            if scalar == "&" {
                if let (decoded, length) = HTMLEntities.decode(source, at: i, inAttribute: false), i + length <= end {
                    var text = decoded
                    if decoded.unicodeScalars.count == 1, let only = decoded.unicodeScalars.first, only.isHTMLSpace {
                        text = reader.preDepth > 0 && (only == "\n" || only == "\r") ? "\n" : " "
                    }
                    emit(.character, text, i..<i + length, &reader)
                    i += length
                } else {
                    emit(.special, "&", i..<i + 1, &reader)
                    i += 1
                }
                continue
            }
            if scalar == "<" {
                emit(.special, "<", i..<i + 1, &reader)
                i += 1
                continue
            }
            if reader.preDepth > 0 {
                if scalar == "\r" {
                    let length = i + 1 < end && source[i + 1] == "\n" ? 2 : 1
                    emit(.character, "\n", i..<i + length, &reader)
                    i += length
                } else {
                    emit(.character, String(scalar), i..<i + 1, &reader)
                    i += 1
                }
                continue
            }
            if scalar.isHTMLSpace {
                var j = i
                var holdsBreak = false
                while j < end, source[j].isHTMLSpace {
                    if source[j] == "\n" || source[j] == "\r" { holdsBreak = true }
                    j += 1
                }
                if holdsBreak {
                    // Source formatting: a space inside a line, nothing before a line's content.
                    if !units.isEmpty, !reader.pendingBoundary { emit(.formatting, " ", i..<j, &reader) }
                } else {
                    // Spaces and tabs read as typed, so `body(fromPlainText:)` reads back exactly.
                    for k in i..<j { emit(.character, String(source[k]), k..<k + 1, &reader) }
                }
                i = j
                continue
            }
            emit(.character, String(scalar), i..<i + 1, &reader)
            i += 1
        }
    }

    // MARK: Editing

    private func openElements(at position: Int) -> [Int] {
        elements.indices.filter { index in
            guard let end = elements[index].end else { return false }
            return elements[index].start.upperBound <= position && end.lowerBound >= position
        }
    }

    private func slice(_ range: Range<Int>) -> String {
        var out = ""
        out.unicodeScalars.append(contentsOf: source[range])
        return out
    }

    func splice(oldText: String, newText rawNew: String) -> String? {
        let newText = EditableBody.normalisedLineBreaks(rawNew)
        let old = Array(oldText.unicodeScalars)
        let new = Array(newText.unicodeScalars)

        if units.isEmpty {
            // Nothing to edit in place: an empty body becomes the typed text, attachments stay.
            if keepers.isEmpty { return Composer.body(fromPlainText: newText) }
            return slice(0..<source.count) + "<p>" + Self.escaped(newText) + "</p>"
        }

        // Smallest changed range, on grapheme boundaries in both texts.
        let oldBoundaries = Self.graphemeBoundaries(oldText)
        let newBoundaries = Self.graphemeBoundaries(newText)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        while prefix > 0, !(oldBoundaries.contains(prefix) && newBoundaries.contains(prefix)) { prefix -= 1 }
        var suffix = 0
        let limit = min(old.count, new.count) - prefix
        while suffix < limit, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        while suffix > 0, !(oldBoundaries.contains(old.count - suffix) && newBoundaries.contains(new.count - suffix)) { suffix -= 1 }

        // Changed units [first, last): widened so no entity, mention or whitespace run is split.
        var a = prefix
        var b = old.count - suffix
        var first = units.firstIndex { $0.textEnd > a } ?? units.count
        var last = units.firstIndex { $0.textStart >= b } ?? units.count
        if first < units.count { a = min(a, units[first].textStart) }
        if last > 0, last > first { b = max(b, units[last - 1].textEnd) }
        if first > 0, units[first - 1].kind == .formatting || units[first - 1].kind == .special {
            first -= 1
            a = units[first].textStart
        }
        if last < units.count, units[last].kind == .formatting {
            b = units[last].textEnd
            last += 1
        }
        let typedEnd = new.count - (old.count - b)
        guard a <= typedEnd else { return nil }
        var typed = ""
        typed.unicodeScalars.append(contentsOf: new[a..<typedEnd])
        var insertion = Self.escaped(typed)

        if first == last {
            // A pure insertion: it joins the text before it, or the text after it at a line's start.
            var position: Int
            if first > 0, units[first - 1].kind != .blockBreak {
                position = units[first - 1].source.upperBound
                let nextStart = first < units.count ? units[first].source.lowerBound : source.count
                // Typing straight after a link never extends it.
                if let link = openElements(at: position).first(where: { elements[$0].name == "a" && elements[$0].end!.lowerBound <= nextStart }) {
                    position = elements[link].end!.upperBound
                }
            } else {
                position = units[first].source.lowerBound
            }
            return slice(0..<position) + insertion + slice(position..<source.count)
        }

        // Deleting all of a line in the middle keeps an empty line: the line break before it
        // (or after it, for the first line) goes and a `<br>` stands in its place.
        if typed.isEmpty {
            let startsLine = first == 0 || units[first - 1].kind == .blockBreak
            let endsLine = last == units.count || units[last].kind == .blockBreak
            if startsLine, endsLine, !(first == 0 && last == units.count) {
                if first > 0 { first -= 1 } else { last += 1 }
                insertion = "<br>"
            }
        }
        return replacing(first: first, last: last, with: insertion)
    }

    /// The body with the plain text at `range` (offsets into the text's scalars) replaced by a
    /// mention of `userId`, or nil where that text isn't plain: not whole units, holding a mention
    /// or a line break, or inside a link or code.
    func mentioning(_ range: Range<Int>, userId: String) -> String? {
        guard !range.isEmpty,
              let first = units.firstIndex(where: { $0.textStart == range.lowerBound }),
              let end = units[first...].firstIndex(where: { $0.textEnd == range.upperBound }) else { return nil }
        let plain: Set<Unit.Kind> = [.character, .special, .formatting]
        let kept: Set<String> = ["a", "code", "pre"]
        for unit in units[first...end] {
            guard plain.contains(unit.kind),
                  !openElements(at: unit.source.lowerBound).contains(where: { kept.contains(elements[$0].name) }) else { return nil }
        }
        return replacing(first: first, last: end + 1, with: Composer.mention(userId))
    }

    /// The body with units [first, last) replaced by `insertion`, closing and opening the elements
    /// around them so the markup stays balanced.
    private func replacing(first: Int, last: Int, with insertion: String) -> String? {
        let p: Int
        if !insertion.isEmpty {
            p = units[first].source.lowerBound
        } else {
            p = first == 0 ? lines[0].lowerBound : units[first - 1].source.upperBound
        }
        let q = last < units.count ? units[last].source.lowerBound : lines[lines.count - 1].upperBound
        guard p <= q else { return nil }

        let before = openElements(at: p)
        let after = openElements(at: q)
        var common = 0
        while common < before.count, common < after.count, before[common] == after[common] { common += 1 }
        let closing = Array(before[common...])
        let opening = Array(after[common...])
        let closeSplit = (closing.lastIndex { elements[$0].isBlock } ?? -1) + 1
        let openSplit = (opening.lastIndex { elements[$0].isBlock } ?? -1) + 1
        let closingBlocks = closing[..<closeSplit]
        let closingInline = closing[closeSplit...]
        let openingBlocks = Array(opening[..<openSplit])
        let openingInline = opening[openSplit...]

        var out = slice(0..<p) + insertion
        for keeper in keepers where keeper.lowerBound >= p && keeper.upperBound <= q {
            out += slice(keeper)
        }
        for index in closingInline.reversed() { out += slice(elements[index].end!) }
        for index in openingInline { out += slice(elements[index].start) }

        if closingBlocks.isEmpty, openingBlocks.isEmpty {
            return out + slice(q..<source.count)
        }

        // The edit crossed a block break: the rest of the later line joins the earlier block.
        let r = boundaries.first { $0 >= q } ?? source.count
        guard openingInline.allSatisfy({ elements[$0].end!.upperBound <= r }) else { return nil }
        out += slice(q..<r)
        var position = r
        var remaining = openingBlocks
        while let innermost = remaining.last, let end = elements[innermost].end, end.lowerBound >= position,
              source[position..<end.lowerBound].allSatisfy(\.isHTMLSpace) {
            position = end.upperBound
            remaining.removeLast()
        }
        for index in closingBlocks.reversed() { out += slice(elements[index].end!) }
        for index in remaining { out += slice(elements[index].start) }
        return out + slice(position..<source.count)
    }

    /// Text as `body(fromPlainText:)` escapes it, without its paragraph.
    static func escaped(_ text: String) -> String {
        // By scalar: a leading combining mark joins `<p>`'s `>` into one Character.
        let body = Composer.body(fromPlainText: text).unicodeScalars
        var out = ""
        out.unicodeScalars.append(contentsOf: body.dropFirst(3).dropLast(4))
        return out
    }

    private static func graphemeBoundaries(_ text: String) -> Set<Int> {
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text {
            offset += character.unicodeScalars.count
            boundaries.insert(offset)
        }
        return boundaries
    }
}

/// Tags whose start and end mark a block: a new line begins after them.
private let blockTags: Set<String> = [
    "p", "div", "address", "blockquote", "pre", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead",
    "tbody", "tfoot", "tr", "td", "th", "caption", "h1", "h2", "h3", "h4", "h5", "h6", "html", "body",
    "article", "section", "header", "footer", "aside", "nav", "main", "details", "summary", "fieldset",
    "form", "figcaption", "hgroup", "menu", "center",
]
/// Read as nothing and kept when an edit spans them.
private let inlineAtomTags: Set<String> = ["img", "video", "audio", "picture", "embed"]
/// Read as nothing and end a line; removed when an edit spans them.
private let blockAtomTags: Set<String> = ["hr", "figure"]
/// Never shown (DocumentConverter's dropped tags); removed when an edit spans them.
private let droppedTags: Set<String> = ["script", "style", "template", "svg", "math", "noscript", "iframe", "object", "title", "head", "textarea", "select"]
private let rawTextTags: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript"]
private let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
