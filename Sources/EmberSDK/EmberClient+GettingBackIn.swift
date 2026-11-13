import Foundation

extension EmberClient {
    /// `POST /api/session/transfers`: signs in with a sign-in link's id, as `SignInLink` reads it
    /// from a pasted link. Make the client for the link's `origin`. The session is kept as
    /// `signIn(emailAddress:password:)` keeps one.
    ///
    /// A link that's expired, was already replaced, or is for a guest or someone deactivated fails 400.
    public func signIn(transferID: Secret) async throws -> Me {
        struct Body: Encodable { var transferId: String }
        do {
            return try await send("POST", "/api/session/transfers", body: Body(transferId: transferID.revealed), as: SignedIn.self).user
        } catch let error as EmberError where error.status == 400 {
            // The server answers a bad link with an empty 400.
            throw EmberError(status: 400, message: "This sign-in link doesn’t work. It may have expired.")
        }
    }

    /// `POST /api/password_resets`: emails a code for a new password to whoever has `emailAddress`.
    /// It answers the same whether or not anyone has it.
    ///
    /// When `Bootstrap.turnstileSiteKey` isn't nil, the server asks for a Turnstile token made with
    /// that key and fails 422 with `field` `"turnstile"` without a good one. It fails 503 while Ember
    /// can't send email (`Bootstrap.passwordResetCodes` is false), and 429 when asked too often.
    public func askForPasswordReset(emailAddress: String, turnstileToken: String? = nil) async throws {
        struct Body: Encodable {
            var emailAddress: String
            var turnstileToken: String?
        }
        try await send("POST", "/api/password_resets", body: Body(emailAddress: emailAddress, turnstileToken: turnstileToken))
    }

    /// `PUT /api/password_resets`: gives whoever has `emailAddress` the new password, with the code
    /// emailed to them, and ends all their sessions. Answers who's signed in now, kept as
    /// `signIn(emailAddress:password:)` keeps them, or nil when they sign in another way
    /// (Memberful) and must do that next.
    ///
    /// A wrong or spent code fails 422 with `field` `"code"`; a password too short or long, `"password"`.
    public func resetPassword(emailAddress: String, code: String, newPassword: String) async throws -> Me? {
        struct Body: Encodable {
            var emailAddress: String
            var code: String
            var password: String
        }
        struct Done: Decodable { var user: Me? }
        return try await send("PUT", "/api/password_resets", body: Body(emailAddress: emailAddress, code: code, password: newPassword), as: Done.self).user
    }
}
