import Testing
import EmberRichText

// @here, @channel and @everyone, and "#" and a room's name: written, read and edited.

private let ann = "0abcdefghijklmno"
private let all = RichText.specialMentions

/// The stored form of a mention of someone, or of a special mention by its name.
private func mention(_ sgid: String) -> String {
    "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(sgid)\"></action-text-attachment>"
}

/// The stored form of a mention of a room.
private func room(_ roomId: String) -> String {
    "<action-text-attachment content-type=\"application/vnd.campfire.room\" sgid=\"\(roomId)\"></action-text-attachment>"
}

private func blocks(_ html: String) -> [RichBlock] {
    RichText.document(html: html, plainText: "x", host: "once.campfire.test").blocks
}

private func plain(_ text: String) -> RichInline { .text(text, []) }

@Suite("Composing special and room mentions")
struct ComposingSpecialAndRoomMentionTests {
    @Test func theSpecialMentionsAreNarrowestFirst() {
        #expect(RichText.specialMentions == ["here", "channel", "everyone"])
        #expect(RichText.privateRoomName == "private room")
    }

    @Test func aSpecialMentionGoesAsAMentionOfItsName() {
        let segments = RichText.segments("@channel lunch is here", mentions: [:], specialMentions: all)
        #expect(segments == [.specialMention("channel"), .text(" lunch is here")])
        #expect(RichText.body(from: segments) == "<p>\(mention("channel")) lunch is here</p>")
        #expect(RichText.body(from: [.specialMention("here"), .text(" "), .specialMention("everyone")]) == "<p>\(mention("here")) \(mention("everyone"))</p>")
    }

    @Test func oneTheRoomDoesNotOfferStaysText() {
        // Where channel mentions are off, or only administrators may make them.
        #expect(RichText.segments("@channel lunch", mentions: [:]) == [.text("@channel lunch")])
        #expect(RichText.segments("@everyone and @here", mentions: [:], specialMentions: ["here"]) == [.text("@everyone and "), .specialMention("here")])
        // A name that is no special mention is never one, whoever asks for it.
        #expect(RichText.segments("@team", mentions: [:], specialMentions: ["team"]) == [.text("@team")])
        #expect(RichText.body(from: [.specialMention("team"), .text(" a<b")]) == "<p>@team a&lt;b</p>")
    }

    @Test func onlyAWholeNameCounts() {
        let segments = RichText.segments("@hereafter x@here (@here) @Here @everyone.", mentions: [:], specialMentions: all)
        #expect(segments == [.text("@hereafter x@here ("), .specialMention("here"), .text(") @Here "), .specialMention("everyone"), .text(".")])
    }

    @Test func someoneWithTheNameIsMentionedInstead() {
        let segments = RichText.segments("@here and @channel", mentions: [ann: "here"], specialMentions: all)
        #expect(segments == [.mention(userId: ann, name: "here"), .text(" and "), .specialMention("channel")])
        // The longer name still wins.
        #expect(RichText.segments("@everyone else", mentions: [ann: "every"], specialMentions: all) == [.specialMention("everyone"), .text(" else")])
        #expect(RichText.segments("@here now", mentions: [ann: "here now"], specialMentions: all) == [.mention(userId: ann, name: "here now")])
    }

    @Test func aRoomsNameAfterAHashMentionsTheRoom() {
        let segments = RichText.segments("see #design & #design-crit", mentions: [:], rooms: ["r-design": "design", "r-crit": "design-crit"])
        #expect(segments == [.text("see "), .roomMention(roomId: "r-design", name: "design"), .text(" & "), .roomMention(roomId: "r-crit", name: "design-crit")])
        #expect(RichText.body(from: segments) == "<p>see \(room("r-design")) &amp; \(room("r-crit"))</p>")
    }

    @Test func aRoomIsFoundByTheSameRuleAsAPerson() {
        let rooms = ["r-design": "design"]
        #expect(RichText.segments("#designers x#design #Design (#design)", mentions: [:], rooms: rooms)
            == [.text("#designers x#design #Design ("), .roomMention(roomId: "r-design", name: "design"), .text(")")])
        #expect(RichText.segments("#design", mentions: [:]) == [.text("#design")])
        // "@" and a room's name is no mention of the room, nor "#" and a person's of them.
        #expect(RichText.segments("@design #Ann", mentions: [ann: "Ann"], rooms: rooms) == [.text("@design #Ann")])
        #expect(RichText.segments("#", mentions: [:], rooms: ["r-none": ""]) == [.text("#")])
    }

    @Test func anIdThatNamesNoRoomGoesAsText() {
        #expect(RichText.body(from: [.roomMention(roomId: "R1", name: "a<b")]) == "<p>#a&lt;b</p>")
        #expect(RichText.body(from: [.roomMention(roomId: "", name: "design")]) == "<p>#design</p>")
        #expect(RichText.body(from: [.roomMention(roomId: "-design", name: "design")]) == "<p>#design</p>")
        #expect(RichText.body(from: [.roomMention(roomId: String(repeating: "a", count: 64), name: "design")]) == "<p>#design</p>")
        #expect(RichText.body(from: [.roomMention(roomId: String(repeating: "a", count: 63), name: "design")]) == "<p>\(room(String(repeating: "a", count: 63)))</p>")
    }

    @Test func everyKindOfMentionHasItsRange() {
        let text = "@Ann, @channel: see #design, not #designs or @heretic"
        let ranges = RichText.mentionRanges(in: text, mentions: [ann: "Ann"], specialMentions: all, rooms: ["r-design": "design"])
        #expect(ranges.map { String(text[$0]) } == ["@Ann", "@channel", "#design"])
        #expect(RichText.mentionRanges(in: text, mentions: [ann: "Ann"]).map { String(text[$0]) } == ["@Ann"])
        #expect(RichText.mentionRanges(in: text, mentions: [:]).isEmpty)
    }
}

