import EmberRichText
import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// The keyed bot API: what goes out, what comes back, and that the key stays out of everything else.
@Suite struct EmberBotTests {
    let transport = MockHTTPTransport()
    let bot: EmberBot
    let key = "bot42-s3cr3tt0k3n"
    let path = "/rooms/room-general/bot42-s3cr3tt0k3n/messages"

    init() {
        bot = EmberBot(origin: URL(string: "https://ember.test")!, roomID: "room-general", key: "bot42-s3cr3tt0k3n", transport: transport)
    }

    private func created(_ id: String = "m500") -> MockHTTPTransport.Answer {
        MockHTTPTransport.Answer(status: 201, json: "null", headers: ["Location": "https://ember.test/rooms/room-general/@\(id)"])
    }

    // MARK: Posting

    @Test func postingTextSendsItAsTheBodyAndAnswersThePermalink() async throws {
        transport.stub("POST", path, answer: { _ in created() })
        let posted = try await bot.post(text: "Deploy finished")
        #expect(posted.id == "m500")
        #expect(posted.url.absoluteString == "https://ember.test/rooms/room-general/@m500")
        let request = try #require(transport.requests("POST", path).last)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
        #expect(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } == "<p>Deploy finished</p>")
    }

    @Test func postingTextEscapesItAsARoomsPlainTextIs() async throws {
        transport.stub("POST", path, answer: { _ in created() })
        let text = "1 < 2 & <b>bold</b>\r\nnext line\n\n"
        try await bot.post(text: text)
        let request = try #require(transport.requests("POST", path).last)
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == RichText.body(fromPlainText: "1 < 2 & <b>bold</b>\nnext line"))
        #expect(body?.contains("<b>") == false)
        #expect(body?.contains("&lt;b&gt;") == true)
    }

    @Test func blankOrTooLongTextIsRefusedBeforeSending() async {
        for text in [" \n ", String(repeating: "a", count: Limits.message + 1)] {
            let error = await #expect(throws: EmberError.self) { try await bot.post(text: text) }
            #expect(error?.kind == .invalid)
        }
        #expect(transport.requests("POST", path).isEmpty)
    }

    @Test func postingHTMLSendsItAsMarkup() async throws {
        transport.stub("POST", path, answer: { _ in created() })
        try await bot.post(html: "<p>Deploy <b>finished</b></p>")
        let request = try #require(transport.requests("POST", path).last)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
        #expect(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } == "<p>Deploy <b>finished</b></p>")
    }

    @Test func aBotSendsNoCookiesAndNoWriteHeaders() async throws {
        transport.stub("POST", path, answer: { _ in created() })
        try await bot.post(text: "Hello")
        let request = try #require(transport.requests.last)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil)
    }

    @Test func postingAFileSendsAMultipartFormWithAnAttachment() async throws {
        transport.stub("POST", path, answer: { _ in created("m501") })
        let bytes = Data("line 1\nline 2\n".utf8)
        let posted = try await bot.post(file: bytes, named: "build.log", contentType: "text/plain")
        #expect(posted.id == "m501")
        let request = try #require(transport.requests("POST", path).last)
        let type = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(type.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
        let body = try #require(request.httpBody)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.hasPrefix("--\(boundary)\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"attachment\"; filename=\"build.log\"\r\n"))
        #expect(text.contains("Content-Type: text/plain\r\n\r\nline 1\nline 2\n\r\n--\(boundary)--\r\n"))
    }

    @Test func aFileNameCantBreakOutOfItsHeader() async throws {
        transport.stub("POST", path, answer: { _ in created() })
        try await bot.post(file: Data([1, 2, 3]), named: "a\"b\r\nX-Injected: 1.bin")
        let body = try #require(transport.requests("POST", path).last?.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("filename=\"a%22b%0D%0AX-Injected: 1.bin\""))
        #expect(!text.contains("\r\nX-Injected"))
    }

    @Test func aFileOnDiskIsPostedUnderItsOwnName() async throws {
        transport.stub("POST", path, answer: { _ in created() })
        let file = try TestFile(Array("report".utf8), name: "report.txt")
        try await bot.post(fileAt: file.url, contentType: "text/plain")
        let body = try #require(transport.requests("POST", path).last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains("filename=\"report.txt\""))
    }

    @Test func aFileThatCantBeReadFailsWithoutSendingAnything() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ember-tests-\(UUID().uuidString)/missing.txt")
        let error = await #expect(throws: EmberError.self) { try await bot.post(fileAt: missing) }
        #expect(error?.kind == .unreadableFile)
        #expect(transport.requests.isEmpty)
    }

    // MARK: Boosting

    @Test func boostingPostsTheContentAndReadsTheBoost() async throws {
        let boosts = "\(path.dropLast("messages".count))messages/m7/boosts"
        transport.stub("POST", boosts, status: 201, json: """
        {"id":"b1","content":"ship it","created_at":"2026-11-10T10:00:00.000Z",\
        "booster":{"id":"bot42","name":"Deploy Bot","role":"bot","avatar_url":"https://ember.test/users/bot42/avatar"},\
        "message":{"id":"m7","url":"https://ember.test/rooms/room-general/@m7"}}
        """)
        let boost = try await bot.boost("m7", with: "ship it")
        #expect(boost == EmberBot.Boost(id: "b1", content: "ship it", messageID: "m7"))
        let request = try #require(transport.requests("POST", boosts).last)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain; charset=utf-8")
        #expect(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } == "ship it")
    }

    @Test func aMessageIdIsEscapedInTheAddress() async throws {
        transport.stub("POST", "/rooms/room-general/bot42-s3cr3tt0k3n/messages/a%2Fb/boosts", status: 404, json: "")
        let error = await #expect(throws: EmberError.self) { try await bot.boost("a/b", with: "x") }
        #expect(error?.status == 404)
        #expect(transport.requests.count == 1)
    }

    // MARK: Refusals

    @Test func aWrongKeyReadsTheServersWords() async {
        transport.stub("POST", path, status: 401, json: Fixtures.errorJSON("Unknown bot key"))
        let error = await #expect(throws: EmberError.self) { try await bot.post(text: "Hello") }
        #expect(error?.status == 401)
        #expect(error?.message == "Unknown bot key")
    }

    @Test func aBodylessRefusalReadsAsItsStatus() async {
        transport.stub("POST", path, status: 422, json: "")
        let error = await #expect(throws: EmberError.self) { try await bot.post(html: " ") }
        #expect(error?.status == 422)
        #expect(error?.message.isEmpty == false)
    }

    @Test func aBotThatIsNotInTheRoomIsAnEmpty404() async {
        transport.stub("POST", path, status: 404, json: "")
        let error = await #expect(throws: EmberError.self) { try await bot.post(text: "Hello") }
        #expect(error?.status == 404)
    }

    @Test func aSuccessWithoutALocationIsUnreadable() async {
        transport.stub("POST", path, status: 201, json: "null")
        let error = await #expect(throws: EmberError.self) { try await bot.post(text: "Hello") }
        #expect(error?.kind == .undecodable)
    }

    @Test func anUnreachableServerSaysWhichOne() async {
        transport.failEverything()
        let error = await #expect(throws: EmberError.self) { try await bot.post(text: "Hello") }
        #expect(error?.status == 0)
        #expect(error?.message == "Couldn’t reach ember.test.")
    }

    @Test func aBotIsNotSignedOutByA401() async {
        let client = EmberClient.mock(transport: transport)
        let signedOut = Counter()
        client.addSignedOutHandler { signedOut.add() }
        transport.stub("POST", path, status: 401, json: Fixtures.errorJSON("Unknown bot key"))
        _ = await #expect(throws: EmberError.self) { try await bot.post(text: "Hello") }
        #expect(signedOut.value == 0)
    }

    // MARK: Keeping the key out

    @Test func theKeyIsInNoDescriptionOrDump() {
        var output = ""
        dump(bot, to: &output)
        let shown = [bot.description, bot.debugDescription, "\(bot)", String(describing: bot), String(reflecting: bot), output]
        for text in shown {
            #expect(!text.contains("s3cr3tt0k3n"), "\(text)")
            #expect(!text.contains(key), "\(text)")
        }
        #expect(bot.description == "EmberBot(https://ember.test, room: room-general)")
    }

    @Test func theKeyIsInNoErrorTheBotThrows() async {
        let cases: [(Int, String)] = [(401, Fixtures.errorJSON("Unknown bot key")), (404, ""), (422, ""), (500, "<html>oops</html>")]
        for (status, json) in cases {
            transport.stub("POST", path, status: status, json: json)
            let error = await #expect(throws: EmberError.self) { try await bot.post(text: "Hello") }
            for text in [error.map { "\($0)" }, error?.message, error?.localizedDescription, error.map { String(reflecting: $0) }] {
                #expect(text?.contains("s3cr3tt0k3n") != true)
            }
        }
        transport.failEverything()
        let unreachable = await #expect(throws: EmberError.self) { try await bot.post(text: "Hello") }
        #expect("\(String(describing: unreachable))".contains("s3cr3tt0k3n") == false)
    }

    @Test func theKeyIsOnlyEverInTheRequestAddress() async throws {
        transport.stub("POST", path, answer: { _ in created() })
        try await bot.post(text: "Hello")
        let request = try #require(transport.requests.last)
        #expect(request.url?.path == path)
        #expect(request.url?.query == nil)
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            #expect(!value.contains("s3cr3tt0k3n"), "\(name)")
        }
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("s3cr3tt0k3n"))
    }

    @Test func aKeyCantReachAnotherRoute() async throws {
        let sneaky = EmberBot(origin: URL(string: "https://ember.test")!, roomID: "room-general", key: "../../api/me?x=", transport: transport)
        transport.stub("POST", "*", answer: { _ in created() })
        try? await sneaky.post(text: "Hello")
        let url = try #require(transport.requests.last?.url)
        #expect(url.host == "ember.test")
        #expect(url.path.hasPrefix("/rooms/room-general/"))
        #expect(url.query == nil)
        #expect(url.absoluteString.hasSuffix("/messages"))
    }

    @Test func aKeyOfOnlyDotsIsEscaped() async throws {
        let dots = EmberBot(origin: URL(string: "https://ember.test")!, roomID: "room-general", key: "..", transport: transport)
        transport.stub("POST", "*", answer: { _ in created() })
        try? await dots.post(text: "Hello")
        #expect(transport.requests.last?.url?.absoluteString == "https://ember.test/rooms/room-general/%2E%2E/messages")
    }

    @Test func theOriginIsKeptBareWhateverAddressIsGiven() {
        let bot = EmberBot(origin: URL(string: "https://user:pass@ember.test:8443/some/path?x=1#y")!, roomID: "r", key: "k-1", transport: transport)
        #expect(bot.origin.absoluteString == "https://ember.test:8443")
    }
}
