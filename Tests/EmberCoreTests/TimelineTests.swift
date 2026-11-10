import Foundation
import Testing
@testable import EmberCore

/// A timeline welcomed, as `ada`, with `messages` and the page's flags.
private func welcomed(_ messages: [Message], hasMore: Bool = false, hasNewer: Bool = false, around: String? = nil, seq: Int = 1) -> Timeline {
    var timeline = Timeline()
    _ = timeline.apply(.welcome(you: ada, present: [ada], seq: seq, page: TimelinePage(messages: messages, hasMore: hasMore, hasNewer: hasNewer, around: around)))
    return timeline
}

/// A message `ada` sent from here, as the room confirms it.
private func mine(_ id: String, _ clientMessageId: String) -> Message {
    message(id, by: ada, clientMessageId: clientMessageId)
}

@Suite struct TimelineTests {
    @Test func welcomeShowsThePage() {
        let timeline = welcomed(stored(1, 3), hasMore: true, seq: 4)
        #expect(timeline.isLoaded)
        #expect(timeline.me == ada)
        #expect(timeline.messages.map(\.id) == ["m001", "m002", "m003"])
        #expect(timeline.hasMore && !timeline.hasNewer)
        #expect(timeline.seq == 4)
        #expect(timeline.present == [ada])
        #expect(timeline.message("m002")?.id == "m002")
        #expect(timeline.message("m009") == nil)
    }

    @Test func quickSendsConfirmedOutOfOrderGoInTheOrderConfirmed() {
        var timeline = welcomed([])
        let first = timeline.send(body: "<p>One</p>", plainText: "One", clientMessageId: "c1", now: noon())
        _ = timeline.send(body: "<p>Two</p>", plainText: "Two", clientMessageId: "c2", now: noon(1))
        #expect(first == .createMessage(clientMessageId: "c1", body: "<p>One</p>"))
        #expect(timeline.pending.map(\.id) == ["c1", "c2"])

        _ = timeline.apply(.messageCreated(mine("m002", "c2"), seq: 2))
        #expect(timeline.pending.map(\.id) == ["c1"])
        _ = timeline.apply(.messageCreated(mine("m003", "c1"), seq: 3))
        #expect(timeline.pending.isEmpty)
        #expect(timeline.messages.map(\.id) == ["m002", "m003"])
        #expect(timeline.seq == 3)
    }

    @Test func someoneElsesMessageCantConfirmMineByReusingItsId() {
        var timeline = welcomed([])
        _ = timeline.send(body: "Hi", plainText: "Hi", clientMessageId: "c1")
        _ = timeline.apply(.messageCreated(message("m001", by: grace, clientMessageId: "c1"), seq: 2))
        #expect(timeline.pending.map(\.id) == ["c1"])
        #expect(timeline.messages.map(\.id) == ["m001"])
    }

    @Test func aRefusedMessageFailsAndCanBeRetriedOrDiscarded() {
        var timeline = welcomed([])
        _ = timeline.send(body: "Hi", plainText: "Hi", clientMessageId: "c1")
        _ = timeline.apply(.error(message: "Too long", clientMessageId: "c1", clientMessageIds: nil, failed: "message.create"))
        #expect(timeline.pending.first?.failure == "Too long")
        #expect(timeline.retry("c1") == .createMessage(clientMessageId: "c1", body: "Hi"))
        #expect(timeline.pending.first?.failure == nil)
        #expect(timeline.retry("c9") == nil)
        timeline.discard("c1")
        #expect(timeline.pending.isEmpty)
    }

    @Test func anErrorAboutNoMessageOfMineChangesNothing() {
        var timeline = welcomed([])
        _ = timeline.send(body: "Hi", plainText: "Hi", clientMessageId: "c1")
        let before = timeline
        _ = timeline.apply(.error(message: "No", clientMessageId: "c9", clientMessageIds: nil, failed: "message.create"))
        _ = timeline.apply(.error(message: "No", clientMessageId: nil, clientMessageIds: nil, failed: nil))
        _ = timeline.apply(.error(message: "No", clientMessageId: "c1", clientMessageIds: nil, failed: "thread.open"))
        #expect(timeline == before)
        _ = timeline.apply(.error(message: "No", clientMessageId: nil, clientMessageIds: ["c1"], failed: "message.check"))
        #expect(timeline.pending.first?.failure == "No")
    }

