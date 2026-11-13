import Foundation
import Testing
@testable import EmberCore

// Ports of apps/web/src/lib/thread-state.test.ts, and what else a client owes a thread.

private let parent = message("m001", by: ada, text: "The plan")

/// A reply in m001's thread, `grace`'s unless it says.
private func reply(_ id: MessageID, by creator: User = grace, clientMessageId: ClientMessageID? = nil, text: String? = nil, alsoSent: Bool = false) -> Message {
    message(id, by: creator, clientMessageId: clientMessageId, text: text, parentId: "m001", alsoSent: alsoSent)
}

private func thread(at replyId: MessageID? = nil) -> ThreadTimeline {
    ThreadTimeline(parentId: "m001", me: ada, at: replyId)
}

/// The room answering `thread.open` for m001 with `replies`, its newest unless `hasMore`.
@discardableResult
private func open(_ thread: inout ThreadTimeline, _ replies: [Message], hasMore: Bool = false, parent of: Message? = parent) -> [ClientFrame] {
    thread.apply(.threadOpened(parentId: "m001", parent: of, messages: replies, hasMore: hasMore))
}

@discardableResult
private func page(_ thread: inout ThreadTimeline, before: MessageID, _ replies: [Message], hasMore: Bool) -> [ClientFrame] {
    thread.apply(.threadHistory(parentId: "m001", before: before, messages: replies, hasMore: hasMore))
}

private func ids(_ thread: ThreadTimeline) -> [MessageID] { thread.replies.map(\.id) }

@Suite struct ThreadOpeningTests {
    @Test func firstOpenShowsTheParentAndNewestReplies() {
        var state = thread()
        #expect(state.parent == .unknown && !state.isLoaded && !state.canReply)
        let opening = state.opening()
        #expect(opening == .openThread(parentId: "m001"))
        let answered = open(&state, [reply("r1"), reply("r2")], hasMore: true)
        #expect(answered.isEmpty)
        #expect(state.parent == .message(parent))
        #expect(state.parentMessage == parent && state.canReply)
        #expect(ids(state) == ["r1", "r2"])
        #expect(state.hasMore && state.isLoaded && !state.isLoadingOlder)
        #expect(state.focus == nil)
    }

    @Test func noSuchParentIsGone() {
        var state = thread()
        open(&state, [], parent: nil)
        #expect(state.parent == .gone && !state.canReply && state.isLoaded)

        // A reply can't have a thread of its own.
        var ofReply = thread()
        open(&ofReply, [], parent: reply("m001"))
        #expect(ofReply.parent == .gone)
    }

    @Test func anotherThreadsFramesAndTheRoomsOwnChangeNothing() {
        var state = thread()
        open(&state, [reply("r1")])
        let before = state
        let other = message("x1", clientMessageId: "cx", parentId: "m009")
        var answers: [ClientFrame] = []
        answers += state.apply(.threadOpened(parentId: "m009", parent: message("m009"), messages: [other], hasMore: false))
        answers += state.apply(.threadHistory(parentId: "m009", before: "x2", messages: [other], hasMore: false))
        answers += state.apply(.messageCreated(other, seq: 1))
        answers += state.apply(.messageCreated(message("m002"), seq: 2))
        answers += state.apply(.presenceJoined(grace))
        answers += state.apply(.typing(user: grace, typing: true, threadId: nil))
        answers += state.apply(.typing(user: grace, typing: true, threadId: "m009"))
        answers += state.apply(.history(before: "m001", messages: [message("m000")], hasMore: false))
        answers += state.apply(.error(message: "Not sent", clientMessageId: "c-room", clientMessageIds: nil, failed: "message.create"))
        answers += state.apply(.error(message: "Couldn't load older messages", clientMessageId: nil, clientMessageIds: nil, failed: "history.before"))
        #expect(answers.isEmpty)
        #expect(state == before)
    }

