import EmberSDK
import Foundation
import Testing

/// Sign-in links and password resets. A reset is done for Leo Park, whom no other live test signs
/// in as, and his password is changed back to the seeded one before the test ends.
extension LiveTests {
    @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func signsInWithASignInLink() async throws {
        let client = try await signedIn()
        let me = try await client.me()
        let transferID = try await client.profile().transferID

        // A link as the web app shows it reads back to the same origin and id.
        let link = try #require(SignInLink("\(origin.absoluteString)/session/transfers#token=\(transferID.revealed)"))
        let sameID = link.transferID == transferID
        let sameOrigin = link.origin.host() == origin.host() && link.origin.port == origin.port
        #expect(sameID)
        #expect(sameOrigin)

        let other = EmberClient(origin: link.origin, cookies: EphemeralCookieStorage())
        #expect(!other.hasSessionCookie)
        let signedIn = try await other.signIn(transferID: link.transferID)
        #expect(signedIn.id == me.id)
        #expect(other.hasSessionCookie)
        #expect(try await other.me().id == me.id)
        // The first client is still signed in.
        #expect(try await client.me().id == me.id)
    }

    @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func anAdministratorSignsInAsSomeoneWithTheirLink() async throws {
        let client = try await signedIn()
        let leo = try #require(try await client.directory().users.first { $0.name.hasPrefix("Leo") })
        let transferID = try #require(try await client.person(leo.id).transferID)
        let other = freshClient()
        #expect(try await other.signIn(transferID: transferID).id == leo.id)
    }

    @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aBadSignInLinkIsRefused() async throws {
        let client = freshClient()
        let error = await #expect(throws: EmberError.self) {
            try await client.signIn(transferID: Secret("not-a-transfer"))
        }
        #expect(error?.status == 400)
        #expect(!client.hasSessionCookie)
    }

    @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func resetsAPasswordAndChangesItBack() async throws {
        let seedPassword = try #require(livePassword(), "Set EMBER_SEED_PASSWORD or write .dev/seed-password.")
        let leoAddress = "leo@example.com"
        #expect(try await freshClient().bootstrap().passwordResetCodes)

        let client = freshClient()
        try await client.askForPasswordReset(emailAddress: leoAddress)
        // The same answer for an address no one has.
        try await client.askForPasswordReset(emailAddress: "no.one.\(UUID().uuidString.prefix(8))@example.com")
        let code = try #require(try await outbox().resetCodes.last { $0.emailAddress == leoAddress }?.code)
        let isEightDigits = code.count == 8 && code.allSatisfy(\.isASCII) && code.allSatisfy(\.isNumber)
        #expect(isEightDigits)

        let wrongCode = code == "00000000" ? "11111111" : "00000000"
        let temporary = "Live-\(UUID().uuidString)"
        let wrong = await #expect(throws: EmberError.self) {
            try await client.resetPassword(emailAddress: leoAddress, code: wrongCode, newPassword: temporary)
        }
        #expect(wrong?.status == 422)
        #expect(wrong?.field == "code")
        #expect(!client.hasSessionCookie)

        let leo = try await client.resetPassword(emailAddress: leoAddress, code: code, newPassword: temporary)
        #expect(leo?.name.hasPrefix("Leo") == true)
        #expect(client.hasSessionCookie)

        // The code is spent, and the old password no longer works.
        let spent = await #expect(throws: EmberError.self) {
            try await freshClient().resetPassword(emailAddress: leoAddress, code: code, newPassword: temporary)
        }
        #expect(spent?.status == 422)
        let old = await #expect(throws: EmberError.self) { try await signedIn(as: leoAddress, password: seedPassword) }
        #expect(old?.status == 401)

        // Back to the seeded password, signed in with the new one.
        let withNew = try await signedIn(as: leoAddress, password: temporary)
        _ = try await withNew.changeProfile(ProfileChanges(password: seedPassword, currentPassword: temporary))
        let back = try await signedIn(as: leoAddress, password: seedPassword)
        #expect(try await back.me().id == leo?.id)
        let refused = await #expect(throws: EmberError.self) { try await signedIn(as: leoAddress, password: temporary) }
        #expect(refused?.status == 401)
    }
}
