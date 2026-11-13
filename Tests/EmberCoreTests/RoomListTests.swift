import Foundation
import Testing
@testable import EmberCore

// Ports of apps/web/src/lib/room-list.test.ts and directs.test.ts.

private func room(_ id: RoomID, _ name: String, unread: Bool = false, involvement: Involvement = .mentions) -> SidebarRoom {
    SidebarRoom(room: Room(id: id, kind: .open, name: name), unread: unread, involvement: involvement)
}

/// A DM between the people `names` names, ids their names lowercased, active `minutes` past noon.
private func direct(_ id: RoomID, _ names: String..., minutes: Int = 0, unread: Bool = false, involvement: Involvement = .everything) -> SidebarRoom {
    SidebarRoom(room: directRoom(id, names, minutes: minutes), unread: unread, involvement: involvement)
}

private func directRoom(_ id: RoomID, _ names: [String], minutes: Int = 0) -> Room {
    Room(id: id, kind: .direct, members: names.map { User(id: UserID($0.lowercased()), name: $0) }, activeAt: noon(minutes))
}

private let four = [room("r1", "Design"), room("r2", "general"), room("r3", "Ops"), room("r4", "Zebra")]

private func sidebar(_ rooms: [SidebarRoom], favorites: Favorites = Favorites(), invitation: Invitation? = nil) -> SidebarState {
    SidebarState(Sidebar(rooms: rooms, favorites: favorites, invitation: invitation))
}

private func sidebarJSON(_ rooms: String, favorites: String = #"{"rooms":[],"version":0}"#, invitation: String = "null") throws -> Sidebar {
    let text = #"{"rooms":\#(rooms),"favorites":\#(favorites),"sharedOrder":[],"invitation":\#(invitation),"suggestions":[]}"#
    return try EmberJSON.decoder().decode(Sidebar.self, from: Data(text.utf8))
}

@Suite struct RoomOrderTests {
    @Test func aNewRoomGoesLastAndTheSidebarPutsItInItsPlaceByName() {
        let rooms = RoomList.withRoom([room("r1", "Design"), room("r2", "general"), room("r3", "Zebra")], Room(id: "r4", kind: .open, name: "Finance"))
        #expect(rooms.map(\.room.name) == ["Design", "general", "Zebra", "Finance"])
        #expect(RoomList.shared(rooms, favorites: [], sharedOrder: []).map(\.room.name) == ["Design", "Finance", "general", "Zebra"])
    }

    @Test func aRenamedRoomKeepsItsPlaceAndTheSidebarMovesIt() {
        let rooms = RoomList.withRoom([room("r1", "Design"), room("r2", "general")], Room(id: "r1", kind: .open, name: "Product design"))
        #expect(rooms == [room("r1", "Product design"), room("r2", "general")])
        #expect(RoomList.shared(rooms, favorites: [], sharedOrder: []) == [room("r2", "general"), room("r1", "Product design")])
    }

    @Test func starredFirstInStarOrder() {
        #expect(RoomList.shared(four, favorites: ["r4", "r2"], sharedOrder: []).map(\.room.name) == ["Zebra", "general", "Design", "Ops"])
        #expect(RoomList.shared(four, favorites: ["gone", "r3"], sharedOrder: []).map(\.room.name) == ["Ops", "Design", "general", "Zebra"])
    }

    @Test func namesWhateverTheirCaseThenId() {
        let rooms = [room("r4", "zed"), room("r2", "alpha"), room("r3", "Éclair"), room("r1", "ALPHA")]
        #expect(RoomList.shared(rooms, favorites: [], sharedOrder: []).map(\.id) == ["r1", "r2", "r3", "r4"])
    }

    @Test func sharedOrderAfterStars() {
        #expect(RoomList.shared(four, favorites: ["r4"], sharedOrder: ["r3", "r4", "r2"]).map(\.room.name) == ["Zebra", "Ops", "general", "Design"])
        #expect(RoomList.shared(four, favorites: [], sharedOrder: ["gone", "r2"]).map(\.room.name) == ["general", "Design", "Ops", "Zebra"])
    }