    @Test func goesToThePermalinkedReplyWhenItsLoaded() {
        var state = thread(at: "r1")
        let answered = open(&state, [reply("r1"), reply("r2")])
        #expect(answered.isEmpty)
        #expect(state.focus == "r1")
        state.clearFocus()
        #expect(state.focus == nil)
    }

    @Test func pagesBackToAnOlderPermalinkedReply() {
        var state = thread(at: "r1")
        let first = open(&state, [reply("r3"), reply("r4")], hasMore: true)
        #expect(first == [.threadBefore(parentId: "m001", before: "r3")])
        #expect(state.isLoadingOlder && state.focus == nil)
        let second = page(&state, before: "r3", [reply("r1"), reply("r2")], hasMore: true)
        #expect(second.isEmpty)
        #expect(ids(state) == ["r1", "r2", "r3", "r4"])
        #expect(state.focus == "r1" && !state.isLoadingOlder)
    }

    @Test func givesUpOnAPermalinkedReplyThatIsntThere() {
        // One that would be among those loaded.
        var among = thread(at: "r3a")
        let none = open(&among, [reply("r3"), reply("r4")], hasMore: true)
        #expect(none.isEmpty && among.focus == nil)

        // One older than every reply.
        var tooOld = thread(at: "r0")
        open(&tooOld, [reply("r3")], hasMore: true)
        let last = page(&tooOld, before: "r3", [reply("r1")], hasMore: false)
        #expect(last.isEmpty && tooOld.focus == nil)
        #expect(ids(tooOld) == ["r1", "r3"])
        // It has stopped going there: a later reopen doesn't page back again.
        let reopened = open(&tooOld, [reply("r1"), reply("r3")])
        #expect(reopened.isEmpty)
    }

    @Test func historyForOtherBoundsOnlyStopsLoading() {
        var state = thread()
        open(&state, [reply("r3"), reply("r4")], hasMore: true)
        let older = state.olderPage()
        #expect(older == .threadBefore(parentId: "m001", before: "r3"))
        #expect(state.olderPage() == nil)
        page(&state, before: "r4", [reply("r1")], hasMore: false)
        #expect(ids(state) == ["r3", "r4"] && state.hasMore && !state.isLoadingOlder)
    }

    @Test func noOlderPageWithoutOne() {
        var unloaded = thread()
        #expect(unloaded.olderPage() == nil)
        var all = thread()
        open(&all, [reply("r1")])
        #expect(all.olderPage() == nil)
        var empty = thread()
        open(&empty, [], hasMore: true)
        #expect(empty.olderPage() == nil)
    }

    @Test func pagesBackThroughOlderRepliesAndKeepsThemAll() {
        let replies = (0 ..< 400).map { reply(MessageID(String(format: "r%03d", $0))) }
        var state = thread()
        open(&state, Array(replies.suffix(40)), hasMore: true)
        for end in stride(from: 360, to: 0, by: -40) {
            let frame = state.olderPage()
            #expect(frame == .threadBefore(parentId: "m001", before: replies[end].id))
            page(&state, before: replies[end].id, Array(replies[(end - 40) ..< end]), hasMore: end > 40)
        }
        #expect(ids(state) == replies.map(\.id))
        #expect(!state.hasMore)
        _ = state.apply(.messageCreated(reply("r400"), seq: 1))
        #expect(state.replies.count == 401 && state.replies.last?.id == "r400")
    }
}

@Suite struct ThreadReopeningTests {
    @Test func catchesUpWhileThePageHoldsEveryReplyShown() {
        var state = thread()
        open(&state, [reply("r1"), reply("r2"), reply("r3")])
        state.disconnected()
        open(&state, [reply("r1"), reply("r3", text: "Edited"), reply("r4")])
        #expect(ids(state) == ["r1", "r3", "r4"])
        #expect(state.replies[1].plainText == "Edited")
        #expect(!state.hasMore)
    }