    @Test func aReconnectChecksWhatsPendingAndTheCheckSettlesIt() {
        var timeline = welcomed([])
        for n in 1 ... 52 { _ = timeline.send(body: "\(n)", plainText: "\(n)", clientMessageId: "c\(n)") }
        _ = timeline.apply(.error(message: "No", clientMessageId: "c52", clientMessageIds: nil, failed: "message.create"))
        timeline.disconnected()

        let checks = timeline.apply(.resumed(you: ada, messages: [], deletedIds: [], present: [], seq: 5))
        #expect(checks.count == 2)
        guard case let .checkMessages(firstIds) = checks[0], case let .checkMessages(secondIds) = checks[1] else {
            Issue.record("\(checks)"); return
        }
        #expect(firstIds.count == Limits.checkedMessages)
        #expect(secondIds == ["c51"])

        let resent = timeline.apply(.messageChecked(stored: (1 ... 49).map { "c\($0)" }, missing: ["c50", "c52"]))
        #expect(resent == [.createMessage(clientMessageId: "c50", body: "50")])
        #expect(timeline.pending.map(\.id) == ["c50", "c51", "c52"])
    }

    @Test func aWelcomeKeepsWhatItDoesntConfirm() {
        var timeline = welcomed([])
        _ = timeline.send(body: "One", plainText: "One", clientMessageId: "c1")
        _ = timeline.send(body: "Two", plainText: "Two", clientMessageId: "c2")
        let checks = timeline.apply(.welcome(you: ada, present: [], seq: 3, page: TimelinePage(messages: [mine("m001", "c1")])))
        #expect(timeline.pending.map(\.id) == ["c2"])
        #expect(checks == [.checkMessages(clientMessageIds: ["c2"])])
        var empty = welcomed([])
        #expect(empty.apply(.welcome(you: ada, present: [], seq: 1, page: TimelinePage(messages: []))) == [])
    }

    @Test func resumedCatchesUp() {
        var timeline = welcomed(stored(1, 3), hasMore: true)
        _ = timeline.send(body: "Mine", plainText: "Mine", clientMessageId: "c-mine")
        var edited = message("m002", text: "Edited")
        edited.editedAt = noon(1)
        let reply = message("m005", parentId: "m002")
        let checks = timeline.apply(.resumed(
            you: ada, messages: [edited, message("m004"), reply, mine("m006", "c-mine")], deletedIds: ["m001"], present: [grace], seq: 9
        ))
        #expect(timeline.messages.map(\.id) == ["m002", "m003", "m004", "m006"])
        #expect(timeline.message("m002")?.plainText == "Edited")
        #expect(timeline.pending.isEmpty)
        #expect(checks.isEmpty)
        #expect(timeline.present == [grace])
        #expect(timeline.seq == 9)
    }

    @Test func resumedIgnoresChangesOutsideThePage() {
        // A page around m010, with older and newer messages left out.
        var timeline = welcomed(stored(9, 11), hasMore: true, hasNewer: true, around: "m010")
        _ = timeline.apply(.resumed(you: ada, messages: [message("m002"), message("m050"), message("m0105")], deletedIds: [], present: [], seq: 2))
        #expect(timeline.messages.map(\.id) == ["m009", "m010", "m0105", "m011"])
    }

    @Test func pagingKeepsItsBoundsAfterDeletes() {
        var timeline = welcomed(stored(5, 7), hasMore: true)
        _ = timeline.apply(.messageDeleted(messageId: "m005", seq: 2))
        #expect(timeline.messages.map(\.id) == ["m006", "m007"])
        #expect(timeline.olderPage() == .historyBefore(messageId: "m005"))
        #expect(timeline.isLoadingOlder)
        #expect(timeline.olderPage() == nil)
        _ = timeline.apply(.history(before: "m005", messages: stored(1, 4), hasMore: false))
        #expect(timeline.messages.map(\.id) == ["m001", "m002", "m003", "m004", "m006", "m007"])
        #expect(!timeline.hasMore && !timeline.isLoadingOlder)
        #expect(timeline.olderPage() == nil)
    }