    @Test func dmsApartAndHiddenLeftOut() {
        let rooms = [
            direct("d1", "Ada", "Grace"), room("r1", "Design", involvement: .invisible), direct("d2", "Ada"),
            room("r2", "general"), direct("d3", "Linus", involvement: .invisible),
        ]
        #expect(RoomList.shared(rooms, favorites: ["r1"], sharedOrder: []).map(\.id) == ["r2"])
        #expect(RoomList.directs(rooms).map(\.id) == ["d2", "d1"])
    }

    @Test func dmsLatestActiveFirstAndOfTwoAtOnceTheLaterMade() {
        let directs = [direct("d1", "Ada", minutes: 1), direct("d2", "Grace", minutes: 3), direct("d3", "Linus", minutes: 2), direct("d4", "Alan", minutes: 3)]
        #expect(RoomList.directs(directs).map(\.id) == ["d4", "d2", "d3", "d1"])
    }

    @Test func markedUnreadUnlessOnScreenOrHidden() {
        #expect(RoomList.isMarkedUnread(room("r1", "Design", unread: true), currentRoomID: nil))
        #expect(RoomList.isMarkedUnread(room("r1", "Design", unread: true), currentRoomID: "r2"))
        #expect(!RoomList.isMarkedUnread(room("r1", "Design", unread: true), currentRoomID: "r1"))
        #expect(!RoomList.isMarkedUnread(room("r1", "Design"), currentRoomID: nil))
        #expect(!RoomList.isMarkedUnread(room("r1", "Design", unread: true, involvement: .invisible), currentRoomID: nil))
        #expect(RoomList.isMarkedUnread(room("r1", "Design", unread: true, involvement: .nothing), currentRoomID: nil))
    }

    @Test func savingKeepsTheMarkAndLevelAndANewRoomStartsRead() {
        let marked = [room("r1", "Design", unread: true, involvement: .everything), room("r2", "general", unread: true)]
        #expect(RoomList.withRoom(marked, Room(id: "r1", kind: .open, name: "Product design")).first
            == room("r1", "Product design", unread: true, involvement: .everything))
        #expect(RoomList.withRoom(marked, Room(id: "r3", kind: .open, name: "Finance")).last == room("r3", "Finance"))
        #expect(RoomList.withRoom(marked, Room(id: "r4", kind: .closed, name: "Ops")).last?.involvement == .mentions)
        #expect(RoomList.withRoom([], directRoom("d2", ["Grace"])).first?.involvement == .everything)
    }

    @Test func aDMSavedAgainKeepsItsMarkAndTheLaterTime() {
        let rooms = RoomList.withRoom([room("r1", "Design")], directRoom("d1", ["Ada"]))
        #expect(rooms == [room("r1", "Design"), direct("d1", "Ada")])
        let marked = [direct("d1", "Ada", minutes: 5, unread: true)]
        #expect(RoomList.withRoom(marked, directRoom("d1", ["Ada"], minutes: 1)) == marked)
        #expect(RoomList.withRoom(marked, directRoom("d1", ["Ada"], minutes: 7)) == [direct("d1", "Ada", minutes: 7, unread: true)])
    }

    @Test func suggestedPeople() {
        let people = ["Grace", "Linus", "Alan"].map { User(id: UserID($0.lowercased()), name: $0) }
        let many = (0 ..< 20).map { User(id: "p\($0)", name: "Person \($0)") }
        #expect(RoomList.suggestedPeople(people, rooms: [room("r1", "Design")]) == people)
        #expect(RoomList.suggestedPeople(people, rooms: [room("r1", "Design"), direct("d1", "Ada", "Linus")]) == [people[0], people[2]])
        #expect(RoomList.suggestedPeople(many, rooms: []).count == 19)
        #expect(RoomList.suggestedPeople(many, rooms: [direct("d1", "Ada")]).count == 18)
        #expect(RoomList.suggestedPeople(many, rooms: [direct("d1", "Ada", "Grace"), direct("d2", "Ada", "Grace", "Linus")]).count == 16)
    }

    @Test func suggestedPeopleLeaveOutAnyoneTheDirectoryHasAsNotActive() {
        let people = ["Grace", "Linus", "Alan", "Edsger", "Barbara"].map { User(id: UserID($0.lowercased()), name: $0) }
        let statuses: [UserStatus] = [.active, .banned, .deactivated, .suspended, .unknown("frozen")]
        let directory = Dictionary(uniqueKeysWithValues: zip(people, statuses).map { ($0.id, DirectoryUser(id: $0.id, name: $0.name, status: $1, avatarUrl: "")) })
        #expect(RoomList.suggestedPeople(people, rooms: [], people: directory) == [people[0]])
        // Someone the directory doesn't have yet counts as active.
        #expect(RoomList.suggestedPeople(people, rooms: [], people: [:]) == people)

        // Those left out don't take up the places of those suggested.
        let many = (0 ..< 25).map { User(id: "p\($0)", name: "Person \($0)") }
        let banned = Dictionary(uniqueKeysWithValues: many.prefix(5).map { ($0.id, DirectoryUser(id: $0.id, name: $0.name, status: .banned, avatarUrl: "")) })
        #expect(RoomList.suggestedPeople(many, rooms: [], people: banned) == Array(many[5 ..< 24]))
    }
}