    @Test func startsAfreshOnceTheRepliesShownGoBackFurther() {
        var state = thread()
        open(&state, [reply("r1"), reply("r2")])
        _ = state.reply(body: "<p>Three</p>", plainText: "Three", delivery: .threadOnly, clientMessageId: "c3", now: noon())
        state.disconnected()
        let checks = open(&state, [reply("r5"), reply("r6")], hasMore: true)
        #expect(checks == [.checkMessages(clientMessageIds: ["c3"])])
        #expect(ids(state) == ["r5", "r6"] && state.pending.map(\.id) == ["c3"])
        #expect(state.hasMore)
        #expect(state.olderPage() == .threadBefore(parentId: "m001", before: "r5"))

        // Even when the page holds some of them.
        page(&state, before: "r5", [reply("r3"), reply("r4")], hasMore: true)
        open(&state, [reply("r4"), reply("r5", text: "Edited"), reply("r7")], hasMore: true)
        #expect(ids(state) == ["r4", "r5", "r7"])
        #expect(state.replies[1].plainText == "Edited")
    }

    @Test func aThreadThatHadNoRepliesPagesBackFromTheNewPage() {
        var state = thread()
        open(&state, [])
        open(&state, [reply("r5"), reply("r6")], hasMore: true)
        #expect(state.hasMore)
        #expect(state.olderPage() == .threadBefore(parentId: "m001", before: "r5"))
    }

    @Test func resumedDropsDeletionsAndTakesChanges() {
        var state = thread()
        open(&state, [reply("r1"), reply("r2"), reply("r3")])
        let edited = message("m001", by: ada, text: "The new plan")
        _ = state.apply(.resumed(you: ada, messages: [edited, reply("r2", text: "Changed", alsoSent: true), reply("r4", alsoSent: true), message("m009")],
                                 deletedIds: ["r3"], present: [], seq: 9))
        #expect(state.parent == .message(edited))
        #expect(ids(state) == ["r1", "r2", "r4"])
        // Replies the room resent quote the parent as it has it; the one it didn't is retold.
        #expect(state.replies[0].parentText == "The new plan")
        #expect(state.replies[1].parentText == reply("r2").parentText)

        _ = state.apply(.resumed(you: ada, messages: [], deletedIds: ["m001"], present: [], seq: 10))
        #expect(state.parent == .gone)
        #expect(ids(state) == ["r1", "r2", "r4"])
    }

    @Test func welcomeAndResumedSayWhoIAmAndAnswerNothing() {
        var state = ThreadTimeline(parentId: "m001")
        let welcomed = state.apply(.welcome(you: grace, present: [], seq: 1, page: TimelinePage(messages: [])))
        #expect(welcomed.isEmpty && state.me == grace)
        let resumed = state.apply(.resumed(you: ada, messages: [], deletedIds: [], present: [], seq: 2))
        #expect(resumed.isEmpty && state.me == ada)
    }
}

@Suite struct ThreadChangeTests {
    @Test func addsChangesAndTakesAwayReplies() {
        var state = thread()
        open(&state, [reply("r1")])
        _ = state.apply(.messageCreated(reply("r3"), seq: 1))
        _ = state.apply(.messageCreated(reply("r2"), seq: 2))
        _ = state.apply(.messageCreated(reply("r2"), seq: 3))
        #expect(ids(state) == ["r1", "r2", "r3"])
        _ = state.apply(.messageUpdated(reply("r1", text: "Edited"), seq: 4))
        #expect(state.replies[0].plainText == "Edited")
        _ = state.apply(.messageUpdated(reply("r9"), seq: 5))
        _ = state.apply(.messageDeleted(messageId: "r2", seq: 6))
        #expect(ids(state) == ["r1", "r3"])
    }

