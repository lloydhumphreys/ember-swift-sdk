import Foundation
import Testing
@testable import EmberCore

/// A timeline welcomed, as `ada`, with `messages` and the page's flags.
private func opened(_ messages: [Message], hasMore: Bool = false, hasNewer: Bool = false, around: MessageID? = nil, seq: Int = 1) -> Timeline {
    var timeline = Timeline()
    _ = timeline.apply(.welcome(you: ada, present: [ada], seq: seq, page: TimelinePage(messages: messages, hasMore: hasMore, hasNewer: hasNewer, around: around)))
    return timeline
}

private func failed(_ request: String) -> ServerFrame {
    .error(message: "Too many requests", clientMessageId: nil, clientMessageIds: nil, failed: request)
}

/// A page that fails isn't asked for again until a retry or a page that works.
@Suite struct PageFailureTests {
    @Test func aFailedOlderPageWaitsForARetry() {
        var timeline = opened(stored(5, 6), hasMore: true)
        #expect(timeline.olderPage() == .historyBefore(messageId: "m005"))
        _ = timeline.apply(failed("history.before"))
        #expect(timeline.olderPageFailure == "Too many requests")
        #expect(timeline.olderPage() == nil)
        #expect(timeline.retryOlderPage() == .historyBefore(messageId: "m005"))
        #expect(timeline.olderPageFailure == nil)
        _ = timeline.apply(.history(before: "m005", messages: stored(3, 4), hasMore: true))
        #expect(timeline.olderPageFailure == nil)
        #expect(timeline.olderPage() == .historyBefore(messageId: "m003"))
    }

    @Test func aFailedNewerPageWaitsForARetry() {
        var timeline = opened(stored(5, 6), hasNewer: true, around: "m005")
        #expect(timeline.newerPage() == .historyAfter(messageId: "m006"))
        _ = timeline.apply(failed("history.after"))
        #expect(timeline.newerPageFailure == "Too many requests")
        #expect(timeline.newerPage() == nil)
        #expect(timeline.olderPageFailure == nil)
        #expect(timeline.retryNewerPage() == .historyAfter(messageId: "m006"))
        _ = timeline.apply(.historyAfter(after: "m006", messages: stored(7, 8), hasNewer: true))
        #expect(timeline.newerPageFailure == nil)
        #expect(timeline.newerPage() == .historyAfter(messageId: "m008"))
    }

    @Test func aJumpOrAReconnectClearsAFailure() {
        var timeline = opened(stored(5, 6), hasMore: true)
        _ = timeline.olderPage()
        _ = timeline.apply(failed("history.before"))
        _ = timeline.pageAround("m020")
        _ = timeline.apply(.historyAround(TimelinePage(messages: stored(19, 21), hasMore: true, hasNewer: true, around: "m020")))
        #expect(timeline.olderPageFailure == nil)
        #expect(timeline.olderPage() == .historyBefore(messageId: "m019"))
        _ = timeline.apply(failed("history.before"))
        _ = timeline.apply(.welcome(you: ada, present: [], seq: 2, page: TimelinePage(messages: stored(30, 31), hasMore: true)))
        #expect(timeline.olderPageFailure == nil)
    }

    @Test func anOlderPageThatAddsNothingIsntAskedForAgain() {
        var timeline = opened(stored(5, 6), hasMore: true)
        _ = timeline.olderPage()
        _ = timeline.apply(.history(before: "m005", messages: [], hasMore: true))
        #expect(timeline.olderPageFailure != nil)
        #expect(timeline.olderPage() == nil)
        // Only what's already shown moves no bound either.
        var again = opened(stored(5, 6), hasMore: true)
        _ = again.olderPage()
        _ = again.apply(.history(before: "m005", messages: [message("m005")], hasMore: true))
        #expect(again.olderPage() == nil)
    }

    @Test func aNewerPageThatAddsNothingIsntAskedForAgain() {
        var timeline = opened(stored(5, 6), hasNewer: true, around: "m005")
        _ = timeline.newerPage()
        _ = timeline.apply(.historyAfter(after: "m006", messages: [], hasNewer: true))
        #expect(timeline.newerPageFailure != nil)
        #expect(timeline.newerPage() == nil)
    }