@Suite struct DirectNamingTests {
    let people = ["Ada", "Grace", "Linus", "Alan"].enumerated().map { User(id: "u\($0.offset + 1)", name: $0.element) }

    func dm(_ members: User...) -> Room { Room(id: "d1", kind: .direct, members: members, activeAt: noon()) }

    @Test func sentences() {
        #expect(RoomList.sentence([]) == "")
        #expect(RoomList.sentence(["Ada"]) == "Ada")
        #expect(RoomList.sentence(["Ada", "Grace"]) == "Ada and Grace")
        #expect(RoomList.sentence(["Ada", "Grace", "Linus"]) == "Ada, Grace, and Linus")
        #expect(RoomList.sentence(["Ada", "Grace", "Linus", "Alan"]) == "Ada, Grace, Linus, and Alan")
    }

    @Test func dmNames() {
        let (ada, grace, linus, alan) = (people[0], people[1], people[2], people[3])
        #expect(RoomList.name(of: dm(ada, grace), me: ada.id, nameOf: \.name) == "Grace")
        #expect(RoomList.name(of: dm(ada, grace, linus, alan), me: grace.id, nameOf: \.name) == "Ada, Linus, and Alan")
        #expect(RoomList.name(of: dm(ada), me: ada.id, nameOf: \.name) == "Ada")
        #expect(RoomList.name(of: dm(ada, grace), me: ada.id) { $0.id == grace.id ? "Grace Hopper" : $0.name } == "Grace Hopper")
        #expect(RoomList.name(of: Room(id: "r1", kind: .open, name: "general"), me: ada.id, nameOf: \.name) == "general")
    }

    @Test func membersShown() {
        let (ada, grace, linus) = (people[0], people[1], people[2])
        #expect(RoomList.membersShown(dm(ada, grace, linus), me: grace.id) == [ada, linus])
        #expect(RoomList.membersShown(dm(ada), me: ada.id) == [ada])
    }

    @Test func soughtName() {
        #expect(RoomList.soughtName("  @@ada ") == "ada")
        #expect(RoomList.soughtName("@ Grace Hopper") == "Grace Hopper")
        #expect(RoomList.soughtName("a@b") == "a@b")
        #expect(RoomList.soughtName("") == "")
    }

    @Test func peopleMatching() {
        let directory = [
            DirectoryUser(id: "u3", name: "adam", avatarUrl: ""),
            DirectoryUser(id: "u1", name: "Ada", avatarUrl: ""),
            DirectoryUser(id: "u2", name: "ADA", avatarUrl: ""),
            DirectoryUser(id: "u4", name: "Madalyn", role: .bot, avatarUrl: ""),
            DirectoryUser(id: "u5", name: "Adele", status: .deactivated, avatarUrl: ""),
            DirectoryUser(id: "u6", name: "ÁDA", avatarUrl: ""),
            DirectoryUser(id: "me", name: "Ada Me", avatarUrl: ""),
        ]
        #expect(RoomList.peopleMatching(directory, me: "me", name: "Ada").map(\.id) == ["u1", "u2", "u3", "u4"])
        #expect(RoomList.peopleMatching(directory, me: "me", name: "").map(\.id) == ["u1", "u2", "u3", "u4", "u6"])
    }
}

