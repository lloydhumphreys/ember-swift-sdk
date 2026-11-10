import Foundation
import Testing
@testable import EmberCore

private func welcomed(_ messages: [Message] = [], hasNewer: Bool = false) -> Timeline {
    var timeline = Timeline()
    _ = timeline.apply(.welcome(you: ada, present: [], seq: 1, page: TimelinePage(messages: messages, hasNewer: hasNewer)))
    return timeline
}

private let pdf = PendingUpload(name: "Q3 report.pdf", contentType: "application/pdf", byteSize: 1000)

private func file(_ id: String, _ clientMessageId: String) -> Message {
    message(id, by: ada, clientMessageId: clientMessageId, text: "Q3 report.pdf")
}

@Suite struct PendingUploadTests {
    @Test func fraction() {
        #expect(PendingUpload(name: "a", contentType: "", byteSize: 0).fraction == 1)
        #expect(PendingUpload(name: "a", contentType: "", byteSize: 0).isProcessing)
        #expect(PendingUpload(name: "a", contentType: "", byteSize: 200, sentBytes: 50).fraction == 0.25)
        #expect(!PendingUpload(name: "a", contentType: "", byteSize: 200, sentBytes: 199).isProcessing)
        #expect(PendingUpload(name: "a", contentType: "", byteSize: 200, sentBytes: 200).isProcessing)
    }

    @Test func alsoSendOnlyWithAThread() {
        #expect(!PendingMessage(clientMessageId: "c", body: "", plainText: "", createdAt: noon(), alsoSend: true).alsoSend)
        #expect(PendingMessage(clientMessageId: "c", body: "", plainText: "", createdAt: noon(), parentId: "m1", alsoSend: true).alsoSend)
        let old = PendingMessage(clientMessageId: "c", body: "b", plainText: "p", createdAt: noon(), failure: "No")
        #expect(old.parentId == nil && old.upload == nil && old.failure == "No")
    }
}

@Suite struct TimelineUploadTests {
    @Test func attachProgressFailAndRetry() {
        var timeline = welcomed()
        timeline.attach(pdf, clientMessageId: "c1", now: noon())
        #expect(timeline.pending == [PendingMessage(clientMessageId: "c1", body: "", plainText: "Q3 report.pdf", createdAt: noon(), upload: pdf)])
        timeline.uploadProgress("c1", sentBytes: 400)
        #expect(timeline.pending[0].upload?.fraction == 0.4)
        timeline.uploadProgress("c1", sentBytes: 5000)
        #expect(timeline.pending[0].upload?.sentBytes == 1000)
        timeline.uploadProgress("c9", sentBytes: 1)

        let check = timeline.fail("c1", reason: "Upload failed")
        #expect(check == .checkMessages(clientMessageIds: ["c1"]))
        #expect(timeline.pending[0].failure == "Upload failed")
        let retried = timeline.retry("c1")
        #expect(retried == nil)
        #expect(timeline.pending[0].failure == nil && timeline.pending[0].upload?.sentBytes == 0)
        #expect(timeline.fail("c9", reason: "No") == nil)
    }

    @Test func progressNeverGoesBackUntilTheFileIsRetried() {
        var timeline = welcomed()
        timeline.attach(pdf, clientMessageId: "c1", now: noon())
        timeline.uploadProgress("c1", sentBytes: 600)
        // A part sent again counts from its own start.
        timeline.uploadProgress("c1", sentBytes: 400)
        #expect(timeline.pending[0].upload?.sentBytes == 600)
        timeline.uploadProgress("c1", sentBytes: 5000)
        #expect(timeline.pending[0].upload?.sentBytes == 1000)
        _ = timeline.fail("c1", reason: "Upload failed")
        _ = timeline.retry("c1")
        #expect(timeline.pending[0].upload?.sentBytes == 0)
        timeline.uploadProgress("c1", sentBytes: 100)
        #expect(timeline.pending[0].upload?.sentBytes == 100)
    }