    @Test func keepsTheParentsChangesBoostsAndGoing() {
        var state = thread()
        open(&state, [reply("r1")])
        var summarised = parent
        summarised.thread = ThreadSummary(count: 1, latestAt: noon(), people: [grace])
        _ = state.apply(.messageUpdated(summarised, seq: 1))
        #expect(state.parentMessage?.thread?.count == 1)

        let boost = Boost(id: "b1", messageId: "m001", booster: ada, content: "👍", createdAt: noon())
        _ = state.apply(.boostCreated(boost, seq: 2))
        _ = state.apply(.boostCreated(boost, seq: 3))
        #expect(state.parentMessage?.boosts.map(\.id) == ["b1"])
        _ = state.apply(.boostCreated(Boost(id: "b2", messageId: "r1", booster: ada, content: "👍", createdAt: noon()), seq: 4))
        #expect(state.replies[0].boosts.map(\.id) == ["b2"])
        _ = state.apply(.boostDeleted(boostId: "b1", messageId: "m001", seq: 5))
        #expect(state.parentMessage?.boosts == [])
        _ = state.apply(.boostDeleted(boostId: "b2", messageId: "r1", seq: 6))
        #expect(state.replies[0].boosts == [])

        _ = state.apply(.messageDeleted(messageId: "m001", seq: 7))
        #expect(state.parent == .gone && !state.canReply)
        #expect(ids(state) == ["r1"])
    }

    @Test func aTombstoneParentCanStillBeRepliedTo() {
        var state = thread()
        open(&state, [reply("r1")])
        var tombstone = message("m001", by: ada, text: "")
        tombstone.deleted = true
        _ = state.apply(.messageUpdated(tombstone, seq: 1))
        #expect(state.parentMessage?.isDeleted == true)
        #expect(state.canReply)
        #expect(state.replies[0].parentText == "")

        var openedOnOne = thread()
        open(&openedOnOne, [], parent: tombstone)
        #expect(openedOnOne.canReply)
    }

    @Test func anEditRetellsTheParentInTheReplies() {
        var state = thread()
        open(&state, [reply("r1"), reply("r2")])
        let long = String(repeating: "é", count: 140) + String(repeating: "😀", count: 20)
        _ = state.apply(.messageUpdated(message("m001", by: ada, text: long), seq: 1))
        let expected = String(repeating: "é", count: 140) + String(repeating: "😀", count: 10)
        #expect(state.replies.allSatisfy { $0.parentText == expected })
    }
}

@Suite struct ThreadReplyTests {
    @Test func aReplyIsPendingUntilTheRoomHasIt() {
        var state = thread()
        open(&state, [reply("r1")])
        let frame = state.reply(body: "<p>Hi</p>", plainText: "Hi", delivery: .threadAndRoom, clientMessageId: "c2", now: noon())
        #expect(frame == .createMessage(clientMessageId: "c2", body: "<p>Hi</p>", parentId: "m001", alsoSend: true))
        #expect(json(frame.text) == json(#"{"type":"message.create","clientMessageId":"c2","body":"<p>Hi</p>","parentId":"m001","alsoSend":true}"#))
        #expect(state.pending == [PendingMessage(clientMessageId: "c2", body: "<p>Hi</p>", plainText: "Hi", createdAt: noon(), parentId: "m001", delivery: .threadAndRoom)])
        let threadOnly = state.reply(body: "B", plainText: "B", delivery: .threadOnly, clientMessageId: "c3", now: noon())
        #expect(threadOnly == .createMessage(clientMessageId: "c3", body: "B", parentId: "m001", alsoSend: false))

        // Someone else reusing my id doesn't confirm it.
        _ = state.apply(.messageCreated(reply("r2", by: grace, clientMessageId: "c2"), seq: 1))
        #expect(state.pending.map(\.id) == ["c2", "c3"])
        _ = state.apply(.messageCreated(reply("r3", by: ada, clientMessageId: "c2", alsoSent: true), seq: 2))
        #expect(state.pending.map(\.id) == ["c3"])
        #expect(ids(state) == ["r1", "r2", "r3"])
    }