    @Test func pagingNewerAfterAJump() {
        var timeline = welcomed(stored(1, 3))
        #expect(timeline.newerPage() == nil)
        #expect(timeline.pageAround("m010") == .historyAround(messageId: "m010"))
        #expect(timeline.isLoadingPage)
        _ = timeline.apply(.historyAround(TimelinePage(messages: stored(9, 11), hasMore: true, hasNewer: true, around: "m010")))
        #expect(!timeline.isLoadingPage)
        #expect(timeline.anchor == "m010")
        #expect(timeline.messages.map(\.id) == ["m009", "m010", "m011"])

        #expect(timeline.newerPage() == .historyAfter(messageId: "m011"))
        #expect(timeline.newerPage() == nil)
        _ = timeline.apply(.historyAfter(after: "m011", messages: stored(12, 13), hasNewer: false))
        #expect(timeline.messages.map(\.id) == ["m009", "m010", "m011", "m012", "m013"])
        #expect(!timeline.hasNewer && !timeline.isLoadingNewer)
    }

    @Test func stalePagesAreDropped() {
        var timeline = welcomed(stored(5, 6), hasMore: true, hasNewer: true)
        _ = timeline.olderPage()
        _ = timeline.apply(.history(before: "m003", messages: stored(1, 2), hasMore: false))
        #expect(timeline.messages.map(\.id) == ["m005", "m006"])
        #expect(timeline.hasMore && !timeline.isLoadingOlder)
        _ = timeline.newerPage()
        _ = timeline.apply(.historyAfter(after: "m009", messages: stored(10, 11), hasNewer: false))
        #expect(timeline.messages.map(\.id) == ["m005", "m006"])
        #expect(timeline.hasNewer && !timeline.isLoadingNewer)
    }

    @Test func aFailedPageStopsLoading() {
        var timeline = welcomed(stored(5, 6), hasMore: true, hasNewer: true)
        _ = timeline.olderPage()
        _ = timeline.newerPage()
        _ = timeline.pageAround(nil)
        _ = timeline.apply(.error(message: "No", clientMessageId: nil, clientMessageIds: nil, failed: "history.before"))
        #expect(!timeline.isLoadingOlder && timeline.isLoadingNewer && timeline.isLoadingPage)
        _ = timeline.apply(.error(message: "No", clientMessageId: nil, clientMessageIds: nil, failed: "history.after"))
        _ = timeline.apply(.error(message: "No", clientMessageId: nil, clientMessageIds: nil, failed: "history.around"))
        #expect(!timeline.isLoadingNewer && !timeline.isLoadingPage)
    }

    @Test func newMessagesCutTheOldestPastTheLeeway() {
        var timeline = welcomed(stored(1, 320))
        _ = timeline.send(body: "Mine", plainText: "Mine", clientMessageId: "c-mine")
        #expect(timeline.messages.count == 320)
        _ = timeline.apply(.messageCreated(message(id(321)), seq: 2))
        #expect(timeline.messages.count == Limits.timelineMessages)
        #expect(timeline.messages.first?.id == "m022")
        #expect(timeline.hasMore)
        #expect(timeline.pending.count == 1)
        #expect(timeline.olderPage() == .historyBefore(messageId: "m022"))
    }

    @Test func olderPagesCutTheNewest() {
        var timeline = welcomed(stored(100, 399), hasMore: true)
        _ = timeline.olderPage()
        _ = timeline.apply(.history(before: "m100", messages: stored(60, 99), hasMore: true))
        #expect(timeline.messages.count == Limits.timelineMessages)
        #expect(timeline.messages.first?.id == "m060")
        #expect(timeline.messages.last?.id == "m359")
        #expect(timeline.hasNewer)
        #expect(timeline.newerPage() == .historyAfter(messageId: "m359"))
    }

    @Test func hasNewerHoldsNewMessagesBack() {
        var timeline = welcomed(stored(9, 11), hasMore: true, hasNewer: true, around: "m010")
        _ = timeline.apply(.messageCreated(message("m500"), seq: 2))
        #expect(timeline.messages.map(\.id) == ["m009", "m010", "m011"])
        #expect(timeline.arrivals == 1)
        _ = timeline.apply(.historyAround(TimelinePage(messages: stored(498, 500), hasMore: true)))
        #expect(timeline.arrivals == 0)
        #expect(timeline.messages.map(\.id) == ["m498", "m499", "m500"])
        #expect(timeline.anchor == nil)
    }

    @Test func aMessageCreatedTwiceIsReplacedInPlace() {
        var timeline = welcomed(stored(1, 2))
        _ = timeline.apply(.messageCreated(message("m001", text: "Again"), seq: 2))
        #expect(timeline.messages.map(\.id) == ["m001", "m002"])
        #expect(timeline.message("m001")?.plainText == "Again")
    }

