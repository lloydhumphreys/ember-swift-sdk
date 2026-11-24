import Foundation
import Testing
@testable import EmberCore

// Ports of the section cases in apps/web/src/lib/room-list.test.ts and the worker's
// workspace-store.test.ts, and what else a client owes the sidebar's sections.

private func room(_ id: RoomID, _ name: String, kind: RoomKind = .open, unread: Bool = false, mentions: Int? = nil) -> SidebarRoom {
    SidebarRoom(room: Room(id: id, kind: kind, name: name), unread: unread, mentionCount: mentions)
}

private let rooms = [room("a", "Alpha"), room("b", "Beta"), room("c", "Gamma"), room("d", "Delta")]

private let product = RoomSection(id: "s1", name: "Product")
private let company = RoomSection(id: "s2", name: "Company")

/// Product with Alpha and Beta in it, Company with Gamma, and Delta in neither.
private let sections = [
    SidebarSection(id: "s1", name: "Product", roomIds: ["a", "b"]),
    SidebarSection(id: "s2", name: "Company", roomIds: ["c"]),
]

private func state(sections: [SidebarSection] = sections, favorites: [RoomID] = [], sharedOrder: [RoomID] = []) -> SidebarState {
    SidebarState(Sidebar(rooms: rooms, favorites: Favorites(rooms: favorites, version: 1), sharedOrder: sharedOrder, sections: sections))
}

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try EmberJSON.decoder().decode(type, from: Data(json.utf8))
}

private func encoded(_ value: some Encodable) throws -> JSONValue? {
    json(String(decoding: try EmberJSON.encoder().encode(value), as: UTF8.self))
}

private func ids(_ sections: [SidebarSection]) -> [[String]] {
    sections.map { [$0.id.rawValue] + $0.roomIds.map(\.rawValue) }
}

