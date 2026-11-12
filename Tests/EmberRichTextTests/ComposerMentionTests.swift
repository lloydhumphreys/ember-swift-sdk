import Testing
import EmberRichText

private let ann = "0abcdefghijklmno"
private let anna = "1abcdefghijklmno"
private let pia = "2abcdefghijklmno"

/// The stored form of a mention, as the server's `canonicalize` (render.ts) writes every mention a
/// client sends, whatever else the web's editor put on it.
private func stored(_ userId: String) -> String {
    "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(userId)\"></action-text-attachment>"
}

@Suite("Composing mentions")
struct ComposerMentionTests {
    @Test func aPickedNameGoesAsTheServersMentionMarkup() {
        let segments = RichText.segments("@Ann can you look", mentions: [ann: "Ann"])
        #expect(segments == [.mention(userId: ann, name: "Ann"), .text(" can you look")])
        #expect(RichText.body(from: segments) == "<p>\(stored(ann)) can you look</p>")
    }

    @Test func aBodyWithAMentionIsTheOneTheServerStores() {
        // body.test.ts and previews.test.ts's stored form: the paragraph, the text around it escaped,
        // line breaks as `<br>`.
        let body = RichText.body(from: RichText.segments("Hi @Pia Montgomery-Fitzwilliam & co\nbye", mentions: [pia: "Pia Montgomery-Fitzwilliam"]))
        #expect(body == "<p>Hi \(stored(pia)) &amp; co<br>bye</p>")
    }

    @Test func everyWholeOccurrenceIsAMentionAndPartsOfWordsAreNot() {
        let segments = RichText.segments("@Ann, @Anna and x@Ann and @Annie. @Ann", mentions: [ann: "Ann", anna: "Anna"])
        #expect(segments == [
            .mention(userId: ann, name: "Ann"), .text(", "),
            .mention(userId: anna, name: "Anna"), .text(" and x@Ann and @Annie. "),
            .mention(userId: ann, name: "Ann"),
        ])
    }

    @Test func aNameNoLongerInTheTextMentionsNobody() {
        #expect(RichText.segments("@An is gone", mentions: [ann: "Ann"]) == [.text("@An is gone")])
        #expect(RichText.segments("", mentions: [ann: "Ann"]) == [.text("")])
        #expect(RichText.body(from: RichText.segments("plain", mentions: [:])) == RichText.body(fromPlainText: "plain"))
    }

    @Test func aMentionNextToPunctuationOrAnotherMentionStillCounts() {
        let segments = RichText.segments("(@Ann)\n@Pia", mentions: [ann: "Ann", pia: "Pia"])
        #expect(segments == [.text("("), .mention(userId: ann, name: "Ann"), .text(")\n"), .mention(userId: pia, name: "Pia")])
    }

    @Test func aMentionsRangeIsWhereItsSegmentStands() {
        let text = "@Ann, @Anna and x@Ann and @Annie. @Ann"
        let ranges = RichText.mentionRanges(in: text, mentions: [ann: "Ann", anna: "Anna"])
        #expect(ranges.map { String(text[$0]) } == ["@Ann", "@Anna", "@Ann"])
        #expect(ranges.last?.upperBound == text.endIndex)
        #expect(RichText.mentionRanges(in: "@An is gone", mentions: [ann: "Ann"]).isEmpty)
    }
}