@Suite("Reading special and room mentions")
struct ReadingSpecialAndRoomMentionTests {
    @Test func aMentionWhoseSgidIsASpecialNameIsThatMention() {
        #expect(blocks("<p>\(mention("channel")) lunch</p>") == [.paragraph([.specialMention("channel"), plain(" lunch")])])
        #expect(blocks("<p>\(mention("here"))\(mention("everyone"))</p>") == [.paragraph([.specialMention("here"), .specialMention("everyone")])])
        // Someone's id is still theirs.
        #expect(blocks("<p>\(mention(ann))</p>") == [.paragraph([.mention(userId: ann)])])
    }

    @Test func aRoomMentionCarriesTheRoomsId() {
        #expect(blocks("<p>see \(room("r-design")) first</p>") == [.paragraph([plain("see "), .roomMention(roomId: "r-design"), plain(" first")])])
        // One with no room shows as a box, as a mention of no one does.
        let empty = "<action-text-attachment content-type=\"application/vnd.campfire.room\"></action-text-attachment>"
        #expect(blocks("<p>\(empty)</p>") == [.paragraph([plain("☒")])])
    }

    @Test func aMentionStandsBetweenTheWordsAroundIt() {
        // A space beside one is kept, as beside a mention of someone.
        #expect(blocks("<p>a \(mention("here")) b \(room("r-design")) c</p>")
            == [.paragraph([plain("a "), .specialMention("here"), plain(" b "), .roomMention(roomId: "r-design"), plain(" c")])])
    }

    @Test func composedBodiesReadBack() {
        let body = RichText.body(from: [.specialMention("everyone"), .text(" see "), .roomMention(roomId: "r-design", name: "design"), .text("\nthanks")])
        #expect(blocks(body) == [.paragraph([.specialMention("everyone"), plain(" see "), .roomMention(roomId: "r-design"), .lineBreak, plain("thanks")])])
    }
}

@Suite("Editing special and room mentions")
struct EditingSpecialAndRoomMentionTests {
    private let rooms = ["r-design": "design"]

    private func editable(_ body: String) -> EditableBody {
        EditableBody(body: body, mentionNames: [ann: "Ann"], roomNames: rooms)
    }

    @Test func eachReadsAsItsSignAndName() {
        #expect(editable("<p>\(mention("channel")) and \(mention(ann)): see \(room("r-design"))</p>").text == "@channel and @Ann: see #design")
        // A room the person editing isn't in.
        #expect(editable("<p>see \(room("r-secret"))</p>").text == "see private room")
        #expect(EditableBody(body: "<p>see \(room("r-design"))</p>").text == "see private room")
    }

    @Test func untouchedOnesStayByteForByte() {
        let body = "<p>\(mention("channel")) see \(room("r-design")) and \(room("r-secret"))</p>"
        #expect(editable(body).body(editedTo: "@channel see #design and private room") == body)
        #expect(editable(body).body(editedTo: "@channel please see #design and private room")
            == "<p>\(mention("channel")) please see \(room("r-design")) and \(room("r-secret"))</p>")
        #expect(editable(body).body(editedTo: "@channel see #design and private room!")
            == "<p>\(mention("channel")) see \(room("r-design")) and \(room("r-secret"))!</p>")
    }

    @Test func cuttingIntoOneLeavesWhatIsLeftAsText() {
        #expect(editable("<p>\(mention("channel")) lunch</p>").body(editedTo: "@chan lunch") == "<p>@chan lunch</p>")
        #expect(editable("<p>see \(room("r-design"))</p>").body(editedTo: "see #des") == "<p>see #des</p>")
    }

    @Test func deletingOneRemovesIt() {
        #expect(editable("<p>\(mention("everyone")) lunch</p>").body(editedTo: " lunch") == "<p> lunch</p>")
        #expect(editable("<p>see \(room("r-secret")) now</p>").body(editedTo: "see  now") == "<p>see  now</p>")
    }

    @Test func aPersonAddedBesideThemLeavesThemAlone() {
        let body = "<p>\(mention("here")) see \(room("r-design"))</p>"
        #expect(editable(body).body(editedTo: "@here see #design with @Ann", mentions: [ann: "Ann"])
            == "<p>\(mention("here")) see \(room("r-design")) with \(mention(ann))</p>")
    }
}