@Suite struct SectionModelTests {
    @Test func theSidebarListsItsSections() throws {
        let sidebar = try decoded(Sidebar.self, #"""
        {"rooms":[{"id":"a","kind":"open","name":"Alpha"}],"favorites":{"rooms":[],"version":0},"sharedOrder":["a"],
         "sections":[{"id":"s1","name":"Product","roomIds":["a"]},{"id":"s2","name":"Company","roomIds":[]},{"name":"No id"}],"invitation":null}
        """#)
        #expect(sidebar.sections == [SidebarSection(id: "s1", name: "Product", roomIds: ["a"]), SidebarSection(id: "s2", name: "Company")])
        #expect(sidebar.sections[0].section == product)
        // A server from before sections lists none.
        let older = try decoded(Sidebar.self, #"{"rooms":[],"favorites":{"rooms":[],"version":0},"sharedOrder":[],"invitation":null}"#)
        #expect(older.sections.isEmpty)
    }

    @Test func aSectionReadsWithWhatItHas() throws {
        #expect(try decoded(SidebarSection.self, #"{"id":"s1"}"#) == SidebarSection(id: "s1", name: ""))
        #expect(try decoded(SidebarSection.self, #"{"id":"s1","name":"Product","roomIds":"a"}"#) == SidebarSection(id: "s1", name: "Product"))
        #expect(try decoded(SectionOption.self, #"{"id":"s1","name":"Product","rooms":3}"#) == SectionOption(id: "s1", name: "Product", rooms: 3))
        #expect(try decoded(SectionOption.self, #"{"id":"s1","rooms":"three"}"#) == SectionOption(id: "s1", name: ""))
        #expect(SectionOption(id: "s1", name: "Product", rooms: 3).section == product)
        #expect(try decoded(RoomSection.self, #"{"id":"s1","name":"Product"}"#) == product)
    }

    @Test func aSectionChoiceGoesAsItsIdNullOrAName() throws {
        #expect(try encoded(["section": SectionChoice.section("s1")]) == json(#"{"section":"s1"}"#))
        #expect(try encoded(["section": SectionChoice.noSection]) == json(#"{"section":null}"#))
        #expect(try encoded(["section": SectionChoice.new(name: "Launch")]) == json(#"{"section":{"name":"Launch"}}"#))
    }

    @Test func aRoomsBodySaysItsSectionOnlyWhenAsked() throws {
        #expect(try encoded(RoomBody(name: "Annex", icon: nil, access: .open)) == json(#"{"name":"Annex","kind":"open"}"#))
        #expect(try encoded(RoomBody(name: "Annex", icon: nil, access: .closed(memberIDs: ["u1"]), section: .section("s1")))
            == json(#"{"name":"Annex","kind":"closed","memberIds":["u1"],"section":"s1"}"#))
        // Null takes it out of its section, which leaving the key out wouldn't.
        #expect(try encoded(RoomBody(name: nil, icon: nil, access: nil, section: .noSection)) == json(#"{"section":null}"#))
        #expect(try encoded(RoomBody(name: nil, icon: nil, access: nil, section: .new(name: "Launch"))) == json(#"{"section":{"name":"Launch"}}"#))
        #expect(try encoded(RoomBody(name: nil, icon: nil, access: nil, channelMentions: false)) == json(#"{"channelMentions":false}"#))
    }

    @Test func aLayoutSaysItsSectionsOnlyWhenItHasThem() throws {
        #expect(try encoded(RoomLayout(roomIds: ["b", "a"])) == json(#"{"roomIds":["b","a"]}"#))
        let layout = RoomLayout(roomIds: ["b", "a", "c"], sections: [RoomLayout.Placement(id: "s2", roomIds: ["c"]), RoomLayout.Placement(id: "s1", roomIds: [])])
        #expect(try encoded(layout) == json(#"{"roomIds":["b","a","c"],"sections":[{"id":"s2","roomIds":["c"]},{"id":"s1","roomIds":[]}]}"#))
    }

    @Test func aSavedLayoutReadsWithOrWithoutSections() throws {
        #expect(try decoded(SavedRoomLayout.self, #"{"sharedOrder":["b","a"],"sections":[{"id":"s1","name":"Product","roomIds":["b"]}]}"#)
            == SavedRoomLayout(sharedOrder: ["b", "a"], sections: [SidebarSection(id: "s1", name: "Product", roomIds: ["b"])]))
        #expect(try decoded(SavedRoomLayout.self, #"{"sharedOrder":["b","a"]}"#) == SavedRoomLayout(sharedOrder: ["b", "a"]))
        #expect(try decoded(SavedRoomLayout.self, "{}") == SavedRoomLayout(sharedOrder: []))
    }

    @Test func aMembersChangeListsWhoIsAddedAndRemoved() throws {
        #expect(try encoded(MembersChange(addedIds: ["u2"], removedIds: [])) == json(#"{"addedIds":["u2"],"removedIds":[]}"#))
        #expect(try encoded(MembersChange(addedIds: [], removedIds: ["u3", "u4"])) == json(#"{"addedIds":[],"removedIds":["u3","u4"]}"#))
    }

    @Test func theFormsListTheSectionsARoomCanGoUnder() throws {
        let form = try decoded(NewRoomForm.self, #"{"people":[{"id":"u1","name":"Ada"}],"sections":[{"id":"s1","name":"Product","rooms":2},{"rooms":1}]}"#)
        #expect(form.sections == [SectionOption(id: "s1", name: "Product", rooms: 2)])
        #expect(try decoded(NewRoomForm.self, #"{"people":[]}"#).sections.isEmpty)
        let settings = try decoded(RoomSettings.self, #"""
        {"room":{"id":"a","kind":"closed","name":"Alpha","channelMentions":false,"members":[]},"canAdminister":true,"canChangeHuddles":false,
         "canChangeChannelMentions":true,"people":[],"section":{"id":"s1","name":"Product"},"sections":[{"id":"s1","name":"Product","rooms":2}]}
        """#)
        #expect(settings.section == product && settings.sections == [SectionOption(id: "s1", name: "Product", rooms: 2)])
        #expect(settings.canChangeChannelMentions && settings.room.channelMentions == false)
        let older = try decoded(RoomSettings.self, #"{"room":{"id":"a","kind":"open","name":"Alpha"},"canAdminister":false,"people":[]}"#)
        #expect(older.section == nil && older.sections.isEmpty && !older.canChangeChannelMentions)
    }
}

@Suite struct SectionListTests {
    @Test func roomsGoUnderTheirSectionsWithTheRestFirst() {
        let listed = RoomList.inSections(rooms, sections: sections, starred: [])
        #expect(listed.loose.map(\.id) == ["d"])
        #expect(listed.sections.map(\.section) == [product, company])
        #expect(listed.sections.map { $0.rooms.map(\.id) } == [["a", "b"], ["c"]])
        #expect(listed.sections.map(\.id) == ["s1", "s2"])
    }

    @Test func aStarredRoomIsListedWithTheRestWhateverItsSection() {
        let listed = RoomList.inSections(rooms, sections: sections, starred: ["c", "a"])
        #expect(listed.loose.map(\.id) == ["a", "c", "d"])
        // Company has no room left to show, so it isn't listed.
        #expect(listed.sections == [ListedSection(section: product, rooms: [rooms[1]])])
    }

    @Test func roomsKeepTheOrderTheyAreGivenInAndSectionsTheirs() {
        let reversed = Array(rooms.reversed())
        let listed = RoomList.inSections(reversed, sections: Array(sections.reversed()), starred: [])
        #expect(listed.sections.map(\.id) == ["s2", "s1"])
        #expect(listed.sections.map { $0.rooms.map(\.id) } == [["c"], ["b", "a"]])
    }

    @Test func aRoomListedInTwoSectionsTakesTheLaterAndOneNotYoursIsLeftOut() {
        let twice = [SidebarSection(id: "s1", name: "Product", roomIds: ["a", "x"]), SidebarSection(id: "s2", name: "Company", roomIds: ["a"])]
        let listed = RoomList.inSections(rooms, sections: twice, starred: [])
        #expect(listed.loose.map(\.id) == ["b", "c", "d"])
        #expect(listed.sections == [ListedSection(section: company, rooms: [rooms[0]])])
        #expect(RoomList.inSections(rooms, sections: [], starred: []) == SectionedRooms(loose: rooms))
    }

    @Test func aRoomMovesToASectionAndOutOfItsOld() {
        #expect(ids(RoomList.withRoomIn(sections, "a", company)) == [["s1", "b"], ["s2", "c", "a"]])
        #expect(ids(RoomList.withRoomIn(sections, "d", product)) == [["s1", "a", "b", "d"], ["s2", "c"]])
        #expect(ids(RoomList.withRoomIn(sections, "a", nil)) == [["s1", "b"], ["s2", "c"]])
        #expect(ids(RoomList.withoutRoom(sections, "c")) == [["s1", "a", "b"], ["s2"]])
        #expect(RoomList.withoutRoom(sections, "d") == sections)
    }

    @Test func aSectionNotListedGoesLastAndOneRenamedTakesItsName() {
        let launch = RoomSection(id: "s3", name: "Launch")
        let moved = RoomList.withRoomIn(sections, "a", launch)
        #expect(ids(moved) == [["s1", "b"], ["s2", "c"], ["s3", "a"]])
        #expect(moved.last?.name == "Launch")
        let renamed = RoomList.withRoomIn(sections, "d", RoomSection(id: "s1", name: "Product team"))
        #expect(renamed.map(\.name) == ["Product team", "Company"])
        #expect(ids(renamed) == [["s1", "a", "b", "d"], ["s2", "c"]])
    }

    @Test func aLayoutPutsItsSectionsFirstInItsOrder() {
        let placed = RoomList.placing(sections, roomIDs: ["a", "b", "c", "d"], in: [
            RoomLayout.Placement(id: "s2", roomIds: ["c", "d"]), RoomLayout.Placement(id: "s1", roomIds: ["a"]),
        ])
        // Delta joins Company, and Beta, which no section lists now, is in none.
        #expect(ids(placed) == [["s2", "c", "d"], ["s1", "a"]])
        #expect(placed.map(\.name) == ["Company", "Product"])
    }

    @Test func aLayoutLeavesWhatItDoesNotList() {
        // Only Company is sent, as someone who isn't an administrator and sees only it would.
        let placed = RoomList.placing(sections, roomIDs: ["a", "c", "d"], in: [RoomLayout.Placement(id: "s2", roomIds: ["d"])])
        // Alpha's section isn't in the layout, so it stays; Gamma, which Company no longer lists, leaves it.
        #expect(ids(placed) == [["s2", "d"], ["s1", "a", "b"]])
        // A room the layout doesn't rank stays wherever it is.
        #expect(ids(RoomList.placing(sections, roomIDs: [], in: [RoomLayout.Placement(id: "s2", roomIds: [])])) == [["s2", "c"], ["s1", "a", "b"]])
    }

    @Test func aLayoutCannotMakeASectionOrListOneTwice() {
        let placed = RoomList.placing(sections, roomIDs: ["a", "d"], in: [
            RoomLayout.Placement(id: "s9", roomIds: ["d"]), RoomLayout.Placement(id: "s1", roomIds: ["a"]), RoomLayout.Placement(id: "s1", roomIds: ["a"]),
        ])
        #expect(ids(placed) == [["s1", "a", "b"], ["s2", "c"]])
        #expect(RoomList.placing(sections, roomIDs: ["a", "b", "c", "d"], in: []) == sections)
    }
}

@Suite struct SidebarSectionTests {
    @Test func theSidebarStartsWithTheServersSections() {
        let sidebar = state()
        #expect(sidebar.sections == sections)
        let listed = RoomList.inSections(sidebar.rooms, sections: sidebar.sections, starred: Set(sidebar.favorites.rooms))
        #expect(listed.loose.map(\.id) == ["d"])
    }

    @Test func aLayoutAskedForShowsUntilItIsAnswered() {
        var sidebar = state(sharedOrder: ["a", "b", "c", "d"])
        let guess = sidebar.beginSharedOrder(["d", "c", "b", "a"], sections: [
            RoomLayout.Placement(id: "s2", roomIds: ["d", "c"]), RoomLayout.Placement(id: "s1", roomIds: ["b"]),
        ])
        #expect(sidebar.sharedOrder == ["d", "c", "b", "a"])
        #expect(ids(sidebar.sections) == [["s2", "c", "d"], ["s1", "b"]])

        // The server's answer takes its place, a section someone else made meanwhile and all.
        let saved = [
            SidebarSection(id: "s2", name: "Company", roomIds: ["d", "c"]), SidebarSection(id: "s1", name: "Product", roomIds: ["b"]),
            SidebarSection(id: "s3", name: "Launch"),
        ]
        sidebar.acceptSharedOrder(guess, order: ["d", "c", "b", "a"], sections: saved)
        #expect(sidebar.sections == saved)
        #expect(sidebar.sharedOrder == ["d", "c", "b", "a"])
    }

    @Test func aLayoutRefusedPutsTheSectionsBack() {
        var sidebar = state(sharedOrder: ["a", "b", "c", "d"])
        let guess = sidebar.beginSharedOrder(["d", "a", "b", "c"], sections: [RoomLayout.Placement(id: "s1", roomIds: ["d", "a", "b"]), RoomLayout.Placement(id: "s2", roomIds: ["c"])])
        #expect(ids(sidebar.sections) == [["s1", "a", "b", "d"], ["s2", "c"]])
        sidebar.rejectSharedOrder(guess)
        #expect(sidebar.sections == sections && sidebar.sharedOrder == ["a", "b", "c", "d"])
    }

    @Test func anOrderWithoutSectionsLeavesThemAsTheyAre() {
        var sidebar = state()
        let guess = sidebar.beginSharedOrder(["d", "c", "b", "a"])
        #expect(sidebar.sections == sections)
        sidebar.acceptSharedOrder(guess, order: ["d", "c", "b", "a"])
        #expect(sidebar.sections == sections && sidebar.sharedOrder == ["d", "c", "b", "a"])
    }

    @Test func twoLayoutsOnTheirWayBothShow() {
        var sidebar = state()
        let first = sidebar.beginSharedOrder(["a", "b", "c", "d"], sections: [RoomLayout.Placement(id: "s1", roomIds: ["a", "b", "d"]), RoomLayout.Placement(id: "s2", roomIds: ["c"])])
        _ = sidebar.beginSharedOrder(["a", "b", "c", "d"], sections: [RoomLayout.Placement(id: "s2", roomIds: ["c"]), RoomLayout.Placement(id: "s1", roomIds: ["a", "b", "d"])])
        #expect(ids(sidebar.sections) == [["s2", "c"], ["s1", "a", "b", "d"]])
        // The first answered, the second still shows over it.
        sidebar.acceptSharedOrder(first, order: ["a", "b", "c", "d"], sections: [
            SidebarSection(id: "s1", name: "Product", roomIds: ["a", "b", "d"]), SidebarSection(id: "s2", name: "Company", roomIds: ["c"]),
        ])
        #expect(ids(sidebar.sections) == [["s2", "c"], ["s1", "a", "b", "d"]])
    }

    @Test func aSavedRoomMovesToTheSectionItSays() {
        var sidebar = state()
        let delta = Room(id: "d", kind: .open, name: "Delta")
        let moved = sidebar.apply(.roomSaved(delta, section: .section(company)))
        #expect(!moved)
        #expect(ids(sidebar.sections) == [["s1", "a", "b"], ["s2", "c", "d"]])
        // Out of every section.
        let taken = sidebar.apply(.roomSaved(Room(id: "a", kind: .open, name: "Alpha"), section: .loose))
        #expect(!taken)
        #expect(ids(sidebar.sections) == [["s1", "b"], ["s2", "c", "d"]])
        // A rename says nothing of its section, and leaves it there.
        let renamed = sidebar.apply(.roomSaved(Room(id: "b", kind: .open, name: "Beta two")))
        #expect(!renamed)
        #expect(ids(sidebar.sections) == [["s1", "b"], ["s2", "c", "d"]])
        #expect(sidebar.rooms.first { $0.id == "b" }?.room.name == "Beta two")
    }

    @Test func aSavedRoomInASectionTheSidebarDoesNotListAsksForTheSidebarAgain() {
        var sidebar = state()
        let launch = RoomSection(id: "s3", name: "Launch")
        // Only the server knows where Launch is among the others, so it's shown last meanwhile.
        let unlisted = sidebar.apply(.roomSaved(Room(id: "e", kind: .open, name: "Epsilon"), section: .section(launch)))
        #expect(unlisted)
        #expect(ids(sidebar.sections) == [["s1", "a", "b"], ["s2", "c"], ["s3", "e"]])
        #expect(sidebar.rooms.map(\.id) == ["a", "b", "c", "d", "e"])
        // The next room put in it finds it listed.
        let listed = sidebar.apply(.roomSaved(Room(id: "d", kind: .open, name: "Delta"), section: .section(launch)))
        #expect(!listed)
    }

    @Test func aRoomMadeOrChangedHereGoesWhereItsAnswerSays() {
        var sidebar = state()
        sidebar.add(Room(id: "e", kind: .open, name: "Epsilon"), section: .section(product))
        #expect(ids(sidebar.sections) == [["s1", "a", "b", "e"], ["s2", "c"]])
        sidebar.add(Room(id: "e", kind: .open, name: "Epsilon"), section: .loose)
        #expect(ids(sidebar.sections) == [["s1", "a", "b"], ["s2", "c"]])
        sidebar.add(Room(id: "e", kind: .open, name: "Epsilon five"))
        #expect(ids(sidebar.sections) == [["s1", "a", "b"], ["s2", "c"]])
    }

    @Test func aRoomThatIsGoneLeavesItsSection() {
        var sidebar = state()
        sidebar.apply(.roomGone("a"))
        #expect(ids(sidebar.sections) == [["s1", "b"], ["s2", "c"]])
        sidebar.remove("c")
        #expect(ids(sidebar.sections) == [["s1", "b"], ["s2"]])
    }

    @Test func aSectionChangeAsksForTheSidebarAgain() {
        var sidebar = state()
        let again = sidebar.apply(.roomsReordered)
        #expect(again)
        #expect(sidebar.sections == sections)
    }

    @Test func changesWhileTheSidebarLoadsGoOverTheOneThatArrives() {
        var sidebar = state()
        sidebar.willLoad()
        sidebar.apply(.roomSaved(Room(id: "d", kind: .open, name: "Delta"), section: .section(company)))
        let guess = sidebar.beginSharedOrder(["a", "b", "c", "d"], sections: [RoomLayout.Placement(id: "s2", roomIds: ["c", "d"]), RoomLayout.Placement(id: "s1", roomIds: ["a", "b"])])
        // The sidebar that arrives was read before either.
        sidebar.loaded(Sidebar(rooms: rooms, sections: sections))
        #expect(ids(sidebar.sections) == [["s2", "c", "d"], ["s1", "a", "b"]])
        sidebar.rejectSharedOrder(guess)
        #expect(ids(sidebar.sections) == [["s1", "a", "b"], ["s2", "c", "d"]])
    }

    @Test func aLayoutSavedWhileTheSidebarLoadsIsKept() {
        var sidebar = state()
        let guess = sidebar.beginSharedOrder(["a", "b", "c", "d"], sections: [RoomLayout.Placement(id: "s2", roomIds: ["c"]), RoomLayout.Placement(id: "s1", roomIds: ["a", "b"])])
        sidebar.willLoad()
        let saved = [SidebarSection(id: "s2", name: "Company", roomIds: ["c"]), SidebarSection(id: "s1", name: "Product", roomIds: ["a", "b"])]
        sidebar.acceptSharedOrder(guess, order: ["a", "b", "c", "d"], sections: saved)
        sidebar.loaded(Sidebar(rooms: rooms, sections: sections))
        #expect(sidebar.sections == saved && sidebar.sharedOrder == ["a", "b", "c", "d"])
    }
}

@Suite struct MentionCountTests {
    @Test func aSidebarRoomSaysHowManyMessagesMentionYou() throws {
        let unread = try decoded(SidebarRoom.self, #"{"id":"a","kind":"open","name":"Alpha","unread":true,"unreadSince":"2026-10-12T12:00:00.000Z","mentionCount":2}"#)
        #expect(unread.mentionCount == 2 && unread.unreadSince == noon())
        // A read room keeps none whatever it says, and one that can't be read is left out.
        #expect(try decoded(SidebarRoom.self, #"{"id":"a","kind":"open","name":"Alpha","unread":false,"mentionCount":2}"#).mentionCount == nil)
        #expect(try decoded(SidebarRoom.self, #"{"id":"a","kind":"open","name":"Alpha","unread":true,"mentionCount":"2"}"#).mentionCount == nil)
        #expect(SidebarRoom(room: Room(id: "a", kind: .open, name: "Alpha"), unread: false, mentionCount: 2).mentionCount == nil)
    }

    @Test func aMarkCarriesItsMentionsAndReadingClearsThem() {
        var sidebar = state()
        sidebar.apply(.roomUnread("a", since: noon(), mentions: 1))
        #expect(sidebar.rooms[0].unread && sidebar.rooms[0].mentionCount == 1 && sidebar.rooms[0].unreadSince == noon())
        // Each mark says how many there are now, and keeps the time the first gave when it names none.
        sidebar.apply(.roomUnread("a", mentions: 3))
        #expect(sidebar.rooms[0].mentionCount == 3 && sidebar.rooms[0].unreadSince == noon())
        // A message that mentions nobody since the last one read.
        sidebar.apply(.roomUnread("b", since: noon(1)))
        #expect(sidebar.rooms[1].unread && sidebar.rooms[1].mentionCount == nil)
        sidebar.apply(.roomRead("a"))
        #expect(!sidebar.rooms[0].unread && sidebar.rooms[0].mentionCount == nil)
        sidebar.apply(.roomUnread("b", since: noon(2), mentions: 1))
        sidebar.markRead("b")
        #expect(sidebar.rooms[1].mentionCount == nil)
    }

    @Test func aMarkMadeWhileTheSidebarLoadsKeepsItsMentions() {
        var sidebar = state()
        sidebar.willLoad()
        sidebar.apply(.roomUnread("c", since: noon(), mentions: 2))
        sidebar.loaded(Sidebar(rooms: rooms, sections: sections))
        #expect(sidebar.rooms[2].unread && sidebar.rooms[2].mentionCount == 2)
    }
}
