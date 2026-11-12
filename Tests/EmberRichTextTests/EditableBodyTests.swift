import Testing
@testable import EmberRichText

private let userId = "0abcdefghijklmno"
private let mention = "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(userId)\"></action-text-attachment>"
private let image = "<action-text-attachment sgid=\"abc\" content-type=\"image/png\" url=\"https://once.campfire.test/a.png\" filename=\"a.png\"></action-text-attachment>"
private let names = [userId: "Maya"]

private func edit(_ body: String, _ newText: String) -> String {
    EditableBody(body: body, mentionNames: names).body(editedTo: newText)
}

private func text(_ body: String) -> String {
    EditableBody(body: body, mentionNames: names).text
}

private let samId = "1abcdefghijklmno"
private let samMention = "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(samId)\"></action-text-attachment>"

private func edit(_ body: String, _ newText: String, mentions: [String: String]) -> String {
    EditableBody(body: body, mentionNames: names).body(editedTo: newText, mentions: mentions)
}

/// Bodies in the shapes Lexxy, Trix, the server and the composer write, plus a few odd ones.
private let corpus: [String] = [
    "<p>Hello world</p>",
    "<p>Hello <strong>bold</strong> and <em>italic</em> text</p>",
    "<p>See <a href=\"https://example.com/?a=1&amp;b=2\">the docs</a> now</p>",
    "<p>Hi \(mention), welcome</p>",
    "<p>First</p><p>Second</p><p>Third</p>",
    "<ul><li>one</li><li>two <b>bold</b></li><li>three</li></ul>",
    "<ol start=\"3\"><li>a</li><li>b</li></ol><p>after</p>",
    "<blockquote><p>quoted</p></blockquote><p>reply</p>",
    "<pre>let x = 1\nlet y = 2</pre><p>code above</p>",
    "<div>Trix line<br>second line</div><div>next div</div>",
    "<p>Tom &amp; Jerry &lt;3 &gt; caf&eacute; &nbsp;space</p>",
    "<p>Emoji 👍🏽 and 👨‍👩‍👧 and e\u{301}</p>",
    "<p>Photo:</p>\(image)<p>caption</p>",
    "<p>a<br>b<br><br>c</p>",
    "<h1>Title</h1><p>Body <code>code</code> <s>gone</s></p>",
    "<p>\n  Pretty\n  printed\n</p>\n<p>html</p>",
    "<table><tr><td>a</td><td>b</td></tr></table>",
    "<p><strong><em>nested</em> styles</strong> end</p>",
    "<p>   </p>",
    "<p>AT&T and 1 < 2</p>",
    "plain text, no markup",
    "",
    "<p></p>",
    "<p>x<!-- a comment -->y</p>",
]

@Suite("EditableBody")
struct EditableBodyTests {
    // MARK: Invariants

    @Test func unchangedTextGivesBackTheBodyByteForByte() {
        for body in corpus + ["<p>broken <b>markup</p>", "<div><p>unclosed"] {
            let editable = EditableBody(body: body, mentionNames: names)
            #expect(editable.body(editedTo: editable.text) == body)
        }
    }

    @Test func bodyFromPlainTextReadsBackExactly() {
        let samples = ["", "hello", "  two spaces  ", "a\nb", "a\n\nb", "\n", "a\n", "\nlead", "tab\there", "& < > \u{A0}", "👍🏽 e\u{301}", "&amp; literal"]
        for sample in samples {
            #expect(text(RichText.body(fromPlainText: sample)) == sample)
        }
    }

