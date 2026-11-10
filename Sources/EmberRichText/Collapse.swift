import Foundation

/// Collapses whitespace in a run of inlines as a browser lays out a paragraph: ASCII whitespace
/// becomes one space, none at a line's start or end, and non-breaking spaces are kept. The web
/// gets this from CSS, so the model has to do it itself.
enum WhitespaceCollapser {
    private struct State {
        /// A space was seen after text and shows only if more text follows on the same line.
        var pendingSpace = false
        /// Style of the text the space was written in, which is the style it shows in (a struck word's following space is not struck).
        var pendingStyle: RichStyle = []
        var atLineStart = true
    }

    static func collapse(_ inlines: [RichInline]) -> [RichInline] {
        var state = State()
        var out = run(inlines, &state)
        while case .lineBreak? = out.first { out.removeFirst() }
        while case .lineBreak? = out.last { out.removeLast() }
        return out
    }

    private static func isCollapsible(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
    }

    private static func run(_ inlines: [RichInline], _ state: inout State) -> [RichInline] {
        var out: [RichInline] = []
        for item in inlines {
            switch item {
            case .text(let text, let style):
                var buffer = String.UnicodeScalarView()
                for scalar in text.unicodeScalars {
                    if isCollapsible(scalar) {
                        if !state.atLineStart, !state.pendingSpace {
                            state.pendingSpace = true
                            state.pendingStyle = style
                        }
                        continue
                    }
                    if state.pendingSpace {
                        // The space follows the words collected so far, so they go in first.
                        if !buffer.isEmpty {
                            append(&out, String(buffer), style)
                            buffer = String.UnicodeScalarView()
                        }
                        flushSpace(&out, &state)
                    }
                    buffer.append(scalar)
                    state.atLineStart = false
                }
                if !buffer.isEmpty { append(&out, String(buffer), style) }
            case .link(let url, let children):
                if state.pendingSpace, hasVisibleContent(children) { flushSpace(&out, &state) }
                let inner = run(children, &state)
                if !inner.isEmpty { out.append(.link(url: url, inner)) }
            case .mention:
                if state.pendingSpace { flushSpace(&out, &state) }
                state.atLineStart = false
                out.append(item)
            case .lineBreak:
                state.pendingSpace = false
                state.atLineStart = true
                out.append(.lineBreak)
            }
        }
        return out
    }

    private static func flushSpace(_ out: inout [RichInline], _ state: inout State) {
        state.pendingSpace = false
        append(&out, " ", state.pendingStyle)
    }

    private static func append(_ out: inout [RichInline], _ text: String, _ style: RichStyle) {
        if case .text(let previous, let previousStyle)? = out.last, previousStyle == style {
            out[out.count - 1] = .text(previous + text, style)
        } else {
            out.append(.text(text, style))
        }
    }

    private static func hasVisibleContent(_ inlines: [RichInline]) -> Bool {
        for item in inlines {
            switch item {
            case .text(let text, _):
                if text.unicodeScalars.contains(where: { !isCollapsible($0) }) { return true }
            case .link(_, let children):
                if hasVisibleContent(children) { return true }
            case .mention:
                return true
            case .lineBreak:
                continue
            }
        }
        return false
    }
}
