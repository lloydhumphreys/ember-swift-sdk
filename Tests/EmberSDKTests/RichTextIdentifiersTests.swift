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

    // MARK: Special and room mentions

    let design: RoomID = "room-design"

    @Test func aSpecialMentionSegmentByItsCase() {
        let segment = ComposeSegment.specialMention(.channel)
        #expect(segment == .specialMention("channel"))
        #expect(segment.special == .channel)
        #expect(segment.userID == nil && segment.roomID == nil)
        #expect(ComposeSegment.mention(grace, name: "Grace").special == nil)
        // One this SDK doesn't know is still what it is.
        #expect(ComposeSegment.specialMention("team").special == SpecialMention("team"))
    }

    @Test func aRoomMentionSegmentByRoomID() {
        let segment = ComposeSegment.roomMention(design, name: "design")
        #expect(segment == .roomMention(roomId: "room-design", name: "design"))
        #expect(segment.roomID == design)
        #expect(segment.userID == nil && segment.special == nil)
        #expect(ComposeSegment.text("#design").roomID == nil)
    }

    @Test func segmentsAndRangesByEveryKindOfID() {
        let text = "@Grace, @here: see #design"
        let segments = RichText.segments(text, mentions: [grace: "Grace"], specialMentions: [.here, .channel], rooms: [design: "design"])
        #expect(segments == [.mention(grace, name: "Grace"), .text(", "), .specialMention(.here), .text(": see "), .roomMention(design, name: "design")])
        #expect(segments == RichText.segments(text, mentions: ["abcdefghijklmnop": "Grace"], specialMentions: ["here", "channel"], rooms: ["room-design": "design"]))
        let ranges = RichText.mentionRanges(in: text, mentions: [grace: "Grace"], specialMentions: [.here], rooms: [design: "design"])
        #expect(ranges.map { String(text[$0]) } == ["@Grace", "@here", "#design"])
        // What the room doesn't offer, and a room you can't name, stay text.
        #expect(RichText.segments("@here #design", mentions: [grace: "Grace"]) == [.text("@here #design")])
        #expect(RichText.mentionRanges(in: "@here #design", mentions: [grace: "Grace"]).isEmpty)
    }

    @Test func theSpecialMentionsSegmentsMake() {
        let segments: [ComposeSegment] = [
            .specialMention(.everyone), .text(" and "), .specialMention(.here), .mention(grace, name: "Grace"),
            .specialMention(.everyone), .specialMention("team"), .roomMention(design, name: "design"),
        ]
        // Each once, in the order made; a name that's no special mention goes as text, so isn't one.
        #expect(RichText.specialMentions(in: segments) == [.everyone, .here])
        #expect(RichText.specialMentions(in: [.text("@here")]).isEmpty)
        let counts = NotifiedCounts(members: 8, mentions: [.here: 3, .everyone: 12])
        #expect(counts.notifying(RichText.specialMentions(in: segments)) == Notifying(mention: .everyone, people: 12))
    }

    @Test func anEditableBodyByRoomID() {
        let body = RichText.body(from: [.specialMention(.channel), .text(" see "), .roomMention(design, name: "design")])
        #expect(EditableBody(body: body, mentionNames: [grace: "Grace"], roomNames: [design: "design"]).text == "@channel see #design")
        // Without the room's name it's one the person editing can't see.
        #expect(EditableBody(body: body, mentionNames: [grace: "Grace"]).text == "@channel see \(RichText.privateRoomName)")
        let editable = EditableBody(body: body, mentionNames: [UserID: String](), roomNames: [design: "design"])
        #expect(editable.body(editedTo: "@channel see #design with @Grace", mentions: [grace: "Grace"]).hasSuffix("sgid=\"abcdefghijklmnop\"></action-text-attachment></p>"))
    }

    @Test func whatAMentionInABodyIsOf() {
        let body = RichText.body(from: [.specialMention(.here), .text(" "), .roomMention(design, name: "design"), .text(" "), .mention(grace, name: "Grace")])
        let document = RichText.document(html: body, plainText: "@here #design @Grace", host: "ember.test")
        guard case let .paragraph(inlines)? = document.blocks.first else { Issue.record("not a paragraph"); return }
        #expect(inlines.compactMap(\.special) == [.here])
        #expect(inlines.compactMap(\.roomID) == [design])
        #expect(inlines.compactMap(\.userID) == [grace])
        #expect(RichInline.lineBreak.special == nil && RichInline.lineBreak.roomID == nil)
    }
}