    @Test func theLastEmptyPageIsntAFailure() {
        var timeline = opened(stored(5, 6), hasMore: true)
        _ = timeline.olderPage()
        _ = timeline.apply(.history(before: "m005", messages: [], hasMore: false))
        #expect(timeline.olderPageFailure == nil)
        #expect(!timeline.hasMore)
    }
}

/// Changes that arrive out of order, twice or with one missing.
@Suite struct SeqOrderTests {
    @Test func aMessageThatArrivesLateGoesInIdOrder() {
        var timeline = opened(stored(1, 2), seq: 10)
        _ = timeline.apply(.messageCreated(message("m004"), seq: 12))
        _ = timeline.apply(.messageCreated(message("m003"), seq: 11))
        _ = timeline.apply(.messageCreated(message("m005"), seq: 13))
        #expect(timeline.messages.map(\.id) == ["m001", "m002", "m003", "m004", "m005"])
        #expect(timeline.seq == 13)
        #expect(!timeline.needsCatchUp)
    }

    @Test func aChangeHeardTwiceChangesNothing() {
        var timeline = opened(stored(1, 2), seq: 10)
        _ = timeline.apply(.messageCreated(message("m003"), seq: 11))
        _ = timeline.apply(.messageDeleted(messageId: "m003", seq: 12))
        _ = timeline.apply(.messageCreated(message("m003"), seq: 11))
        #expect(timeline.messages.map(\.id) == ["m001", "m002"])
        _ = timeline.apply(.messageCreated(message("m005"), seq: 14))
        _ = timeline.apply(.messageCreated(message("m005", text: "Again"), seq: 14))
        #expect(timeline.messages.filter { $0.id == "m005" }.count == 1)
        #expect(timeline.message("m005")?.plainText == "Message m005")
    }

    @Test func aChangeStillMissingAfterSeveralLaterOnesAsksForACatchUp() {
        var timeline = opened(stored(1, 2), seq: 10)
        _ = timeline.apply(.messageCreated(message("m004"), seq: 12))
        _ = timeline.apply(.messageCreated(message("m005"), seq: 13))
        #expect(!timeline.needsCatchUp)
        _ = timeline.apply(.messageCreated(message("m006"), seq: 14))
        #expect(timeline.needsCatchUp)
        #expect(timeline.seq == 10)
        _ = timeline.apply(.resumed(you: ada, messages: [message("m003")], deletedIds: [], present: [], seq: 14))
        #expect(!timeline.needsCatchUp)
        #expect(timeline.seq == 14)
        #expect(timeline.messages.map(\.id) == ["m001", "m002", "m003", "m004", "m005", "m006"])
    }
}

/// A reconnect the room answers with a welcome, after too much has happened to resume.
@Suite struct WelcomeAgainTests {
    @Test func aWelcomeThatOverlapsTheWindowKeepsWhatCameBefore() {
        var timeline = opened(stored(1, 20), hasMore: true)
        _ = timeline.apply(.welcome(you: ada, present: [], seq: 200, page: TimelinePage(messages: stored(15, 40), hasMore: true)))
        #expect(timeline.messages.first?.id == "m001")
        #expect(timeline.messages.last?.id == "m040")
        #expect(timeline.messages.count == 40)
        #expect(!timeline.hasNewer)
    }

    @Test func aReaderScrolledUpKeepsTheirWindow() {
        var timeline = opened(stored(1, 20), hasMore: true)
        timeline.setAwayFromLatest(true)
        _ = timeline.apply(.welcome(you: ada, present: [], seq: 200, page: TimelinePage(messages: stored(100, 140), hasMore: true)))
        #expect(timeline.messages.map(\.id) == stored(1, 20).map(\.id))
        #expect(timeline.hasNewer)
        #expect(timeline.arrivals == 1)
        #expect(timeline.seq == 200)
        #expect(timeline.newerPage() == .historyAfter(messageId: "m020"))
    }

    @Test func aReaderAtTheLatestSeesTheNewest() {
        var timeline = opened(stored(1, 20), hasMore: true)
        _ = timeline.apply(.welcome(you: ada, present: [], seq: 200, page: TimelinePage(messages: stored(100, 140), hasMore: true)))
        #expect(timeline.messages.first?.id == "m100")
        #expect(timeline.messages.last?.id == "m140")
        #expect(!timeline.hasNewer)
    }