    @Test func aReconnectChecksAndResendsWithTheThread() {
        var state = thread()
        open(&state, [])
        _ = state.reply(body: "Two", plainText: "Two", delivery: .threadAndRoom, clientMessageId: "c2", now: noon())
        _ = state.reply(body: "Three", plainText: "Three", delivery: .threadOnly, clientMessageId: "c3", now: noon())
        _ = state.apply(.error(message: "Too long", clientMessageId: "c3", clientMessageIds: nil, failed: "message.create"))
        state.attach(PendingUpload(name: "a.pdf", contentType: "application/pdf", byteSize: 10), delivery: .threadOnly, clientMessageId: "c4", now: noon())
        state.attach(PendingUpload(name: "b.pdf", contentType: "application/pdf", byteSize: 10), delivery: .threadAndRoom, clientMessageId: "c5", now: noon())
        _ = state.fail("c5", reason: Uploads.failed)
        state.disconnected()

        let checks = open(&state, [])
        #expect(checks == [.checkMessages(clientMessageIds: ["c2", "c3", "c5"])])
        let resent = state.apply(.messageChecked(stored: [], missing: ["c2", "c3", "c5", "c9"]))
        #expect(resent == [.createMessage(clientMessageId: "c2", body: "Two", parentId: "m001", alsoSend: true)])
        #expect(state.pending.map(\.id) == ["c2", "c3", "c4", "c5"])
        _ = state.apply(.messageChecked(stored: ["c2", "c5"], missing: []))
        #expect(state.pending.map(\.id) == ["c3", "c4"])
    }

    @Test func checksGoInChunks() {
        var state = thread()
        for n in 0 ..< 51 { _ = state.reply(body: "\(n)", plainText: "\(n)", delivery: .threadOnly, clientMessageId: "c\(n)", now: noon()) }
        let checks = open(&state, [])
        #expect(checks == [.checkMessages(clientMessageIds: (0 ..< 50).map { "c\($0)" }), .checkMessages(clientMessageIds: ["c50"])])
    }

    @Test func aPageThatHoldsAPendingReplyConfirmsIt() {
        var state = thread()
        _ = state.reply(body: "Hi", plainText: "Hi", delivery: .threadOnly, clientMessageId: "c2", now: noon())
        let checks = open(&state, [reply("r1", by: ada, clientMessageId: "c2")])
        #expect(checks.isEmpty && state.pending.isEmpty)
    }

    @Test func errorsByIdFailTheThreadsReplies() {
        var state = thread()
        open(&state, [reply("r1")])
        _ = state.reply(body: "A", plainText: "A", delivery: .threadOnly, clientMessageId: "c2", now: noon())
        _ = state.reply(body: "B", plainText: "B", delivery: .threadOnly, clientMessageId: "c3", now: noon())
        _ = state.apply(.error(message: "That message no longer exists", clientMessageId: "c2", clientMessageIds: nil, failed: "message.create"))
        _ = state.apply(.error(message: "Slow down", clientMessageId: nil, clientMessageIds: ["c3", "c9"], failed: "message.create"))
        #expect(state.pending.map(\.failure) == ["That message no longer exists", "Slow down"])
        #expect(state.notice == nil)
        #expect(state.retry("c2") == .createMessage(clientMessageId: "c2", body: "A", parentId: "m001", alsoSend: false))
        #expect(state.pending[0].failure == nil)
        #expect(state.retry("c9") == nil)
        state.discard("c3")
        #expect(state.pending.map(\.id) == ["c2"])
    }

    @Test func aFailedOpenOrPageSaysWhy() {
        var state = thread()
        _ = state.opening()
        _ = state.apply(.error(message: "Couldn't open the thread", clientMessageId: nil, clientMessageIds: nil, failed: "thread.open"))
        #expect(state.notice == "Couldn't open the thread")
        state.notice = nil
        // Not waiting on one, it isn't this thread's.
        _ = state.apply(.error(message: "Again", clientMessageId: nil, clientMessageIds: nil, failed: "thread.open"))
        #expect(state.notice == nil)

        var paging = thread(at: "r1")
        _ = paging.opening()
        open(&paging, [reply("r3")], hasMore: true)
        #expect(paging.isLoadingOlder)
        _ = paging.apply(.error(message: "Couldn't load the thread", clientMessageId: nil, clientMessageIds: nil, failed: "thread.before"))
        #expect(paging.notice == "Couldn't load the thread" && !paging.isLoadingOlder)
        // It has stopped going to the permalinked reply, but can page again.
        #expect(paging.olderPage() == .threadBefore(parentId: "m001", before: "r3"))
        let answered = page(&paging, before: "r3", [reply("r2")], hasMore: true)
        #expect(answered.isEmpty && paging.focus == nil)

        var idle = thread()
        open(&idle, [reply("r3")], hasMore: true)
        _ = idle.apply(.error(message: "Not ours", clientMessageId: nil, clientMessageIds: nil, failed: "thread.before"))
        #expect(idle.notice == nil)
    }