@Suite struct SidebarStateTests {
    @Test func takesTheSidebar() throws {
        let state = SidebarState(try sidebarJSON(
            #"[{"id":"r1","kind":"open","name":"general","icon":null,"unread":true,"involvement":"everything"}]"#,
            favorites: #"{"rooms":["r1"],"version":2}"#, invitation: #"{"roomId":"r1","joinCode":"aB3d"}"#
        ))
        #expect(state.rooms == [room("r1", "general", unread: true, involvement: .everything)])
        #expect(state.favorites == Favorites(rooms: ["r1"], version: 2))
        #expect(state.invitation == Invitation(roomId: "r1", joinCode: "aB3d"))
        #expect(SidebarState().rooms.isEmpty && SidebarState().favorites == Favorites())
    }

    @Test func welcomeAndReorderedFetchAgain() {
        var state = sidebar(four)
        let before = state
        let fetched1 = state.apply(.welcome(you: Me(id: "u1", name: "Ada", administrator: false), account: Account(name: "Acme")))
        #expect(fetched1)
        let fetched2 = state.apply(.roomsReordered)
        #expect(fetched2)
        #expect(state == before)
    }

    @Test func framesThatChangeNothingFetchNothing() {
        var state = sidebar(four)
        let before = state
        for frame: WorkspaceFrame in [
            .userUpdated(DirectoryUser(id: "u2", name: "Grace", avatarUrl: "")), .accountUpdated(Account(name: "Acme")),
            .error("No"), .pong, .unknown("future"),
        ] {
            let fetched3 = state.apply(frame)
            #expect(!fetched3)
        }
        #expect(state == before)
    }

    @Test func marksUnreadAndRead() {
        var state = sidebar([room("r1", "Design"), room("r2", "general", unread: true)])
        let fetched4 = state.apply(.roomUnread("r1"))
        #expect(!fetched4)
        #expect(state.rooms == [room("r1", "Design", unread: true), room("r2", "general", unread: true)])
        let fetched5 = state.apply(.roomRead("r2"))
        #expect(!fetched5)
        state.markRead("r1")
        #expect(state.rooms == [room("r1", "Design"), room("r2", "general")])
    }

    @Test func savedAndGone() {
        var state = sidebar(four, favorites: Favorites(rooms: ["r1", "r3"], version: 2))
        let fetched6 = state.apply(.roomSaved(Room(id: "r1", kind: .open, name: "Product design")))
        #expect(!fetched6)
        #expect(state.rooms.first == room("r1", "Product design"))
        state.add(Room(id: "r5", kind: .closed, name: "Finance"))
        #expect(state.rooms.last == SidebarRoom(room: Room(id: "r5", kind: .closed, name: "Finance")))
        let fetched7 = state.apply(.roomGone("r1"))
        #expect(!fetched7)
        #expect(state.rooms.map(\.id) == ["r2", "r3", "r4", "r5"])
        #expect(state.favorites == Favorites(rooms: ["r3"], version: 2))
        state.apply(.roomGone("r2"))
        #expect(state.favorites == Favorites(rooms: ["r3"], version: 2))
    }

    @Test func activeMovesOnlyADMAndOnlyLater() {
        var state = sidebar([room("r1", "Design"), direct("d1", "Ada", minutes: 1), direct("d2", "Ada", "Grace", minutes: 2)])
        let fetched8 = state.apply(.roomActive("d1", at: noon(5)))
        #expect(!fetched8)
        #expect(state.rooms[1] == direct("d1", "Ada", minutes: 5))
        let moved = state
        state.apply(.roomActive("d1", at: noon(4)))
        state.apply(.roomActive("r1", at: noon(6)))
        state.apply(.roomActive("d9", at: noon(6)))
        #expect(state == moved)
    }

    @Test func involvement() {
        var state = sidebar([room("r1", "Design"), direct("d1", "Ada")])
        let fetched9 = state.apply(.roomInvolvement("r1", .everything))
        #expect(!fetched9)
        state.setInvolvement(.nothing, roomID: "d1")
        #expect(state.rooms == [room("r1", "Design", involvement: .everything), direct("d1", "Ada", involvement: .nothing)])
    }

    @Test func theNewestStarsStand() {
        var state = sidebar(four, favorites: Favorites(rooms: ["r1"], version: 2))
        let fetched10 = state.apply(.favoritesChanged(Favorites(rooms: ["r1", "r2"], version: 3)))
        #expect(!fetched10)
        #expect(state.favorites == Favorites(rooms: ["r1", "r2"], version: 3))
        state.setFavorites(Favorites(rooms: ["r1"], version: 2))
        state.apply(.favoritesChanged(Favorites(rooms: ["r2"], version: 3)))
        #expect(state.favorites == Favorites(rooms: ["r1", "r2"], version: 3))
    }