    @Test func aFullWindowReadBackIsntCutForSomethingNewer() {
        let full = Limits.timelineMessages + Limits.timelineLeeway
        var timeline = opened(stored(1, full), hasMore: true)
        timeline.setAwayFromLatest(true)
        _ = timeline.apply(.messageCreated(message(id(full + 1)), seq: 2))
        #expect(timeline.messages.count == full)
        #expect(timeline.messages.first?.id == "m001")
        #expect(timeline.hasNewer)
        #expect(timeline.arrivals == 1)
        #expect(timeline.newerPage() == .historyAfter(messageId: id(full)))
    }

    @Test func aFullWindowAtTheLatestStillLetsTheOldestGo() {
        let full = Limits.timelineMessages + Limits.timelineLeeway
        var timeline = opened(stored(1, full), hasMore: true)
        _ = timeline.apply(.messageCreated(message(id(full + 1)), seq: 2))
        #expect(timeline.messages.last?.id == id(full + 1))
        #expect(timeline.messages.count == Limits.timelineMessages)
        #expect(!timeline.hasNewer)
    }

    @Test func aWelcomeAroundAMessageStillReplacesTheWindow() {
        var timeline = opened(stored(1, 20), hasMore: true)
        timeline.setAwayFromLatest(true)
        _ = timeline.apply(.welcome(you: ada, present: [], seq: 200, page: TimelinePage(messages: stored(9, 11), hasMore: true, hasNewer: true, around: "m010")))
        #expect(timeline.messages.map(\.id) == ["m009", "m010", "m011"])
    }
}

/// Paging older after a reconnect in a timeline opened on the page around a message.
@Suite struct PagingAfterAReconnectTests {
    /// Opened around m120 (m080 to m160, more either side), landed, and one older page in
    /// (m040 to m079), with `inFlight` the next one asked for when the socket dropped.
    func jumpedAndPaged(inFlight: Bool = false) -> Timeline {
        var timeline = opened(stored(80, 160), hasMore: true, hasNewer: true, around: "m120", seq: 10)
        timeline.clearAnchor()
        #expect(timeline.olderPage() == .historyBefore(messageId: "m080"))
        _ = timeline.apply(.history(before: "m080", messages: stored(40, 79), hasMore: true))
        if inFlight { #expect(timeline.olderPage() == .historyBefore(messageId: "m040")) }
        timeline.disconnected()
        return timeline
    }

    /// The next older page is asked for, from m040, and lands.
    func pagesOn(_ timeline: inout Timeline) {
        let frame = timeline.olderPage() ?? timeline.retryOlderPage()
        #expect(frame == .historyBefore(messageId: "m040"))
        _ = timeline.apply(.history(before: "m040", messages: stored(1, 39), hasMore: false))
        #expect(timeline.messages.first?.id == "m001")
        #expect(timeline.anchor == nil)
    }

    @Test(arguments: [false, true]) func afterTheRoomCatchesUp(inFlight: Bool) {
        var timeline = jumpedAndPaged(inFlight: inFlight)
        _ = timeline.apply(.resumed(you: ada, messages: [], deletedIds: [], present: [ada], seq: 12))
        #expect(timeline.hasMore)
        pagesOn(&timeline)
    }

    @Test(arguments: [false, true]) func afterANewestPageThatOverlaps(inFlight: Bool) {
        var timeline = jumpedAndPaged(inFlight: inFlight)
        _ = timeline.apply(.welcome(you: ada, present: [ada], seq: 400, page: TimelinePage(messages: stored(141, 180), hasMore: true)))
        #expect(timeline.messages.first?.id == "m040")
        pagesOn(&timeline)
    }

    @Test(arguments: [false, true]) func afterANewestPageThatDoesntOverlapWhileAway(inFlight: Bool) {
        var timeline = jumpedAndPaged(inFlight: inFlight)
        timeline.setAwayFromLatest(true)
        _ = timeline.apply(.welcome(you: ada, present: [ada], seq: 400, page: TimelinePage(messages: stored(200, 239), hasMore: true)))
        #expect(timeline.messages.first?.id == "m040")
        pagesOn(&timeline)
    }
}