    @Test func threadRepliesStayOutUnlessAlsoSent() {
        var timeline = welcomed(stored(1, 1))
        _ = timeline.apply(.messageCreated(message("m002", parentId: "m001"), seq: 2))
        _ = timeline.apply(.messageCreated(message("m003", parentId: "m001", alsoSent: true), seq: 3))
        #expect(timeline.messages.map(\.id) == ["m001", "m003"])
    }

    @Test func anEditRetellsTheParentInItsReplies() {
        var reply = message("m002", parentId: "m001", alsoSent: true)
        reply.parentText = "Message m001"
        var timeline = welcomed([message("m001"), reply])
        let long = String(repeating: "é", count: 200)
        _ = timeline.apply(.messageUpdated(message("m001", text: long), seq: 2))
        #expect(timeline.message("m001")?.plainText == long)
        #expect(timeline.message("m002")?.parentText == String(repeating: "é", count: Limits.parentText))
    }

    @Test func boostsComeAndGo() {
        var timeline = welcomed(stored(1, 1))
        let boost = Boost(id: "b1", messageId: "m001", booster: grace, content: "🎉", createdAt: noon())
        _ = timeline.apply(.boostCreated(boost, seq: 2))
        _ = timeline.apply(.boostCreated(boost, seq: 3))
        #expect(timeline.message("m001")?.boosts == [boost])
        _ = timeline.apply(.boostCreated(Boost(id: "b2", messageId: "m404", booster: grace, content: "x", createdAt: noon()), seq: 4))
        _ = timeline.apply(.boostDeleted(boostId: "b1", messageId: "m001", seq: 5))
        #expect(timeline.message("m001")?.boosts == [])
        #expect(timeline.seq == 5)
    }

    @Test func presenceAndTyping() {
        var timeline = welcomed([])
        _ = timeline.apply(.presenceJoined(grace))
        _ = timeline.apply(.presenceJoined(grace))
        #expect(timeline.present == [ada, grace])
        _ = timeline.apply(.typing(user: grace, typing: true, threadId: nil))
        _ = timeline.apply(.typing(user: grace, typing: true, threadId: nil))
        _ = timeline.apply(.typing(user: linus, typing: true, threadId: "m001"))
        _ = timeline.apply(.typing(user: ada, typing: true, threadId: nil))
        #expect(timeline.typing == [grace])
        _ = timeline.apply(.messageCreated(message("m001", by: grace), seq: 2))
        #expect(timeline.typing.isEmpty)
        _ = timeline.apply(.typing(user: grace, typing: true, threadId: nil))
        _ = timeline.apply(.presenceLeft(userId: "u2"))
        #expect(timeline.present == [ada])
        #expect(timeline.typing.isEmpty)
        _ = timeline.apply(.typing(user: linus, typing: true, threadId: nil))
        _ = timeline.apply(.typing(user: linus, typing: false, threadId: nil))
        #expect(timeline.typing.isEmpty)
    }

    @Test func disconnectingStopsTypingAndLoading() {
        var timeline = welcomed(stored(5, 6), hasMore: true)
        _ = timeline.apply(.typing(user: grace, typing: true, threadId: nil))
        _ = timeline.olderPage()
        timeline.disconnected()
        #expect(timeline.typing.isEmpty && !timeline.isLoadingOlder)
        #expect(timeline.messages.count == 2)
    }

    @Test func threadFramesLeaveTheTimelineAlone() {
        let timeline = welcomed(stored(1, 2))
        var after = timeline
        _ = after.apply(.threadOpened(parentId: "m001", parent: message("m001"), messages: [message("m003", parentId: "m001")], hasMore: false))
        _ = after.apply(.threadHistory(parentId: "m001", before: "m003", messages: [], hasMore: false))
        _ = after.apply(.pong)
        _ = after.apply(.unknown("future"))
        #expect(after == timeline)
    }

    @Test func sendDefaultsToALowercaseUUID() {
        var timeline = Timeline()
        guard case let .createMessage(clientMessageId, _, nil, nil) = timeline.send(body: "Hi", plainText: "Hi") else {
            Issue.record("not a message.create"); return
        }
        #expect(clientMessageId == clientMessageId.lowercased())
        #expect(UUID(uuidString: clientMessageId) != nil)
    }
}