    @Test func invitationDismissed() {
        var state = sidebar(four, invitation: Invitation(roomId: "r1", joinCode: "aB3d"))
        let fetched11 = state.apply(.invitationDismissed)
        #expect(!fetched11)
        #expect(state.invitation == nil)
        #expect(state.rooms == four)
    }

    @Test func userUpdatedFetchesForMyNewRoleOrSomeoneBack() {
        var state = sidebar(four)
        let me = Me(id: "u1", name: "Ada", administrator: false)
        let directory = [
            DirectoryUser(id: "u1", name: "Ada", avatarUrl: ""),
            DirectoryUser(id: "u2", name: "Grace", status: .suspended, avatarUrl: ""),
            DirectoryUser(id: "u3", name: "Linus", avatarUrl: ""),
        ]
        let fetched12 = state.apply(.userUpdated(DirectoryUser(id: "u1", name: "Ada", role: .administrator, avatarUrl: "")), me: me, directory: directory)
        #expect(fetched12)
        let fetched13 = state.apply(.userUpdated(DirectoryUser(id: "u1", name: "Ada L", avatarUrl: "")), me: me, directory: directory)
        #expect(!fetched13)
        let fetched14 = state.apply(.userUpdated(DirectoryUser(id: "u1", name: "Ada", avatarUrl: "")), me: Me(id: "u1", name: "Ada", administrator: true), directory: directory)
        #expect(fetched14)
        let fetched15 = state.apply(.userUpdated(DirectoryUser(id: "u2", name: "Grace", avatarUrl: "")), me: me, directory: directory)
        #expect(fetched15)
        let fetched16 = state.apply(.userUpdated(DirectoryUser(id: "u3", name: "Linus T", avatarUrl: "")), me: me, directory: directory)
        #expect(!fetched16)
        let fetched17 = state.apply(.userUpdated(DirectoryUser(id: "u9", name: "New", avatarUrl: "")), me: me, directory: directory)
        #expect(!fetched17)
        let fetched18 = state.apply(.userUpdated(DirectoryUser(id: "u3", name: "Linus", status: .banned, avatarUrl: "")), me: me, directory: directory)
        #expect(!fetched18)
        let fetched19 = state.apply(.roomsReordered, me: me, directory: directory)
        #expect(fetched19)
        #expect(state.rooms == four)
    }

    @Test func changesWhileASidebarIsOnItsWayAreKeptOverIt() throws {
        let list = try sidebarJSON(
            #"[{"id":"r1","kind":"open","name":"Design","icon":null,"unread":false,"involvement":"mentions"},{"id":"r2","kind":"open","name":"general","icon":null,"unread":true,"involvement":"mentions"},{"id":"d1","kind":"direct","members":[{"id":"ada","name":"Ada"}],"activeAt":"2026-10-12T12:01:00.000Z","unread":false,"involvement":"everything"}]"#,
            invitation: #"{"roomId":"r1","joinCode":"aB3d"}"#
        )
        var state = SidebarState(list)
        state.willLoad()
        state.apply(.roomSaved(Room(id: "r3", kind: .open, name: "Finance")))
        state.apply(.roomSaved(Room(id: "r1", kind: .open, name: "Product design")))
        state.markRead("r2")
        state.apply(.roomActive("d1", at: noon(5)))
        state.apply(.roomInvolvement("d1", .nothing))
        state.apply(.favoritesChanged(Favorites(rooms: ["r3"], version: 1)))
        state.apply(.invitationDismissed)
        state.loaded(list)
        #expect(state.rooms.map(\.id) == ["r1", "r2", "d1", "r3"])
        #expect(state.rooms[0].room.name == "Product design")
        #expect(!state.rooms[1].unread)
        #expect(state.rooms[2] == direct("d1", "Ada", minutes: 5, involvement: .nothing))
        #expect(state.favorites == Favorites(rooms: ["r3"], version: 1))
        #expect(state.invitation == nil)

        // Loaded, it stops keeping changes; a later sidebar replaces it outright.
        state.apply(.roomGone("r3"))
        state.loaded(list)
        #expect(state == SidebarState(list))
    }