    @Test func randomEditsRoundTripAndKeepUntouchedLines() {
        var generator = SeededGenerator(seed: 0x5EED)
        let insertions = ["", "x", "Z ", "\n", "é", "👍🏽", "&", "<b>", " ", "a\nb", "&amp;", "\u{301}"]
        for body in corpus {
            let original = EditableBody(body: body, mentionNames: names)
            let characters = Array(original.text)
            for _ in 0..<60 {
                let lower = Int.random(in: 0...characters.count, using: &generator)
                let upper = Int.random(in: lower...min(characters.count, lower + 6), using: &generator)
                let typed = insertions.randomElement(using: &generator)!
                let newText = String(characters[..<lower]) + typed + String(characters[upper...])
                let result = original.body(editedTo: newText)
                #expect(EditableBody(body: result, mentionNames: names).text == newText, "\(body) -> \(newText.debugDescription)")
                #expect((try? HTMLTreeBuilder.parse(result)) != nil)
                guard newText != original.text, let layout = original.layout else { continue }
                #expect(original.splice(editedTo: newText) != nil, "lost formatting: \(body) -> \(newText.debugDescription)")
                if original.splice(editedTo: newText) != nil {
                    expectUntouchedLinesKept(layout, original.text, newText, result)
                }
            }
        }
    }

    /// Every line wholly before or after the edit (with one line of slack each side) keeps its bytes.
    private func expectUntouchedLinesKept(_ layout: Layout, _ oldText: String, _ newText: String, _ result: String) {
        let old = Array(oldText), new = Array(newText)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // The layout lines the change starts and ends in: block breaks before those text offsets.
        func line(atScalar offset: Int) -> Int {
            layout.units.filter { $0.kind == .blockBreak && $0.textEnd <= offset }.count
        }
        let firstLine = line(atScalar: String(old[..<prefix]).unicodeScalars.count)
        let lastLine = line(atScalar: String(old[..<(old.count - suffix)]).unicodeScalars.count)
        let source = layout.source
        let out = Array(result.unicodeScalars)
        for (index, line) in layout.lines.enumerated() {
            if index < firstLine - 1 {
                #expect(Array(out.prefix(line.upperBound)) == Array(source.prefix(line.upperBound)))
            }
            if index > lastLine + 1 {
                #expect(Array(out.suffix(source.count - line.lowerBound)) == Array(source[line.lowerBound...]))
            }
        }
    }

    @Test func resultsUseOnlyTagsFromTheBodyOrTheComposer() {
        var generator = SeededGenerator(seed: 42)
        for body in corpus where !body.isEmpty {
            let original = EditableBody(body: body, mentionNames: names)
            let allowed = tagNames(body).union(["p", "br"])
            let characters = Array(original.text)
            for _ in 0..<20 {
                let lower = Int.random(in: 0...characters.count, using: &generator)
                let upper = Int.random(in: lower...characters.count, using: &generator)
                let result = original.body(editedTo: String(characters[..<lower]) + "new\ntext" + String(characters[upper...]))
                #expect(tagNames(result).isSubset(of: allowed), "\(result)")
            }
        }
    }

    private func tagNames(_ html: String) -> Set<String> {
        guard let root = try? HTMLTreeBuilder.parse(html) else { return [] }
        return Set(root.descendantElements().map(\.name))
    }

    // MARK: Named cases

    @Test func typoFixedInsideBoldStaysBold() {
        #expect(edit("<p>Hello <strong>wrold</strong>!</p>", "Hello world!") == "<p>Hello <strong>world</strong>!</p>")
    }

    @Test func editInsideALinkKeepsItsHref() {
        let body = "<p>See <a href=\"https://example.com/?a=1&amp;b=2\">the docs</a> now</p>"
        #expect(edit(body, "See the new docs now") == "<p>See <a href=\"https://example.com/?a=1&amp;b=2\">the new docs</a> now</p>")
    }

    @Test func typingJustAfterALinkDoesNotExtendIt() {
        #expect(edit("<p><a href=\"https://x.test\">x.test</a></p>", "x.test thanks") == "<p><a href=\"https://x.test\">x.test</a> thanks</p>")
    }

    @Test func typingAtTheEndOfABoldRunContinuesIt() {
        #expect(edit("<p><b>bold</b> plain</p>", "bolder plain") == "<p><b>bolder</b> plain</p>")
    }

