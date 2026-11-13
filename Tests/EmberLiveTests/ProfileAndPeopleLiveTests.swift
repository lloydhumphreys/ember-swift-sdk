import CoreGraphics
import EmberSDK
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Your profile and picture, someone else's details, and banning. Profiles are changed back, and
/// the one person banned, Tomás García, is let back in. Banning deletes his messages, so the
/// stand-in has none of his until it starts again.
extension LiveTests {
    /// A small square PNG of one colour.
    func squarePNG(side: Int = 96) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Tomás, from the directory: the seeded person no other live test relies on.
    func tomas(on client: EmberClient) async throws -> DirectoryUser {
        try #require(try await client.directory().users.first { $0.name.hasPrefix("Tomás") })
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func changesTheProfileAndChangesItBack() async throws {
        let client = try await signedIn()
        let original = try await client.profile().profile
        #expect(!original.name.isEmpty)
        #expect(original.emailAddress != nil)
        #expect(original.hasPassword)

        let bio = "Live test \(UUID().uuidString.prefix(8))"
        try await afterwards({ _ = try await client.changeProfile(ProfileChanges(name: original.name, bio: original.bio ?? "")) }) {
            let changed = try await client.changeProfile(ProfileChanges(name: original.name + " Live", bio: bio)).profile
            #expect(changed.name == original.name + " Live")
            #expect(changed.bio == bio)
            #expect(try await client.me().name == original.name + " Live")

            // A new email address needs the password you have now.
            let error = await #expect(throws: EmberError.self) {
                try await client.changeProfile(ProfileChanges(emailAddress: "someone.else@example.com"))
            }
            #expect(error?.status == 422)
        }
        let restored = try await client.profile().profile
        #expect(restored.name == original.name)
        #expect(restored.bio == original.bio)
        #expect(restored.emailAddress == original.emailAddress)
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func changesAndRemovesTheAvatar() async throws {
        let client = try await signedIn()
        let original = try await client.profile().profile
        let png = try squarePNG()
        try await afterwards({ if try await client.profile().profile.hasAvatar != original.hasAvatar { _ = try await client.removeAvatar() } }) {
            let pictured = try await client.changeAvatar(png, filename: "live.png", contentType: "image/png").profile
            #expect(pictured.hasAvatar)
            #expect(pictured.avatarUrl != original.avatarUrl)
            let me = try await client.me()
            let listed = try await client.directory().users.first { $0.id == me.id }
            #expect(listed?.avatarUrl == pictured.avatarUrl)

            let removed = try await client.removeAvatar().profile
            #expect(!removed.hasAvatar)
        }
        #expect(try await client.profile().profile.hasAvatar == original.hasAvatar)
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aWorkspaceChangesTheProfileAndAvatarAndChangesThemBack() async throws {
        let client = try await signedIn()
        let original = try await client.profile().profile
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        let me = workspace.me.id
        let png = try squarePNG()

        try await afterwards({
            _ = try await client.changeProfile(ProfileChanges(name: original.name, bio: original.bio ?? ""))
            if try await client.profile().profile.hasAvatar != original.hasAvatar { _ = try await client.removeAvatar() }
        }) {
            let bio = "Workspace live test \(UUID().uuidString.prefix(8))"
            let changed = try await workspace.changeProfile(ProfileChanges(name: original.name + " Live", bio: bio))
            #expect(changed.name == original.name + " Live")
            #expect(workspace.me.name == original.name + " Live")
            #expect(workspace.person(me)?.name == original.name + " Live")
            #expect(workspace.person(me)?.bio == bio)

            let pictured = try await workspace.changeAvatar(png, contentType: "image/png")
            #expect(pictured.hasAvatar)
            #expect(workspace.person(me)?.avatarUrl == pictured.avatarUrl)

            let removed = try await workspace.removeAvatar()
            #expect(!removed.hasAvatar)
            #expect(workspace.person(me)?.avatarUrl == removed.avatarUrl)

            let restored = try await workspace.changeProfile(ProfileChanges(name: original.name, bio: original.bio ?? ""))
            #expect(restored.name == original.name)
            #expect(workspace.me.name == original.name)
        }
        let restored = try await client.profile().profile
        #expect(restored.name == original.name)
        #expect(restored.bio == original.bio)
        #expect(restored.hasAvatar == original.hasAvatar)
    }

    @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func anAdministratorSeesSomeonesDetails() async throws {
        let client = try await signedIn()
        let tomas = try await tomas(on: client)
        let details = try await client.person(tomas.id)
        #expect(details.user.id == tomas.id)
        #expect(details.user.name == tomas.name)
        #expect(details.emailAddress != nil)
        #expect(details.transferID != nil)

        // Someone who isn't an administrator sees neither.
        let sam = try await signedIn(as: "sam@example.com")
        let seen = try await sam.person(tomas.id)
        #expect(seen.user.id == tomas.id)
        #expect(seen.emailAddress == nil)
        #expect(seen.transferID == nil)
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func bansAndLetsBackIn() async throws {
        let client = try await signedIn()
        let tomas = try await tomas(on: client)
        try #require(tomas.status != .banned, "Tomás is banned already: start the stand-in again.")
        let tomasClient = try await signedIn(as: "tomas@example.com")
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }

        try await afterwards({ if workspace.person(tomas.id)?.status == .banned { try await workspace.unban(tomas.id) } }) {
            try await workspace.ban(tomas.id)
            #expect(workspace.person(tomas.id)?.status == .banned)
            #expect(workspace.bannedPeople.map(\.id) == [tomas.id])

            // His session has ended, and he can't sign in again.
            let signedOut = await #expect(throws: EmberError.self) { try await tomasClient.me() }
            #expect(signedOut?.isSignedOut == true)
            let refused = await #expect(throws: EmberError.self) { try await signedIn(as: "tomas@example.com") }
            #expect(refused?.status == 401)

            // Only administrators unban.
            let sam = try await signedIn(as: "sam@example.com")
            let forbidden = await #expect(throws: EmberError.self) { try await sam.unban(tomas.id) }
            #expect(forbidden?.status == 403)

            try await workspace.unban(tomas.id)
            #expect(workspace.person(tomas.id)?.status == .active)
            #expect(workspace.bannedPeople.isEmpty)
        }
        let back = try await signedIn(as: "tomas@example.com")
        #expect(try await back.me().id == tomas.id)
        #expect(try await client.directory().users.first { $0.id == tomas.id }?.status == .active)
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func theClientBansAndUnbans() async throws {
        let client = try await signedIn()
        let tomas = try await tomas(on: client)
        try #require(tomas.status != .banned, "Tomás is banned already: start the stand-in again.")
        var banned = false
        try await afterwards({ if banned { _ = try await client.unban(tomas.id) } }) {
            let after = try await client.ban(tomas.id)
            banned = true
            #expect(after.id == tomas.id)
            #expect(after.status == .banned)
            let again = try await client.unban(tomas.id)
            banned = false
            #expect(again.status == .active)
        }
    }
}