    @Test func aThreadsProgressNeverGoesBackUntilTheFileIsRetried() {
        var thread = ThreadTimeline(parentId: "m001", me: ada)
        thread.attach(pdf, alsoSend: false, clientMessageId: "c1", now: noon())
        thread.uploadProgress("c1", sentBytes: 600)
        thread.uploadProgress("c1", sentBytes: 400)
        #expect(thread.pending[0].upload?.sentBytes == 600)
        _ = thread.fail("c1", reason: "Upload failed")
        _ = thread.retry("c1")
        #expect(thread.pending[0].upload?.sentBytes == 0)
        thread.uploadProgress("c1", sentBytes: 100)
        #expect(thread.pending[0].upload?.sentBytes == 100)
    }

    @Test func failingAMessageThatIsntAFileChecksNothing() {
        var timeline = welcomed()
        _ = timeline.send(body: "Hi", plainText: "Hi", clientMessageId: "c1")
        #expect(timeline.fail("c1", reason: "Not connected") == nil)
        #expect(timeline.pending[0].failure == "Not connected")
    }

    @Test func postedThenCreatedShowsOnce() {
        var timeline = welcomed([message("m001")])
        timeline.attach(pdf, clientMessageId: "c1", now: noon())
        timeline.posted(file("m002", "c1"))
        #expect(timeline.pending.isEmpty)
        #expect(timeline.messages.map(\.id) == ["m001", "m002"])
        #expect(timeline.seq == 1)
        _ = timeline.apply(.messageCreated(file("m002", "c1"), seq: 2))
        #expect(timeline.messages.map(\.id) == ["m001", "m002"])
        #expect(timeline.seq == 2)
    }

    @Test func createdThenPostedShowsOnce() {
        var timeline = welcomed([message("m001")])
        timeline.attach(pdf, clientMessageId: "c1", now: noon())
        _ = timeline.apply(.messageCreated(file("m002", "c1"), seq: 2))
        let before = timeline
        timeline.posted(file("m002", "c1"))
        #expect(timeline == before)
    }

    @Test func postedPastTheWindowOnlyDropsThePending() {
        var timeline = welcomed([message("m001")], hasNewer: true)
        timeline.attach(pdf, clientMessageId: "c1", now: noon())
        timeline.posted(file("m005", "c1"))
        #expect(timeline.pending.isEmpty && timeline.messages.map(\.id) == ["m001"])
    }

    @Test func aThreadOnlyFilePostedStaysOutOfTheRoom() {
        var timeline = welcomed([message("m001")])
        timeline.attach(pdf, clientMessageId: "c1", now: noon())
        timeline.posted(message("m002", by: ada, clientMessageId: "c1", parentId: "m001", alsoSent: false))
        #expect(timeline.pending.isEmpty && timeline.messages.map(\.id) == ["m001"])
    }

    @Test func aReconnectAsksAboutFailedFilesButNotOnesGoingUp() {
        var timeline = welcomed()
        _ = timeline.send(body: "Hi", plainText: "Hi", clientMessageId: "c1")
        _ = timeline.send(body: "Long", plainText: "Long", clientMessageId: "c2")
        _ = timeline.apply(.error(message: "Too long", clientMessageId: "c2", clientMessageIds: nil, failed: "message.create"))
        timeline.attach(pdf, clientMessageId: "c3", now: noon())
        timeline.attach(pdf, clientMessageId: "c4", now: noon())
        _ = timeline.fail("c4", reason: "Upload failed")
        let checks = timeline.apply(.welcome(you: ada, present: [], seq: 2, page: TimelinePage(messages: [])))
        #expect(checks == [.checkMessages(clientMessageIds: ["c1", "c4"])])

        let resent = timeline.apply(.messageChecked(stored: [], missing: ["c1", "c3", "c4"]))
        #expect(resent == [.createMessage(clientMessageId: "c1", body: "Hi")])
        #expect(timeline.pending.map(\.id) == ["c1", "c2", "c3", "c4"])
        #expect(timeline.pending[3].failure == "Upload failed")
        _ = timeline.apply(.messageChecked(stored: ["c4"], missing: []))
        #expect(timeline.pending.map(\.id) == ["c1", "c2", "c3"])
    }
}