/// What `seq` says the timeline has heard, and what counts as an arrival past the window.
@Suite struct TimelineOrderTests {
    @Test func aGapStopsSeqWhereItWas() {
        var timeline = welcomed([], seq: 0)
        _ = timeline.apply(.messageCreated(message("m001"), seq: 1))
        _ = timeline.apply(.messageCreated(message("m003"), seq: 3))
        _ = timeline.apply(.messageCreated(message("m004"), seq: 4))
        #expect(timeline.seq == 1)
        // A repeat or an older change leaves it be too.
        _ = timeline.apply(.messageDeleted(messageId: "m001", seq: 1))
        #expect(timeline.seq == 1)
        _ = timeline.apply(.messageDeleted(messageId: "m003", seq: 2))
        #expect(timeline.seq == 2)
    }

    @Test func resumedSetsTheBaseline() {
        var timeline = welcomed([], seq: 1)
        _ = timeline.apply(.messageCreated(message("m005"), seq: 5))
        #expect(timeline.seq == 1)
        _ = timeline.apply(.resumed(you: ada, messages: [message("m005")], deletedIds: [], present: [], seq: 5))
        #expect(timeline.seq == 5)
        _ = timeline.apply(.messageCreated(message("m006"), seq: 6))
        #expect(timeline.seq == 6)
    }

    @Test func noSeqBeforeTheWelcome() {
        var timeline = Timeline()
        _ = timeline.apply(.messageDeleted(messageId: "m001", seq: 1))
        #expect(timeline.seq == nil)
    }

    @Test func yourOwnMessageConfirmedPastTheWindowIsntAnArrival() {
        var timeline = welcomed(stored(1, 3), hasNewer: true, seq: 1)
        _ = timeline.send(body: "Mine", plainText: "Mine", clientMessageId: "c1")
        _ = timeline.apply(.messageCreated(mine("m009", "c1"), seq: 2))
        #expect(timeline.arrivals == 0)
        #expect(timeline.pending.isEmpty)
        _ = timeline.apply(.messageCreated(message("m010"), seq: 3))
        #expect(timeline.arrivals == 1)
    }

    @Test func resumedWithSomethingNewerPastTheWindowCountsOnce() {
        var timeline = welcomed(stored(9, 11), hasMore: true, hasNewer: true, around: "m010")
        _ = timeline.apply(.resumed(you: ada, messages: [message("m050"), message("m051"), message("m010")], deletedIds: [], present: [], seq: 4))
        #expect(timeline.arrivals == 1)
        // Only a change to what's shown: nothing new.
        _ = timeline.apply(.resumed(you: ada, messages: [message("m010", text: "Edited")], deletedIds: [], present: [], seq: 5))
        #expect(timeline.arrivals == 1)
    }

    @Test func resumedAtTheLatestIsntAnArrival() {
        var timeline = welcomed(stored(1, 3))
        _ = timeline.apply(.resumed(you: ada, messages: [message("m004")], deletedIds: [], present: [], seq: 4))
        #expect(timeline.arrivals == 0)
        #expect(timeline.messages.last?.id == "m004")
    }
}

/// How long a boost can be.
@Suite struct BoostLimitTests {
    @Test func aBoostFitsOnceTrimmed() {
        #expect(Limits.boostFits("👍"))
        #expect(Limits.boostFits("  nice  "))
        #expect(!Limits.boostFits(""))
        #expect(!Limits.boostFits(" \n\u{FEFF}"))
        #expect(Limits.boostFits(String(repeating: "a", count: 16)))
        #expect(!Limits.boostFits(String(repeating: "a", count: 17)))
        #expect(Limits.boostFits("   " + String(repeating: "a", count: 16) + "   "))
        // Counted in UTF-16 units: eight two-unit emoji fit, nine don't.
        #expect(Limits.boostFits(String(repeating: "🔥", count: 8)))
        #expect(!Limits.boostFits(String(repeating: "🔥", count: 9)))
    }

    @Test func clampingDropsWholeCharactersAndDoesntTrim() {
        #expect(Limits.clampedBoost(" hi ") == " hi ")
        #expect(Limits.clampedBoost(String(repeating: "a", count: 20)) == String(repeating: "a", count: 16))
        // Fifteen units, then a two-unit emoji that would make seventeen: the emoji goes whole.
        let text = String(repeating: "a", count: 15) + "🔥"
        #expect(Limits.clampedBoost(text) == String(repeating: "a", count: 15))
        // A family emoji is one character of eight units: two fit, and a third goes whole.
        let family = "👨‍👩‍👧"
        #expect(Limits.clampedBoost(family + family + family) == family + family)
        #expect(Limits.trimmedBoost("\u{FEFF} ok \n") == "ok")
    }
}
