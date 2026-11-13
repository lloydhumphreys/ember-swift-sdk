import EmberRichText
import Foundation
import EmberSDK
import Testing

/// The `UserID` forms of EmberRichText's mention calls, which take a user's id as a String.
@Suite struct RichTextIdentifiersTests {
    let grace: UserID = "abcdefghijklmnop"

    @Test func aMentionSegmentByUserID() {
        let segment = ComposeSegment.mention(grace, name: "Grace")
        #expect(segment == .mention(userId: "abcdefghijklmnop", name: "Grace"))
        #expect(segment.userID == grace)
        #expect(ComposeSegment.text("hi").userID == nil)
    }

    @Test func segmentsAndRangesByUserID() {
        let text = "Hi @Grace"
        #expect(RichText.segments(text, mentions: [grace: "Grace"]) == RichText.segments(text, mentions: ["abcdefghijklmnop": "Grace"]))
        #expect(RichText.mentionRanges(in: text, mentions: [grace: "Grace"]).count == 1)
    }

    @Test func anEditableBodyByUserID() {
        let body = RichText.body(from: [.text("Hi "), .mention(grace, name: "Grace")])
        let editable = EditableBody(body: body, mentionNames: [grace: "Grace"])
        #expect(editable.text == "Hi @Grace")
        #expect(editable.body(editedTo: "Hi @Grace and @Grace", mentions: [grace: "Grace"]).components(separatedBy: "sgid=\"abcdefghijklmnop\"").count == 3)
    }

    @Test func whoAMentionInABodyIsOf() {
        let body = RichText.body(from: [.mention(grace, name: "Grace")])
        let document = RichText.document(html: body, plainText: "@Grace", host: "ember.test")
        guard case let .paragraph(inlines)? = document.blocks.first else { Issue.record("not a paragraph"); return }
        #expect(inlines.compactMap(\.userID) == [grace])
        #expect(RichInline.lineBreak.userID == nil)
    }
}