@Suite struct UploadShapeTests {
    @Test func newUploadLeavesOutWhatTheRoomWouldntKeep() throws {
        let encoder = EmberJSON.encoder()
        func text(_ upload: NewUpload) throws -> JSONValue? { json(String(decoding: try encoder.encode(upload), as: UTF8.self)) }
        #expect(try text(NewUpload(name: "a.png", type: "image/png", size: 3, clientMessageId: "c1"))
            == json(#"{"name":"a.png","type":"image/png","size":3,"clientMessageId":"c1"}"#))
        #expect(try text(NewUpload(name: "a.png", type: "", size: 0, clientMessageId: "c1", alsoSend: true))
            == json(#"{"name":"a.png","type":"","size":0,"clientMessageId":"c1"}"#))
        #expect(try text(NewUpload(name: "a.png", type: "image/png", size: 3, clientMessageId: "c1", parentId: "m1"))
            == json(#"{"name":"a.png","type":"image/png","size":3,"clientMessageId":"c1","parentId":"m1"}"#))
        #expect(try text(NewUpload(name: "a.png", type: "image/png", size: 3, clientMessageId: "c1", parentId: "m1", alsoSend: true))
            == json(#"{"name":"a.png","type":"image/png","size":3,"clientMessageId":"c1","parentId":"m1","alsoSend":true}"#))
        let decoded = try EmberJSON.decoder().decode(NewUpload.self, from: Data(#"{"name":"a","type":"","size":1,"clientMessageId":"c"}"#.utf8))
        #expect(decoded == NewUpload(name: "a", type: "", size: 1, clientMessageId: "c"))
    }

    @Test func ticketDecodes() throws {
        let ticket = try EmberJSON.decoder().decode(UploadTicket.self, from: Data(#"{"id":"0123456789abcdefghijklmnopqr","partSize":10485760,"parts":3}"#.utf8))
        #expect(ticket == UploadTicket(id: "0123456789abcdefghijklmnopqr", partSize: 10_485_760, parts: 3))
        let encoded = String(decoding: try EmberJSON.encoder().encode(ticket), as: UTF8.self)
        #expect(json(encoded) == json(#"{"id":"0123456789abcdefghijklmnopqr","partSize":10485760,"parts":3}"#))
    }

    @Test func partRanges() {
        let ticket = UploadTicket(id: "u", partSize: 10, parts: 3)
        #expect(UploadTicket(id: "u", partSize: 10, parts: 1).range(ofPart: 1, size: 0) == 0 ..< 0)
        #expect(UploadTicket(id: "u", partSize: 10, parts: 2).range(ofPart: 2, size: 20) == 10 ..< 20)
        #expect(ticket.range(ofPart: 1, size: 25) == 0 ..< 10)
        #expect(ticket.range(ofPart: 2, size: 25) == 10 ..< 20)
        #expect(ticket.range(ofPart: 3, size: 25) == 20 ..< 25)
        #expect(ticket.range(ofPart: 4, size: 25) == 25 ..< 25)
        #expect(UploadTicket(id: "u", partSize: 10, parts: 1).range(ofPart: 1, size: 7) == 0 ..< 7)
    }

    @Test func partRangesNeverTrap() {
        #expect(UploadTicket(id: "u", partSize: -4, parts: 3).range(ofPart: 2, size: 10) == 0 ..< 0)
        #expect(UploadTicket(id: "u", partSize: 0, parts: 3).range(ofPart: 2, size: 10) == 0 ..< 0)
        #expect(UploadTicket(id: "u", partSize: Int.max, parts: 3).range(ofPart: 1, size: 10) == 0 ..< 10)
        #expect(UploadTicket(id: "u", partSize: Int.max, parts: 3).range(ofPart: 3, size: 10) == 10 ..< 10)
        #expect(UploadTicket(id: "u", partSize: 4, parts: 3).range(ofPart: Int.max, size: 10) == 10 ..< 10)
        #expect(UploadTicket(id: "u", partSize: 4, parts: 3).range(ofPart: Int.min, size: 10) == 0 ..< 4)
        #expect(UploadTicket(id: "u", partSize: 4, parts: 3).range(ofPart: 1, size: -5) == 0 ..< 0)
    }

    @Test func aTicketFitsOnlyTheFileItWasWorkedOutFor() {
        // As the server works it out: 10 MiB parts, at least one.
        let mib = 1024 * 1024
        #expect(UploadTicket(id: "u", partSize: 10 * mib, parts: 1).fits(size: 0))
        #expect(UploadTicket(id: "u", partSize: 10 * mib, parts: 1).fits(size: 10 * mib))
        #expect(UploadTicket(id: "u", partSize: 10 * mib, parts: 2).fits(size: 10 * mib + 1))
        #expect(UploadTicket(id: "u", partSize: 10 * mib, parts: 24).fits(size: Limits.fileBytes))
        #expect(UploadTicket(id: "u", partSize: 4, parts: 3).fits(size: 10))

        #expect(!UploadTicket(id: "u", partSize: 4, parts: 2).fits(size: 10))
        #expect(!UploadTicket(id: "u", partSize: 4, parts: 4).fits(size: 10))
        #expect(!UploadTicket(id: "u", partSize: 0, parts: 1).fits(size: 0))
        #expect(!UploadTicket(id: "u", partSize: -1, parts: 1).fits(size: 0))
        #expect(!UploadTicket(id: "u", partSize: 4, parts: 0).fits(size: 0))
        #expect(!UploadTicket(id: "u", partSize: Limits.uploadPartBytes + 1, parts: 1).fits(size: 10))
        #expect(!UploadTicket(id: "u", partSize: 1, parts: 10_000).fits(size: 10_000))
        #expect(!UploadTicket(id: "u", partSize: Int.max, parts: Int.max).fits(size: 10))
        #expect(!UploadTicket(id: "u", partSize: 10 * mib, parts: 24).fits(size: Limits.fileBytes + 1))
        #expect(!UploadTicket(id: "u", partSize: 10 * mib, parts: 1).fits(size: -1))
    }

    @Test func namesAndTypesTheServerRefuses() {
        #expect(Uploads.refusal(name: "a.png", contentType: "image/png") == nil)
        #expect(Uploads.refusal(name: "a.png", contentType: "") == nil)
        #expect(Uploads.refusal(name: "  ", contentType: "") == "A file needs a name.")
        #expect(Uploads.refusal(name: String(repeating: "é", count: 255), contentType: "") == nil)
        #expect(Uploads.refusal(name: String(repeating: "é", count: 256), contentType: "") == "That file’s name is too long.")
        #expect(Uploads.refusal(name: "a", contentType: String(repeating: "x", count: 256)) == "That file’s type is too long.")
        #expect(Limits.fileName == 255 && Limits.fileType == 255)
    }

    @Test(arguments: [
        "image/png", "image/gif", "image/jpeg", "image/tiff", "image/webp", "image/avif", "image/heic", "image/heif",
        "video/mp4", "video/quicktime", "IMAGE/JPEG", "image/jpeg; charset=binary",
    ])
    func previewed(_ type: String) {
        #expect(Uploads.hasPreview(contentType: type))
    }

    @Test(arguments: ["image/bmp", "image/x-icon", "image/vnd.adobe.photoshop", "image/svg+xml", "application/pdf", "audio/mpeg", "text/plain", ""])
    func notPreviewed(_ type: String) {
        #expect(!Uploads.hasPreview(contentType: type))
    }

    @Test func previewSizes() {
        #expect(Uploads.previewSize(width: 600, height: 400) == (600, 400))
        #expect(Uploads.previewSize(width: 2400, height: 1600) == (1200, 800))
        #expect(Uploads.previewSize(width: 4000, height: 1000) == (1200, 300))
        #expect(Uploads.previewSize(width: 1000, height: 4000) == (200, 800))
        #expect(Uploads.previewSize(width: 3000, height: 2001) == (1199, 800))
        #expect(Uploads.previewSize(width: 100_000, height: 10) == (1200, 1))
        #expect(Uploads.previewSize(width: 1200, height: 800) == (1200, 800))
    }

    @Test func limitsAndStrings() {
        #expect(Limits.fileBytes == 250_000_000 && Limits.previewBytes == 5_242_880)
        #expect(Limits.previewWidth == 1200 && Limits.previewHeight == 800)
        #expect(Uploads.tooLarge("clip.mov") == "clip.mov is too large. Choose a file that’s 250 MB or smaller." && Uploads.failed == "Upload failed")
    }
}