    @Test func typingAtTheStartOfALineTakesTheFormattingAfterIt() {
        #expect(edit("<p>a</p><p><b>b</b></p>", "a\nxb") == "<p>a</p><p><b>xb</b></p>")
    }

    @Test func editingOneListItemKeepsTheList() {
        let body = "<ul><li>one</li><li>two</li><li>three</li></ul>"
        #expect(text(body) == "one\ntwo\nthree")
        #expect(edit(body, "one\n2\nthree") == "<ul><li>one</li><li>2</li><li>three</li></ul>")
    }

    @Test func untouchedMentionStays() {
        let body = "<p>Hi \(mention), welcome</p>"
        #expect(text(body) == "Hi @Maya, welcome")
        #expect(edit(body, "Hi @Maya, welcome aboard") == "<p>Hi \(mention), welcome aboard</p>")
    }

    @Test func cuttingIntoAMentionKeepsWhatIsLeftAsPlainText() {
        let body = "<p>Hi \(mention)!</p>"
        #expect(edit(body, "Hi @May!") == "<p>Hi @May!</p>")
    }

    @Test func deletingAWholeMentionRemovesIt() {
        #expect(edit("<p>Hi \(mention)!</p>", "Hi !") == "<p>Hi !</p>")
    }

    @Test func untouchedAttachmentStays() {
        let body = "<p>Photo:</p>\(image)<p>caption</p>"
        #expect(text(body) == "Photo:\ncaption")
        #expect(edit(body, "Photo:\nnew caption") == "<p>Photo:</p>\(image)<p>new caption</p>")
    }

    @Test func attachmentsSurviveAnEditThatSpansThem() {
        let body = "<p>see\(image)here</p>"
        #expect(edit(body, "shere") == "<p>s\(image)here</p>")
    }

    @Test func textAppendedAtTheEnd() {
        #expect(edit("<p>Hello <em>there</em></p>", "Hello there, friend") == "<p>Hello <em>there, friend</em></p>")
    }

    @Test func textPrepended() {
        #expect(edit("<p><strong>Hello</strong></p>", "Oh, Hello") == "<p><strong>Oh, Hello</strong></p>")
    }

    @Test func everythingDeleted() {
        let body = "<p>One <b>two</b></p><ul><li>three</li></ul>"
        let result = edit(body, "")
        #expect(text(result) == "")
        #expect((try? HTMLTreeBuilder.parse(result)) != nil)
    }

    @Test func emojiAndCombinedCharactersAreNeverSplit() {
        let body = "<p>a👍🏽b e\u{301}</p>"
        #expect(edit(body, "a👍b e\u{301}") == "<p>a👍b e\u{301}</p>")
        #expect(edit(body, "a👍🏽b e") == "<p>a👍🏽b e</p>")
    }

    @Test func entitiesStayEscapedAndAreNeverSplit() {
        let body = "<p>Tom &amp; Jerry &lt;3</p>"
        #expect(text(body) == "Tom & Jerry <3")
        #expect(edit(body, "Tom & Jerry <3 <b>") == "<p>Tom &amp; Jerry &lt;3 &lt;b&gt;</p>")
        #expect(edit(body, "Tom and Jerry <3") == "<p>Tom and Jerry &lt;3</p>")
    }

    @Test func typedLineBreaksBecomeBr() {
        #expect(edit("<p><b>ab</b></p>", "a\nb") == "<p><b>a<br>b</b></p>")
    }

    @Test func deletingTheBreakBetweenBlocksJoinsThem() {
        #expect(edit("<p>ab</p><p><i>cd</i></p>", "abcd") == "<p>ab<i>cd</i></p>")
        #expect(edit("<p>a</p><ul><li>b</li><li>c</li></ul>", "ab\nc") == "<p>ab</p><ul><li>c</li></ul>")
    }

    @Test func deletingALineInTheMiddleKeepsAnEmptyLine() {
        let result = edit("<p>a</p><p>b</p><p>c</p>", "a\n\nc")
        #expect(text(result) == "a\n\nc")
    }

