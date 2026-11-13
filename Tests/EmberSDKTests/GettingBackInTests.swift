import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Signing in with a sign-in link, and resetting a password with an emailed code.
@Suite struct GettingBackInTests {
    let transport = MockHTTPTransport()
    let client: EmberClient

    init() {
        client = EmberClient.mock(transport: transport)
    }

    /// Signs out first, so there's a reason to clear.
    func signedOut() async {
        transport.stub("DELETE", "/api/session", status: 204, json: "")
        await client.signOut()
        #expect(client.signOutReason == .userInitiated)
        #expect(!client.hasSessionCookie)
    }

    // MARK: Sign-in links

    @Test func aSignInLinkStartsASession() async throws {
        await signedOut()
        transport.stub("POST", "/api/session/transfers", status: 201, json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        let me = try await client.signIn(transferID: Fixtures.transferID)
        #expect(me == Fixtures.me)
        #expect(client.hasSessionCookie)
        #expect(client.signOutReason == nil)
        let request = try #require(transport.requests("POST", "/api/session/transfers").last)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://ember.test")
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        #expect(transport.lastBody("POST", "/api/session/transfers")?["transferId"] as? String == Fixtures.transferID.revealed)
    }

    @Test func aBadLinkSaysSoWithoutItsID() async {
        transport.stub("POST", "/api/session/transfers", status: 400, json: "")
        let error = await #expect(throws: EmberError.self) { try await client.signIn(transferID: Fixtures.transferID) }
        #expect(error?.status == 400)
        #expect(error?.message == "This sign-in link doesn’t work. It may have expired.")
        #expect(!String(describing: error as Any).contains(Fixtures.transferID.revealed))
        #expect(!(error?.localizedDescription.contains(Fixtures.transferID.revealed) ?? true))
        #expect(!client.hasSessionCookie)
    }

    @Test func aRefusedLinkDoesntSignAnyoneOut() async {
        let signedOut = Counter()
        client.addSignedOutHandler { signedOut.add() }
        transport.stub("POST", "/api/session/transfers", status: 401, json: Fixtures.errorJSON("Not signed in"))
        _ = try? await client.signIn(transferID: Fixtures.transferID)
        transport.stub("PUT", "/api/password_resets", status: 401, json: Fixtures.errorJSON("Not signed in"))
        _ = try? await client.resetPassword(emailAddress: "ada@example.com", code: "12345678", newPassword: "not-a-real-password")
        #expect(signedOut.value == 0)
        #expect(client.signOutReason == nil)
    }

    // MARK: Asking for a code

    @Test func askingForACodeSendsTheAddressAndToken() async throws {
        transport.stub("POST", "/api/password_resets", status: 202, json: "{}")
        try await client.askForPasswordReset(emailAddress: "ada@example.com", turnstileToken: "fake-turnstile-token")
        let request = try #require(transport.requests("POST", "/api/password_resets").last)
        #expect(request.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
        let body = try #require(transport.lastBody("POST", "/api/password_resets"))
        #expect(body["emailAddress"] as? String == "ada@example.com")
        #expect(body["turnstileToken"] as? String == "fake-turnstile-token")
    }

    @Test func askingWithoutTurnstileSendsNoToken() async throws {
        transport.stub("POST", "/api/password_resets", status: 202, json: "{}")
        try await client.askForPasswordReset(emailAddress: "ada@example.com")
        let body = try #require(transport.lastBody("POST", "/api/password_resets"))
        #expect(Set(body.keys) == ["emailAddress"])
    }

    @Test func aFailedTurnstileCheckNamesItsField() async {
        transport.stub("POST", "/api/password_resets", status: 422, json: Fixtures.errorJSON("Ember couldn't check that you're a person. Try again.", field: "turnstile"))
        let error = await #expect(throws: EmberError.self) { try await client.askForPasswordReset(emailAddress: "ada@example.com") }
        #expect(error?.status == 422)
        #expect(error?.field == "turnstile")
    }

    @Test func askingTooOftenIsRefused() async {
        transport.stub("POST", "/api/password_resets", status: 429, json: Fixtures.errorJSON("Too many codes asked for. Try again later."))
        let error = await #expect(throws: EmberError.self) { try await client.askForPasswordReset(emailAddress: "ada@example.com") }
        #expect(error?.status == 429)
        #expect(error?.message == "Too many codes asked for. Try again later.")
    }

    @Test func theBootstrapSaysWhetherTurnstileIsOn() throws {
        let off = Fixtures.bootstrap
        #expect(off.turnstileSiteKey == nil)
        #expect(off.passwordResetCodes)
        let json = Fixtures.bootstrapJSON().replacingOccurrences(of: #""turnstileSiteKey":null"#, with: #""turnstileSiteKey":"1x00000000000000000000AA""#)
        #expect(Fixtures.decode(json, as: Bootstrap.self).turnstileSiteKey == "1x00000000000000000000AA")
    }

    // MARK: Resetting with the code

    @Test func aResetWithTheCodeSignsIn() async throws {
        await signedOut()
        transport.stub("PUT", "/api/password_resets", status: 201, json: Fixtures.meJSON(), headers: Fixtures.sessionCookieHeaders)
        let me = try await client.resetPassword(emailAddress: "ada@example.com", code: "1234 5678", newPassword: "not-a-real-password")
        #expect(me == Fixtures.me)
        #expect(client.hasSessionCookie)
        #expect(client.signOutReason == nil)
        let body = try #require(transport.lastBody("PUT", "/api/password_resets"))
        #expect(body["emailAddress"] as? String == "ada@example.com")
        #expect(body["code"] as? String == "1234 5678")
        #expect(body["password"] as? String == "not-a-real-password")
        #expect(transport.requests("PUT", "/api/password_resets").last?.value(forHTTPHeaderField: "Sec-Fetch-Site") == "same-origin")
    }

    @Test func aResetForSomeoneWhoSignsInElsewhereAnswersNil() async throws {
        await signedOut()
        transport.stub("PUT", "/api/password_resets", status: 200, json: #"{"user":null}"#)
        let me = try await client.resetPassword(emailAddress: "ada@example.com", code: "12345678", newPassword: "not-a-real-password")
        #expect(me == nil)
        #expect(!client.hasSessionCookie)
        #expect(client.signOutReason == .userInitiated)
    }

    @Test func aWrongCodeNamesItsField() async {
        transport.stub("PUT", "/api/password_resets", status: 422, json: Fixtures.errorJSON("That code isn't right.", field: "code"))
        let error = await #expect(throws: EmberError.self) {
            try await client.resetPassword(emailAddress: "ada@example.com", code: "00000000", newPassword: "not-a-real-password")
        }
        #expect(error?.status == 422)
        #expect(error?.field == "code")
        #expect(error?.message == "That code isn't right.")
    }
}

/// Reading sign-in links people paste.
@Suite struct SignInLinkTests {
    @Test func aLinkGivesItsOriginAndID() throws {
        let link = try #require(SignInLink("https://Chat.Example.com/session/transfers#token=user_1.sess-2.k9.fake_sig"))
        #expect(link.origin.absoluteString == "https://chat.example.com")
        #expect(link.transferID.revealed == "user_1.sess-2.k9.fake_sig")
    }

    @Test func spacesAPortAndATrailingSlashAreFine() throws {
        let link = try #require(SignInLink("  http://localhost:8787/session/transfers/#token=a.b.c.d\n"))
        #expect(link.origin.absoluteString == "http://localhost:8787")
        #expect(link.transferID.revealed == "a.b.c.d")
        let other = try #require(SignInLink("https://ember.test/session/transfers#other=1&token=x.y"))
        #expect(other.transferID.revealed == "x.y")
    }

    @Test func otherLinksArent() {
        for text in [
            "https://ember.test/join/invitation#token=abc",
            "https://ember.test/session/transfers?token=abc",
            "https://ember.test/session/transfers#token=",
            "https://ember.test/session/transfers",
            "https://ember.test/rooms/general#token=abc",
            "https://ember.test/session/transfers#token=a%20b",
            "https://ember.test/session/transfers#token=a/b",
            "ftp://ember.test/session/transfers#token=abc",
            "javascript:alert(1)//session/transfers#token=abc",
            "/session/transfers#token=abc",
            "https://ada:pw@ember.test/session/transfers#token=abc",
            "not a link",
            "",
        ] {
            #expect(SignInLink(text) == nil, "\(text)")
        }
    }

    @Test func aLinkDoesntPrintItsID() throws {
        let link = try #require(SignInLink("https://ember.test/session/transfers#token=fake.secret.id"))
        var dumped = ""
        dump(link, to: &dumped)
        for text in [String(describing: link), String(reflecting: link), dumped, "\(link)"] {
            #expect(!text.contains("fake.secret.id"), "\(text)")
        }
    }
}

/// Secrets stay out of everything printed.
@Suite struct SecretTests {
    let secret = Secret("fake-secret-value")

    @Test func aSecretPrintsRedacted() {
        var dumped = ""
        dump(secret, to: &dumped)
        for text in [String(describing: secret), String(reflecting: secret), dumped, "\(secret)", "\([secret])", "\(Optional(secret) as Any)"] {
            #expect(!text.contains("fake-secret-value"), "\(text)")
        }
        #expect(String(describing: secret) == "<redacted>")
        #expect(secret.revealed == "fake-secret-value")
    }

    @Test func modelsHoldingSecretsDontPrintThem() throws {
        let outcome = InvitationOutcome.invited(Fixtures.emailInvitation(), link: secret)
        let person = PersonDetails(user: Fixtures.people[1], transferID: secret)
        let answer = ProfileAnswer(profile: Fixtures.profile, transferID: secret)
        for value in [outcome as Any, person, answer, ResentInvitation(invitation: Fixtures.emailInvitation(), link: secret)] {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), dumped] {
                #expect(!text.contains("fake-secret-value"), "\(text)")
            }
        }
    }

    @Test func aSecretDecodes() throws {
        let decoded = try JSONDecoder().decode([Secret].self, from: Data(#"["fake-secret-value"]"#.utf8))
        #expect(decoded == [secret])
    }
}