    @Test func aRoomGoneBeforeTheSidebarArrivesStaysGone() throws {
        let list = try sidebarJSON(#"[{"id":"r1","kind":"open","name":"Design","icon":null},{"id":"r2","kind":"open","name":"general","icon":null}]"#)
        var state = SidebarState()
        state.willLoad()
        state.apply(.roomGone("r1"))
        state.loaded(list)
        #expect(state.rooms.map(\.id) == ["r2"])
    }

    @Test func aSidebarThatDoesntArriveKeepsTheOneThereIs() {
        var state = sidebar(four)
        state.willLoad()
        state.apply(.roomUnread("r1"))
        state.unanswered()
        #expect(state.rooms.first?.unread == true)
        #expect(state.rooms.count == 4)
    }
}

@Suite struct FavoriteGuessTests {
    @Test func aStarShowsAtOnceAndAnAnswerTakesItsPlace() {
        var state = sidebar(four, favorites: Favorites(rooms: ["r1"], version: 1))
        let guess = state.beginFavorite(true, roomID: "r2")
        #expect(state.favorites == Favorites(rooms: ["r1", "r2"], version: 1))
        state.acceptFavorite(guess, favorites: Favorites(rooms: ["r1", "r2"], version: 2))
        #expect(state.favorites == Favorites(rooms: ["r1", "r2"], version: 2))
    }

    @Test func aRefusedStarGoesBackToTheServersStars() {
        var state = sidebar(four, favorites: Favorites(rooms: ["r1"], version: 1))
        let guess = state.beginFavorite(false, roomID: "r1")
        #expect(state.favorites.rooms.isEmpty)
        // Stars from elsewhere arrive meanwhile: refusing the guess shows them, not the stars before it.
        state.apply(.favoritesChanged(Favorites(rooms: ["r1", "r3"], version: 2)))
        #expect(state.favorites.rooms == ["r3"])
        state.rejectFavorite(guess)
        #expect(state.favorites == Favorites(rooms: ["r1", "r3"], version: 2))
    }

    @Test func aStarSurvivesASidebarLandingBeforeItsAnswer() {
        var state = sidebar(four, favorites: Favorites(rooms: ["r1"], version: 1))
        state.willLoad()
        let guess = state.beginFavorite(true, roomID: "r4")
        state.loaded(Sidebar(rooms: four, favorites: Favorites(rooms: ["r1"], version: 1)))
        #expect(state.favorites.rooms == ["r1", "r4"])
        // And a sidebar asked for after the star, landing before its answer.
        state.willLoad()
        state.loaded(Sidebar(rooms: four, favorites: Favorites(rooms: ["r1"], version: 1)))
        #expect(state.favorites.rooms == ["r1", "r4"])
        state.acceptFavorite(guess, favorites: Favorites(rooms: ["r1", "r4"], version: 2))
        #expect(state.favorites == Favorites(rooms: ["r1", "r4"], version: 2))

        let unstar = state.beginFavorite(false, roomID: "r4")
        state.willLoad()
        state.loaded(Sidebar(rooms: four, favorites: Favorites(rooms: ["r1", "r4"], version: 2)))
        state.rejectFavorite(unstar)
        #expect(state.favorites == Favorites(rooms: ["r1", "r4"], version: 2))
    }

    @Test func anOlderAnswerDoesntUndoANewerOne() {
        var state = sidebar(four, favorites: Favorites(rooms: [], version: 1))
        let star = state.beginFavorite(true, roomID: "r1")
        let unstar = state.beginFavorite(false, roomID: "r1")
        #expect(state.favorites.rooms.isEmpty)
        state.acceptFavorite(unstar, favorites: Favorites(rooms: [], version: 3))
        state.acceptFavorite(star, favorites: Favorites(rooms: ["r1"], version: 2))
        #expect(state.favorites == Favorites(rooms: [], version: 3))
    }

    @Test func aRoomThatsGoneTakesItsGuessWithIt() {
        var state = sidebar(four)
        _ = state.beginFavorite(true, roomID: "r2")
        state.apply(.roomGone("r2"))
        #expect(state.favorites.rooms.isEmpty)
    }
}
