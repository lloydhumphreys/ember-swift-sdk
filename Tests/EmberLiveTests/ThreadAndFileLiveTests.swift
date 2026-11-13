import EmberSDK
import Foundation
import Testing

/// Threads and files against a running server, in the same serialized suite as the rest.
extension LiveTests {
    /// The room called launch, opened and loaded.
    @MainActor
    func launch(on client: EmberClient) async throws -> RoomSession {
        let sidebar = try await client.sidebar()
        let room = try #require(sidebar.rooms.first { $0.room.name?.lowercased() == "launch" }?.room)
        let session = RoomSession(client: client, roomID: room.id)
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open })
        return session
    }

    /// The seeded thread's parent in launch: the question about a status page.
    @MainActor
    func seededParent(in session: RoomSession) throws -> Message {
        try #require(session.timeline.messages.first { ($0.thread?.count ?? 0) > 0 && $0.plainText.contains("status page") })
    }

    /// `path` fetched on a session with no cookies at all.
    func fetchedWithoutCookies(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @MainActor @Test func theSeededThreadOpens() async throws {
        let client = try await signedIn()
        let session = try await launch(on: client)
        defer { session.stop() }
        let parent = try seededParent(in: session)
        let thread = session.thread(parent.id)
        let lease = thread.open()
        defer { lease.close() }
        #expect(await eventually { thread.timeline.isLoaded })
        #expect(thread.timeline.parentMessage?.id == parent.id)
        #expect(thread.timeline.replies.count >= 3)
        #expect(thread.timeline.replies.allSatisfy { $0.parentId == parent.id })
        #expect(thread.notice == nil)
    }

    @MainActor @Test func repliesGoToTheThreadAndAlsoToTheRoom() async throws {
        let client = try await signedIn()
        let session = try await launch(on: client)
        defer { session.stop() }
        let parent = try seededParent(in: session)
        let thread = session.thread(parent.id)
        let lease = thread.open()
        defer { lease.close() }
        #expect(await eventually { thread.timeline.isLoaded })
        let before = thread.timeline.parentMessage?.thread?.count ?? 0

        let tag = UUID().uuidString.prefix(8)
        let only = "Thread only \(tag)"
        let onlyID = thread.reply(body: "<p>\(only)</p>", plainText: only)
        #expect(await eventually {
            thread.timeline.pending.isEmpty && thread.timeline.replies.contains { $0.clientMessageId == onlyID && $0.plainText == only }
        })
        #expect(await eventually { thread.timeline.parentMessage?.thread?.count == before + 1 })
        #expect(await eventually { session.timeline.messages.first { $0.id == parent.id }?.thread?.count == before + 1 })
        #expect(!session.timeline.messages.contains { $0.clientMessageId == onlyID })

        let also = "Also sent \(tag)"
        let alsoID = thread.reply(body: "<p>\(also)</p>", plainText: also, delivery: .threadAndRoom)
        #expect(await eventually {
            thread.timeline.pending.isEmpty && thread.timeline.replies.contains { $0.clientMessageId == alsoID && $0.alsoSent == true }
        })
        #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == alsoID && $0.parentId == parent.id } })
        #expect(await eventually { thread.timeline.parentMessage?.thread?.count == before + 2 })
        #expect(await eventually { session.timeline.messages.first { $0.id == parent.id }?.thread?.count == before + 2 })
    }

    /// A small text file in a folder of its own.
    func smallFile(_ text: String) throws -> (UploadSource, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ember-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notes.txt")
        try Data(text.utf8).write(to: url)
        return (try UploadSource(fileURL: url, contentType: "text/plain"), folder)
    }

    /// Both of `file`'s addresses answer its bytes to a client with no cookies.
    func expectServed(_ file: StoredFile, as text: String, on client: EmberClient) async throws {
        for path in [file.url, file.downloadUrl] {
            let (data, response) = try await fetchedWithoutCookies(try #require(client.url(path)))
            #expect(response.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == text)
        }
    }

    @MainActor @Test func aFileGoesToARoom() async throws {
        let client = try await signedIn()
        let session = try await launch(on: client)
        defer { session.stop() }
        let text = "Room file \(UUID().uuidString.prefix(8))"
        let (source, folder) = try smallFile(text)
        defer { try? FileManager.default.removeItem(at: folder) }

        let id = try #require(session.send(files: [source]).first)
        #expect(await eventually { session.timeline.pending.isEmpty })
        let message = try #require(session.timeline.messages.first { $0.clientMessageId == id })
        let file = try #require(message.attachment)
        #expect(file.name == "notes.txt")
        #expect(file.byteSize == text.utf8.count)
        try await expectServed(file, as: text, on: client)
    }

    @MainActor @Test func aFileGoesToAThread() async throws {
        let client = try await signedIn()
        let session = try await launch(on: client)
        defer { session.stop() }
        let parent = try seededParent(in: session)
        let thread = session.thread(parent.id)
        let lease = thread.open()
        defer { lease.close() }
        #expect(await eventually { thread.timeline.isLoaded })
        let text = "Thread file \(UUID().uuidString.prefix(8))"
        let (source, folder) = try smallFile(text)
        defer { try? FileManager.default.removeItem(at: folder) }

        let id = try #require(thread.send(files: [source]).first)
        #expect(await eventually { thread.timeline.pending.isEmpty })
        let reply = try #require(thread.timeline.replies.first { $0.clientMessageId == id })
        #expect(reply.parentId == parent.id)
        #expect(!session.timeline.messages.contains { $0.clientMessageId == id })
        try await expectServed(try #require(reply.attachment), as: text, on: client)
    }
}
