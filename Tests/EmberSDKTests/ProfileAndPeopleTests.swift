import EmberTesting
import Foundation
import ImageIO
import Testing
@testable import EmberSDK

/// Your profile and avatar, someone's page, and bans.
@Suite struct ProfileAndPeopleTests {
    let transport = MockHTTPTransport()
    let client: EmberClient

    init() {
        client = EmberClient.mock(transport: transport)
    }

    // MARK: Profile

    @Test func theProfileIsRead() async throws {
        transport.stub("GET", "/api/users/me/profile", json: Fixtures.profileJSON())
        let answer = try await client.profile()
        #expect(answer.profile == Fixtures.profile)
        #expect(answer.transferID == Fixtures.transferID)
        #expect(transport.requests("GET", "/api/users/me/profile").count == 1)
    }

    @Test func theProfileReadsEverythingTheServerSays() throws {
        let json = #"""
        {"profile":{"name":"Ada","emailAddress":null,"bio":null,"avatarUrl":"/a","avatar":true,"password":false,
        "membershipNeeded":true,"memberful":{"membersOnly":true,"connected":{"name":"Ada L","emailAddress":"ada@example.com"}},
        "assistant":null},"transferId":"fake.id"}
        """#
        let answer = try EmberJSON.decoder().decode(ProfileAnswer.self, from: Data(json.utf8))
        #expect(answer.profile.emailAddress == nil)
        #expect(answer.profile.bio == nil)
        #expect(answer.profile.hasAvatar)
        #expect(!answer.profile.hasPassword)
        #expect(answer.profile.membershipNeeded)
        #expect(answer.profile.memberful == MemberfulStatus(membersOnly: true, connected: .init(name: "Ada L", emailAddress: "ada@example.com")))
        #expect(answer.transferID.revealed == "fake.id")
    }

    @Test func changingTheProfileSendsOnlyWhatChanges() async throws {
        transport.stub("PATCH", "/api/users/me/profile", json: Fixtures.profileJSON())
        _ = try await client.changeProfile(ProfileChanges(name: "Ada King", bio: ""))
        let request = try #require(transport.requests("PATCH", "/api/users/me/profile").last)
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        let body = try #require(transport.lastBody("PATCH", "/api/users/me/profile"))
        #expect(body["name"] as? String == "Ada King")
        #expect(body["bio"] as? String == "")
        #expect(Set(body.keys) == ["name", "bio"])
    }

    @Test func changingTheEmailAddressSendsTheCurrentPassword() async throws {
        transport.stub("PATCH", "/api/users/me/profile", json: Fixtures.profileJSON())
        _ = try await client.changeProfile(ProfileChanges(emailAddress: "ada@example.org", currentPassword: "not-a-real-password"))
        let body = try #require(transport.lastBody("PATCH", "/api/users/me/profile"))
        #expect(body["emailAddress"] as? String == "ada@example.org")
        #expect(body["currentPassword"] as? String == "not-a-real-password")
    }

    @Test func profileChangesDontPrintPasswords() {
        let changes = ProfileChanges(password: "not-a-real-new-password", currentPassword: "not-a-real-password")
        var dumped = ""
        dump(changes, to: &dumped)
        for text in [String(describing: changes), String(reflecting: changes), dumped] {
            #expect(!text.contains("not-a-real"))
        }
    }

    @Test func aWrongCurrentPasswordNamesItsField() async {
        transport.stub("PATCH", "/api/users/me/profile", status: 422, json: Fixtures.errorJSON("That isn't your current password.", field: "currentPassword"))
        let error = await #expect(throws: EmberError.self) {
            try await client.changeProfile(ProfileChanges(password: "not-a-real-new-password", currentPassword: "wrong"))
        }
        #expect(error?.status == 422)
        #expect(error?.message == "That isn't your current password.")
        #expect(error?.field == "currentPassword")
    }

    @Test func tooManyTriesIsRefused() async {
        transport.stub("PATCH", "/api/users/me/profile", status: 429, json: Fixtures.errorJSON("Too many sign-in attempts. Please wait a few minutes and try again."))
        let error = await #expect(throws: EmberError.self) {
            try await client.changeProfile(ProfileChanges(password: "not-a-real-new-password", currentPassword: "wrong"))
        }
        #expect(error?.status == 429)
        #expect(error?.message.hasPrefix("Too many sign-in attempts") == true)
    }

    // MARK: Avatar

    @Test func anAvatarGoesUpWithAVariantAndItsLength() async throws {
        transport.stub("PUT", "/api/users/me/avatar", json: Fixtures.profileJSON())
        let photo = try Self.picture(width: 1200, height: 800, opaque: true)
        let answer = try await client.changeAvatar(photo, filename: "photo.png", contentType: "image/png")
        #expect(answer.profile == Fixtures.profile)

        let request = try #require(transport.requests("PUT", "/api/users/me/avatar").last)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://ember.test")
        let body = try #require(request.httpBody)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == String(body.count))
        let parts = try Self.parts(of: request)
        #expect(parts.map(\.name) == ["avatar", "variant"])
        #expect(parts[0].filename == "photo.png")
        #expect(parts[0].contentType == "image/png")
        #expect(parts[0].data == photo)
        #expect(parts[1].contentType == "image/jpeg")
        let size = try #require(Self.size(of: parts[1].data))
        #expect(size.width <= 512 && size.height <= 512)
        #expect(size.width == 512)
    }

    @Test func aVariantGivenIsSentAsItIs() async throws {
        transport.stub("PUT", "/api/users/me/avatar", json: Fixtures.profileJSON())
        let variant = AvatarVariant(data: Data([1, 2, 3]), contentType: "image/webp")
        _ = try await client.changeAvatar(Data([4, 5, 6]), contentType: "image/heic", variant: variant)
        let parts = try Self.parts(of: try #require(transport.requests("PUT", "/api/users/me/avatar").last))
        #expect(parts.map(\.name) == ["avatar", "variant"])
        #expect(parts[1].data == Data([1, 2, 3]))
        #expect(parts[1].contentType == "image/webp")
    }

    @Test func aPictureImageIOCantReadGoesWithoutAVariant() async throws {
        transport.stub("PUT", "/api/users/me/avatar", json: Fixtures.profileJSON())
        _ = try await client.changeAvatar(Data("<svg/>".utf8), filename: "a.svg", contentType: "image/svg+xml")
        let parts = try Self.parts(of: try #require(transport.requests("PUT", "/api/users/me/avatar").last))
        #expect(parts.map(\.name) == ["avatar"])
    }

    @Test func aVariantFitsTheBoxInAnAcceptedFormat() throws {
        for (width, height, opaque) in [(2000, 3000, true), (700, 300, false), (64, 64, true)] {
            let variant = try #require(AvatarVariant(of: try Self.picture(width: width, height: height, opaque: opaque)))
            #expect(["image/png", "image/jpeg"].contains(variant.contentType))
            #expect(variant.contentType == (opaque ? "image/jpeg" : "image/png"))
            let size = try #require(Self.size(of: variant.data))
            #expect(size.width <= 512 && size.height <= 512)
            #expect(max(size.width, size.height) == min(512, max(width, height)))
            // The bytes say what they are, as the server checks.
            let magic = [UInt8](variant.data.prefix(4))
            #expect(magic == [0x89, 0x50, 0x4E, 0x47] || magic.prefix(3) == [0xFF, 0xD8, 0xFF])
        }
        #expect(AvatarVariant(of: Data("not a picture".utf8)) == nil)
    }

    @Test func aTooLargeAvatarIsntSent() async {
        let error = await #expect(throws: EmberError.self) {
            try await client.changeAvatar(Data(count: EmberClient.avatarByteLimit + 1), contentType: "image/jpeg")
        }
        #expect(error?.kind == .invalid)
        #expect(transport.requests.isEmpty)
    }

    @Test func anAvatarRefusalReadsAsTheServerSaysIt() async {
        transport.stub("PUT", "/api/users/me/avatar", status: 422, json: Fixtures.errorJSON("A variant fits within 512×512"))
        let error = await #expect(throws: EmberError.self) {
            try await client.changeAvatar(Data([1]), contentType: "image/png", variant: AvatarVariant(data: Data([2]), contentType: "image/png"))
        }
        #expect(error?.message == "A variant fits within 512×512")
    }

    @Test func removingTheAvatarDeletesIt() async throws {
        transport.stub("DELETE", "/api/users/me/avatar", json: Fixtures.profileJSON())
        let answer = try await client.removeAvatar()
        #expect(answer.profile == Fixtures.profile)
        #expect(transport.requests("DELETE", "/api/users/me/avatar").last?.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
    }

    // MARK: Someone's page

    @Test func anAdministratorSeesTheirAddressAndALink() async throws {
        let grace = Fixtures.people[1]
        transport.stub("GET", "/api/users/user_grace", json: Fixtures.personJSON(grace, emailAddress: "grace@example.com", transferID: Secret("fake.link.id")))
        let person = try await client.person(grace.id)
        #expect(person.user == grace)
        #expect(person.emailAddress == "grace@example.com")
        #expect(person.transferID?.revealed == "fake.link.id")
    }

    @Test func anyoneElseSeesThePersonAlone() async throws {
        let grace = Fixtures.people[1]
        transport.stub("GET", "/api/users/user_grace", json: Fixtures.personJSON(grace))
        let person = try await client.person(grace.id)
        #expect(person == PersonDetails(user: grace))
    }

    @Test func anIDCantReachAnotherRoute() async throws {
        _ = try? await client.person("../me/profile")
        #expect(transport.requests.last?.url?.absoluteString == "https://ember.test/api/users/..%2Fme%2Fprofile")
    }

    @Test func nobodyWithTheIDIsNotFound() async {
        transport.stub("GET", "/api/users/user_nobody", status: 404, json: Fixtures.errorJSON("Not found"))
        let error = await #expect(throws: EmberError.self) { try await client.person("user_nobody") }
        #expect(error?.status == 404)
        #expect(error?.message == "Not found")
    }

    // MARK: Bans

    @Test func banningAnswersThemBanned() async throws {
        var banned = Fixtures.people[1]
        banned.status = .banned
        transport.stub("POST", "/api/users/user_grace/ban", json: Fixtures.changedPersonJSON(banned))
        let user = try await client.ban(banned.id)
        #expect(user.status == .banned)
        let request = try #require(transport.requests("POST", "/api/users/user_grace/ban").last)
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        #expect(request.httpBody == nil)
    }

    @Test func unbanningAnswersThemActive() async throws {
        transport.stub("DELETE", "/api/users/user_grace/ban", json: Fixtures.changedPersonJSON(Fixtures.people[1]))
        #expect(try await client.unban("user_grace").status == .active)
    }

    @Test func onlyAdministratorsBan() async {
        transport.stub("POST", "/api/users/user_grace/ban", status: 403, json: Fixtures.errorJSON("Only administrators can ban people"))
        let error = await #expect(throws: EmberError.self) { try await client.ban("user_grace") }
        #expect(error?.status == 403)
        #expect(error?.message == "Only administrators can ban people")
    }

    @Test func anAddressThatCantBeBlockedIsRefused() async {
        transport.stub("POST", "/api/users/user_grace/ban", status: 422, json: Fixtures.errorJSON("They signed in from your IP address, which a ban would block for you too"))
        let error = await #expect(throws: EmberError.self) { try await client.ban("user_grace") }
        #expect(error?.status == 422)
        #expect(error?.message.contains("your IP address") == true)
    }

    // MARK: Pictures and forms

    /// A PNG of `width`×`height`, with transparency unless `opaque`.
    static func picture(width: Int, height: Int, opaque: Bool) throws -> Data {
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: opaque ? 1 : 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The pixel size of the picture in `data`.
    static func size(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    struct Part {
        var name: String
        var filename: String?
        var contentType: String?
        var data: Data
    }

    /// The parts of a multipart request, in order.
    static func parts(of request: URLRequest) throws -> [Part] {
        let type = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        try #require(type.hasPrefix(prefix))
        let boundary = Data("--\(type.dropFirst(prefix.count))".utf8)
        let body = try #require(request.httpBody)
        var parts: [Part] = []
        var cursor = try #require(body.range(of: boundary)).upperBound
        while body[cursor...].starts(with: Data("\r\n".utf8)) {
            let headersEnd = try #require(body.range(of: Data("\r\n\r\n".utf8), in: cursor ..< body.endIndex))
            let headers = String(decoding: body[(cursor + 2) ..< headersEnd.lowerBound], as: UTF8.self)
            let next = try #require(body.range(of: Data("\r\n".utf8) + boundary, in: headersEnd.upperBound ..< body.endIndex))
            var part = Part(name: "", data: body[headersEnd.upperBound ..< next.lowerBound])
            for line in headers.components(separatedBy: "\r\n") {
                if line.hasPrefix("Content-Type: ") { part.contentType = String(line.dropFirst("Content-Type: ".count)) }
                if line.hasPrefix("Content-Disposition: ") {
                    part.name = Self.quoted("name", in: line) ?? ""
                    part.filename = Self.quoted("filename", in: line)
                }
            }
            parts.append(part)
            cursor = next.upperBound
        }
        #expect(body[cursor...] == Data("--\r\n".utf8))
        return parts
    }

    private static func quoted(_ key: String, in line: String) -> String? {
        guard let start = line.range(of: "; \(key)=\"") else { return nil }
        let rest = line[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