    @Test func aDisconnectClearsLoadingAndTyping() {
        var state = thread()
        open(&state, [reply("r3")], hasMore: true)
        _ = state.olderPage()
        _ = state.apply(.typing(user: User(id: "ember", name: "Ember"), typing: true, threadId: "m001"), now: noon())
        _ = state.reply(body: "Hi", plainText: "Hi", delivery: .threadOnly, clientMessageId: "c1", now: noon())
        state.disconnected()
        #expect(!state.isLoadingOlder && state.typing.isEmpty)
        #expect(ids(state) == ["r3"] && state.pending.map(\.id) == ["c1"])
    }
}

@Suite struct ThreadTypingTests {
    let ember = User(id: "ember", name: "Ember")

    @Test func showsBotsTypingInThisThreadUntilTheyStopReplyOrGoQuiet() {
        var state = thread()
        open(&state, [reply("r1")])
        _ = state.apply(.typing(user: ember, typing: true, threadId: "m001"), now: noon())
        #expect(state.typing == [ember])
        _ = state.apply(.typing(user: ada, typing: true, threadId: "m001"), now: noon())
        #expect(state.typing == [ember])

        var replied = state
        _ = replied.apply(.messageCreated(reply("r2", by: ember), seq: 1))
        #expect(replied.typing.isEmpty)

        var stopped = state
        _ = stopped.apply(.typing(user: ember, typing: false, threadId: "m001"), now: noon())
        #expect(stopped.typing.isEmpty)

        var quiet = state
        quiet.expireTyping(now: noon().addingTimeInterval(Limits.typingTTL))
        #expect(quiet.typing == [ember])
        quiet.expireTyping(now: noon().addingTimeInterval(Limits.typingTTL + 1))
        #expect(quiet.typing.isEmpty)

        // Typing again keeps it going.
        var again = state
        _ = again.apply(.typing(user: ember, typing: true, threadId: "m001"), now: noon(1))
        again.expireTyping(now: noon(1).addingTimeInterval(Limits.typingTTL))
        #expect(again.typing == [ember])
        #expect(Limits.typingTTL == 5)
    }
}