    @Test func oddOrBrokenHTMLFallsBackToPlainText() {
        for body in ["<p>broken <b>markup</p>", "<div><p>unclosed", "<p>stray</b></p>", "<b/>x"] {
            let editable = EditableBody(body: body)
            #expect(editable.layout == nil)
            #expect(editable.body(editedTo: editable.text) == body)
            #expect(editable.body(editedTo: editable.text + "!") == RichText.body(fromPlainText: editable.text + "!"))
        }
        #expect(text("<p>broken <b>markup</p>") == "broken markup")
    }

    @Test func pathologicalInputNeverTraps() {
        let inputs = ["<", "<a", "</", "<!--", "&", "&#", "&#x110000;", String(repeating: "<b>", count: 500) + "x", "<p a=\"unclosed>x</p>", "\u{0}"]
        for input in inputs {
            let editable = EditableBody(body: input)
            _ = editable.body(editedTo: editable.text + "x")
            _ = editable.body(editedTo: "")
            _ = editable.body(editedTo: editable.text + " @Sam", mentions: [samId: "Sam"])
            _ = editable.body(editedTo: "@Sam", mentions: [samId: "Sam"])
        }
    }

    // MARK: Adding mentions

    @Test func typedNameOfSomeoneChosenBecomesAMention() {
        #expect(edit("<p>Thanks all</p>", "Thanks @Sam all", mentions: [samId: "Sam"]) == "<p>Thanks \(samMention) all</p>")
        #expect(edit("<p>Over to</p>", "Over to @Sam ", mentions: [samId: "Sam"]) == "<p>Over to \(samMention) </p>")
        #expect(edit("<p>hi</p>", "@Sam hi", mentions: [samId: "Sam"]) == "<p>\(samMention) hi</p>")
    }

    @Test func mentionTypedInsideBoldStaysInBold() {
        #expect(edit("<p><strong>hi there</strong></p>", "hi @Sam there", mentions: [samId: "Sam"]) == "<p><strong>hi \(samMention) there</strong></p>")
    }

    @Test func mentionsAlreadyThereStayByteForByte() {
        let body = "<p>Hi \(mention), welcome</p><ul><li><b>one</b></li></ul>"
        #expect(edit(body, "Hi @Maya, welcome @Sam\none", mentions: [samId: "Sam"]) == "<p>Hi \(mention), welcome \(samMention)</p><ul><li><b>one</b></li></ul>")
    }

    @Test func choosingSomeoneAlreadyMentionedLeavesTheBodyAlone() {
        let body = "<p>Hi \(mention)</p>"
        #expect(edit(body, "Hi @Maya", mentions: [userId: "Maya"]) == body)
    }

    @Test func anotherPersonWithTheSameNameGetsTheirOwnMention() {
        #expect(edit("<p>Hi \(mention)</p>", "Hi @Maya and @Maya", mentions: [samId: "Maya"]) == "<p>Hi \(mention) and \(samMention)</p>")
    }

    @Test func nameAlreadyThereAsPlainTextBecomesAMention() {
        // As the composer does: every "@Name" of someone chosen is a mention of them.
        #expect(edit("<p>ask @Sam about it</p>", "ask @Sam about it", mentions: [samId: "Sam"]) == "<p>ask \(samMention) about it</p>")
        #expect(edit("<p>ask <em>@Sam</em></p>", "ask @Sam", mentions: [samId: "Sam"]) == "<p>ask <em>\(samMention)</em></p>")
    }

    @Test func nameSplitAcrossFormattingBecomesOneMention() {
        let result = edit("<p>@<b>Sam</b> hi</p>", "@Sam hi", mentions: [samId: "Sam"])
        #expect(result == "<p>\(samMention) hi</p>")
    }

    @Test func nameInsideALinkOrCodeStaysText() {
        let body = "<p><a href=\"https://x.test\">@Sam</a> and <code>@Sam</code></p><pre>@Sam</pre>"
        #expect(edit(body, "@Sam and @Sam\n@Sam", mentions: [samId: "Sam"]) == body)
        #expect(edit(body, "@Sam and @Sam!\n@Sam", mentions: [samId: "Sam"]) == "<p><a href=\"https://x.test\">@Sam</a> and <code>@Sam!</code></p><pre>@Sam</pre>")
    }

