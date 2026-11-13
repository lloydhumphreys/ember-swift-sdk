import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// Your profile and bans as the workspace shows them: at once, before the socket says so, and the
/// sidebar's suggestions leaving out whoever is banned, deactivated or suspended.
@MainActor @Suite struct WorkspacePeopleTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let workspace: Workspace

    init() {
        let (timing, _) = manualTiming()
        workspace = Workspace.mock(transport: transport, connector: connector, timing: timing)
    }

    func started() async throws {
        workspace.start()
        try #require(await eventually { workspace.isLoaded && workspace.person(Fixtures.grace.id) != nil })
    }

    // MARK: Profile

    @Test func aChangedProfileShowsAtOnce() async throws {
        try await started()
        let saved = UserProfile(name: "Ada King", emailAddress: "ada@example.com", bio: "Countess", avatarUrl: "/users/user_ada/avatar?v=1")
        transport.stub("PATCH", "/api/users/me/profile", json: Fixtures.profileJSON(saved))
        let profile = try await workspace.changeProfile(ProfileChanges(name: "Ada King", bio: "Countess"))
        #expect(profile == saved)
        #expect(transport.lastBody("PATCH", "/api/users/me/profile")?["name"] as? String == "Ada King")
        #expect(workspace.me.name == "Ada King")
        #expect(workspace.me.administrator)
        #expect(workspace.person(Fixtures.me.id)?.name == "Ada King")
        #expect(workspace.person(Fixtures.me.id)?.bio == "Countess")
        #expect(workspace.name(ofUserID: Fixtures.me.id) == "Ada King")
    }

    @Test func aRefusedProfileChangesNothing() async throws {
        try await started()
        transport.stub("PATCH", "/api/users/me/profile", status: 422, json: Fixtures.errorJSON("Name can’t be blank"))
        await #expect(throws: EmberError(status: 422, message: "Name can’t be blank")) {
            try await workspace.changeProfile(ProfileChanges(name: ""))
        }
        #expect(workspace.me.name == Fixtures.me.name)
        #expect(workspace.person(Fixtures.me.id)?.name == Fixtures.me.name)
    }

    @Test func aNewAvatarShowsAtOnce() async throws {
        try await started()
        let saved = UserProfile(name: Fixtures.me.name, bio: "Poet of numbers", avatarUrl: "/users/user_ada/avatar?v=2", hasAvatar: true)
        transport.stub("PUT", "/api/users/me/avatar", json: Fixtures.profileJSON(saved))
        let profile = try await workspace.changeAvatar(Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")
        #expect(profile.hasAvatar)
        #expect(workspace.avatarPath(for: Fixtures.me.id) == "/users/user_ada/avatar?v=2")
    }

    @Test func aRemovedAvatarShowsAtOnce() async throws {
        try await started()
        let saved = UserProfile(name: Fixtures.me.name, bio: "Poet of numbers", avatarUrl: "/users/user_ada/avatar?v=3")
        transport.stub("DELETE", "/api/users/me/avatar", json: Fixtures.profileJSON(saved))
        let profile = try await workspace.removeAvatar()
        #expect(!profile.hasAvatar)
        #expect(workspace.avatarPath(for: Fixtures.me.id) == "/users/user_ada/avatar?v=3")
    }

    // MARK: Bans

    @Test func someoneBannedIsListedAtOnceAndUnbannedIsnt() async throws {
        try await started()
        #expect(workspace.bannedPeople.isEmpty)
        var grace = try #require(workspace.person(Fixtures.grace.id))
        grace.status = .banned
        transport.stub("POST", "/api/users/user_grace/ban", json: Fixtures.changedPersonJSON(grace))
        try await workspace.ban(Fixtures.grace.id)
        #expect(workspace.person(Fixtures.grace.id)?.status == .banned)
        #expect(workspace.bannedPeople.map(\.id) == [Fixtures.grace.id])

        // The socket's user.updated agrees and changes nothing.
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(grace))
        #expect(workspace.bannedPeople.map(\.id) == [Fixtures.grace.id])

        grace.status = .active
        transport.stub("DELETE", "/api/users/user_grace/ban", json: Fixtures.changedPersonJSON(grace))
        try await workspace.unban(Fixtures.grace.id)
        #expect(workspace.person(Fixtures.grace.id)?.status == .active)
        #expect(workspace.bannedPeople.isEmpty)
    }

    @Test func aRefusedBanBansNobody() async throws {
        try await started()
        transport.stub("POST", "/api/users/user_grace/ban", status: 403, json: Fixtures.errorJSON("Only administrators can ban people"))
        await #expect(throws: EmberError(status: 403, message: "Only administrators can ban people")) {
            try await workspace.ban(Fixtures.grace.id)
        }
        #expect(workspace.person(Fixtures.grace.id)?.status == .active)
        #expect(workspace.bannedPeople.isEmpty)
    }

    @Test func bannedPeopleGoByName() async throws {
        try await started()
        for user in [Fixtures.grace, Fixtures.alan] {
            var person = try #require(workspace.person(user.id))
            person.status = .banned
            connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(person))
        }
        #expect(await eventually { workspace.bannedPeople.count == 2 })
        #expect(workspace.bannedPeople.map(\.name) == [Fixtures.alan.name, Fixtures.grace.name])
    }

    // MARK: Suggestions

    /// The sidebar suggests Grace and Alan; Grace has a DM already, so Alan is the one suggested.
    func suggestingAlan() async throws {
        try await started()
        try #require(workspace.suggestedPeople.map(\.id) == [Fixtures.alan.id])
    }

    @Test func someoneBannedIsntSuggestedAndIsAgainOnceLetBackIn() async throws {
        try await suggestingAlan()
        var alan = try #require(workspace.person(Fixtures.alan.id))
        alan.status = .banned
        transport.stub("POST", "/api/users/user_alan/ban", json: Fixtures.changedPersonJSON(alan))
        try await workspace.ban(Fixtures.alan.id)
        #expect(workspace.suggestedPeople.isEmpty)
        #expect(workspace.suggestions.map(\.id).contains(Fixtures.alan.id))

        alan.status = .active
        transport.stub("DELETE", "/api/users/user_alan/ban", json: Fixtures.changedPersonJSON(alan))
        try await workspace.unban(Fixtures.alan.id)
        #expect(workspace.suggestedPeople.map(\.id) == [Fixtures.alan.id])
    }

    @Test func someoneTheSocketSaysIsBannedOrDeactivatedIsntSuggested() async throws {
        try await suggestingAlan()
        var alan = try #require(workspace.person(Fixtures.alan.id))
        for status: UserStatus in [.banned, .deactivated, .suspended, .unknown("frozen")] {
            alan.status = status
            connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(alan))
            #expect(await eventually { workspace.suggestedPeople.isEmpty }, "\(status.rawValue)")

            alan.status = .active
            connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(alan))
            #expect(await eventually { workspace.suggestedPeople.map(\.id) == [Fixtures.alan.id] })
        }
    }

    @Test func aDirectoryAnswerOnItsWayDoesntUndoWhatTheSocketSaid() async throws {
        try await suggestingAlan()
        // The answer still has Alan active.
        let gate = transport.hold("GET", "/api/users")
        let reloading = Task { await workspace.reloadDirectory() }
        await gate.waitForRequest()
        var alan = try #require(workspace.person(Fixtures.alan.id))
        alan.status = .banned
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(alan))
        #expect(await eventually { workspace.person(Fixtures.alan.id)?.status == .banned })
        gate.release()
        await reloading.value
        #expect(workspace.person(Fixtures.alan.id)?.status == .banned)
        #expect(workspace.bannedPeople.map(\.id) == [Fixtures.alan.id])
        #expect(workspace.suggestedPeople.isEmpty)
    }

    @Test func aSidebarSuggestingSomeoneTheDirectoryHasAsBannedLeavesThemOut() async throws {
        var people = Fixtures.people
        let index = try #require(people.firstIndex { $0.id == Fixtures.alan.id })
        people[index].status = .banned
        transport.stub("GET", "/api/users", json: Fixtures.directoryJSON(people))
        try await started()
        #expect(await eventually { workspace.person(Fixtures.alan.id)?.status == .banned })
        #expect(workspace.suggestions.map(\.id).contains(Fixtures.alan.id))
        #expect(workspace.suggestedPeople.isEmpty)
    }

    @Test func aChangeToSomeoneNotSuggestedDoesntSortTheSuggestionsAgain() async throws {
        try await suggestingAlan()
        let sorts = workspace.sortCount
        var grace = try #require(workspace.person(Fixtures.grace.id))
        grace.bio = "Admiral"
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(grace))
        #expect(await eventually { workspace.person(Fixtures.grace.id)?.bio == "Admiral" })
        #expect(workspace.sortCount == sorts)
    }
}