@Suite struct ThreadUploadTests {
    @Test func aFileGoesUpAsAPendingReply() {
        var state = thread()
        open(&state, [reply("r1")])
        state.attach(PendingUpload(name: "plan.pdf", contentType: "application/pdf", byteSize: 100), delivery: .threadAndRoom, clientMessageId: "c2", now: noon())
        #expect(state.pending == [PendingMessage(
            clientMessageId: "c2", body: "", plainText: "plan.pdf", createdAt: noon(), parentId: "m001", delivery: .threadAndRoom,
            upload: PendingUpload(name: "plan.pdf", contentType: "application/pdf", byteSize: 100)
        )])
        state.uploadProgress("c2", sentBytes: 40)
        state.uploadProgress("c9", sentBytes: 40)
        #expect(state.pending[0].upload?.sentBytes == 40)

        let check = state.fail("c2", reason: Uploads.failed)
        #expect(check == .checkMessages(clientMessageIds: ["c2"]))
        #expect(state.retry("c2") == nil)
        #expect(state.pending[0].failure == nil && state.pending[0].upload?.sentBytes == 0)

        let file = reply("r2", by: ada, clientMessageId: "c2", text: "plan.pdf", alsoSent: true)
        state.posted(file)
        #expect(state.pending.isEmpty && ids(state) == ["r1", "r2"])
        _ = state.apply(.messageCreated(file, seq: 1))
        #expect(ids(state) == ["r1", "r2"])
    }

    @Test func aBroadcastFirstThenTheAnswerShowsOnce() {
        var state = thread()
        open(&state, [])
        state.attach(PendingUpload(name: "a.png", contentType: "image/png", byteSize: 1), delivery: .threadOnly, clientMessageId: "c1", now: noon())
        let file = reply("r1", by: ada, clientMessageId: "c1")
        _ = state.apply(.messageCreated(file, seq: 1))
        state.posted(file)
        #expect(ids(state) == ["r1"] && state.pending.isEmpty)
    }

    @Test func aFileIsntSentAgainWhenTheRoomNeverGotIt() {
        var state = thread()
        open(&state, [])
        state.attach(PendingUpload(name: "a.png", contentType: "image/png", byteSize: 1), delivery: .threadOnly, clientMessageId: "c1", now: noon())
        _ = state.fail("c1", reason: "Upload failed")
        let resent = state.apply(.messageChecked(stored: [], missing: ["c1"]))
        #expect(resent.isEmpty && state.pending.first?.failure == "Upload failed")
    }
}

/// A second link into a thread that's open already.
@Suite struct ThreadGoToTests {
    @Test func aLoadedReplyIsFocusedAtOnce() {
        var state = thread()
        open(&state, [reply("r1"), reply("r2"), reply("r3")])
        _ = state.reply(body: "<p>Hi</p>", plainText: "Hi", delivery: .threadOnly, clientMessageId: "c1", now: Date())
        #expect(state.go(to: "r2").isEmpty)
        #expect(state.focus == "r2")
        #expect(ids(state) == ["r1", "r2", "r3"])
        #expect(state.pending.map(\.clientMessageId) == ["c1"])
        state.clearFocus()
        // The same reply asked for again is brought into view again.
        #expect(state.go(to: "r2").isEmpty)
        #expect(state.focus == "r2")
        // Even with the socket out of the room, a reply that's loaded is there to go to.
        state.clearFocus()
        #expect(state.go(to: "r1", isOpen: false).isEmpty && state.focus == "r1")
    }

    @Test func anOlderReplyIsPagedBackTo() {
        var state = thread()
        open(&state, [reply("r3"), reply("r4")], hasMore: true)
        _ = state.reply(body: "<p>Hi</p>", plainText: "Hi", delivery: .threadOnly, clientMessageId: "c1", now: Date())
        #expect(state.go(to: "r1") == [.threadBefore(parentId: "m001", before: "r3")])
        #expect(state.focus == nil && state.isLoadingOlder)
        page(&state, before: "r3", [reply("r1"), reply("r2")], hasMore: false)
        #expect(state.focus == "r1")
        #expect(ids(state) == ["r1", "r2", "r3", "r4"])
        #expect(state.pending.map(\.clientMessageId) == ["c1"])
    }

    @Test func offlineItWaitsForTheThreadToOpenAgain() {
        var state = thread()
        open(&state, [reply("r3"), reply("r4")], hasMore: true)
        state.disconnected()
        #expect(state.go(to: "r1", isOpen: false).isEmpty)
        #expect(!state.isLoadingOlder)
        #expect(open(&state, [reply("r3"), reply("r4")], hasMore: true) == [.threadBefore(parentId: "m001", before: "r3")])
    }

    @Test func beforeTheThreadHasOpenedItsWhereTheOpenGoes() {
        var state = thread()
        #expect(state.go(to: "r1").isEmpty)
        open(&state, [reply("r1"), reply("r2")])
        #expect(state.focus == "r1")
    }

    @Test func aFocusNotYetShownIsReplaced() {
        var state = thread(at: "r1")
        open(&state, [reply("r1"), reply("r2")])
        #expect(state.focus == "r1")
        _ = state.go(to: "r2")
        #expect(state.focus == "r2")
    }
}