    @Test func onlyAWholeNameBecomesAMention() {
        #expect(edit("<p>hi</p>", "hi @Samuel and x@Sam", mentions: [samId: "Sam"]) == "<p>hi @Samuel and x@Sam</p>")
    }

    @Test func nameThatRunsIntoAMentionStaysText() {
        // "@Maya" is a mention; a chosen "Maya Lin" can't take it over.
        let body = "<p>\(mention) Lin</p>"
        #expect(edit(body, "@Maya Lin", mentions: [samId: "Maya Lin"]) == body)
    }

    @Test func chosenNameOtherThanTheShownOneStillMentions() {
        // Someone the body mentions as "Maya" chosen again as "Maya Lin": the new mention reads as
        // the old one does.
        #expect(edit("<p>Hi \(mention)</p>", "Hi @Maya and @Maya Lin", mentions: [userId: "Maya Lin"]) == "<p>Hi \(mention) and \(mention)</p>")
    }

    @Test func idTheServerWouldRefuseChangesNothing() {
        #expect(edit("<p>Hi</p>", "Hi @Sam", mentions: ["not-a-user": "Sam"]) == "<p>Hi @Sam</p>")
        #expect(edit("<p>Hi @Sam</p>", "Hi @Sam", mentions: ["not-a-user": "Sam"]) == "<p>Hi @Sam</p>")
    }

    @Test func noMentionsIsBodyEditedTo() {
        for body in corpus {
            let editable = EditableBody(body: body, mentionNames: names)
            for newText in [editable.text, editable.text + " @Sam", "x" + editable.text] {
                #expect(editable.body(editedTo: newText, mentions: [:]) == editable.body(editedTo: newText))
            }
        }
    }

    @Test func unmappableBodyFallsBackToTheComposersBody() {
        let editable = EditableBody(body: "<p>broken <b>markup</p>")
        #expect(editable.body(editedTo: "broken markup @Sam", mentions: [samId: "Sam"]) == "<p>broken markup \(samMention)</p>")
        #expect(editable.body(editedTo: "broken markup", mentions: [samId: "Sam"]) == "<p>broken <b>markup</p>")
    }

    @Test func randomMentionsRoundTripAndKeepUntouchedLines() {
        var generator = SeededGenerator(seed: 0xA7)
        let people = [samId: "Sam", userId: "Maya"]
        var known = names
        known[samId] = "Sam"
        for body in corpus {
            let original = EditableBody(body: body, mentionNames: names)
            let characters = Array(original.text)
            let plainish = !body.contains("<a ") && !body.contains("<code") && !body.contains("<pre")
            for _ in 0..<40 {
                let lower = Int.random(in: 0...characters.count, using: &generator)
                let upper = Int.random(in: lower...min(characters.count, lower + 4), using: &generator)
                let newText = String(characters[..<lower]) + " @Sam " + String(characters[upper...])
                let result = original.body(editedTo: newText, mentions: people)
                #expect(EditableBody(body: result, mentionNames: known).text == newText, "\(body) -> \(newText.debugDescription)")
                #expect((try? HTMLTreeBuilder.parse(result)) != nil)
                if plainish { #expect(result.contains(samMention), "\(body) -> \(newText.debugDescription): \(result)") }
                // A mention never costs formatting the same edit without one keeps.
                guard let layout = original.layout, original.splice(editedTo: newText) != nil else { continue }
                #expect(original.splice(editedTo: newText, mentions: people) != nil, "lost formatting: \(body) -> \(newText.debugDescription)")
                if original.splice(editedTo: newText, mentions: people) != nil {
                    expectUntouchedLinesKept(layout, original.text, newText, result)
                }
            }
        }
    }
}

/// SplitMix64, so the random edits are the same every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
