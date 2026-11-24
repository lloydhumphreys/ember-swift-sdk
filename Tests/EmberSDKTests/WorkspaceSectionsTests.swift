import EmberTesting
import Foundation
import Testing
@testable import EmberSDK

/// The sidebar's sections as the workspace shows them: what the server lists, what the socket says,
/// and what you change, shown at once.
@MainActor @Suite struct WorkspaceSectionsTests {
    let transport = MockHTTPTransport()
    let connector = MockSocketConnector()
    let workspace: Workspace

    static let sectioned = Fixtures.sidebarJSON(sections: Fixtures.sidebarSections)
    static let ops = RoomSection(id: "section-ops", name: "Ops")

    init() {
        let (timing, _) = manualTiming()
        workspace = Workspace.mock(transport: transport, connector: connector, timing: timing)
    }

    /// Loads the workspace with Engines under Product and Company empty, and lets the welcome's
    /// refetch finish, so later sidebar stubs are only read when a test asks for them.
    func started(sidebar: String = sectioned) async throws {
        transport.stub("GET", "/api/sidebar", json: sidebar)
        workspace.start()
        try #require(await eventually { workspace.isLoaded && transport.requests("GET", "/api/sidebar").count >= 2 })
        await workspace.reload()
    }

    var sidebarLoads: Int { transport.requests("GET", "/api/sidebar").count }

    /// The sections, each with its rooms' ids.
    var listed: [String: [RoomID]] {
        Dictionary(uniqueKeysWithValues: workspace.sections.map { ($0.name, $0.roomIds) })
    }

    // MARK: What the sidebar lists

    @Test func theSidebarsSectionsListTheirRooms() async throws {
        try await started()
        #expect(workspace.sections == Fixtures.sidebarSections)
        // General is starred, so it stays with the rooms in no section. Company has no room of yours.
        #expect(workspace.sectionedRooms.loose.map(\.id) == [Fixtures.general.id])
        #expect(workspace.sectionedRooms.sections.map(\.section) == [Fixtures.product])
        #expect(workspace.sectionedRooms.sections.first?.rooms.map(\.id) == [Fixtures.engines.id])
    }

    @Test func aStarredRoomIsListedOutsideItsSection() async throws {
        let both = [SidebarSection(id: Fixtures.product.id, name: "Product", roomIds: [Fixtures.general.id, Fixtures.engines.id])]
        try await started(sidebar: Fixtures.sidebarJSON(favorites: Favorites(rooms: [], version: 1), sections: both))
        #expect(workspace.sectionedRooms.loose.isEmpty)
        // In the shared order, whatever order the section lists them in.
        #expect(workspace.sectionedRooms.sections.first?.rooms.map(\.id) == [Fixtures.engines.id, Fixtures.general.id])

        connector.latest?.serverSends(Fixtures.WorkspaceFrames.favoritesChanged(Favorites(rooms: [Fixtures.general.id], version: 2)))
        #expect(await eventually { workspace.sectionedRooms.loose.map(\.id) == [Fixtures.general.id] })
        #expect(workspace.sectionedRooms.sections.first?.rooms.map(\.id) == [Fixtures.engines.id])
        #expect(workspace.sections == both)
    }

    @Test func aServerFromBeforeSectionsListsNone() async throws {
        try await started(sidebar: Fixtures.sidebarJSON())
        #expect(workspace.sections.isEmpty)
        #expect(workspace.sectionedRooms.sections.isEmpty)
        #expect(workspace.sectionedRooms.loose.map(\.id) == workspace.sharedRooms.map(\.id))
    }

    // MARK: What the socket says

    @Test func aRoomSavedWithASectionIsListedThere() async throws {
        try await started()
        let loads = sidebarLoads
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomSaved(Fixtures.engines, section: Fixtures.company))
        #expect(await eventually { listed == ["Product": [], "Company": [Fixtures.engines.id]] })
        #expect(workspace.sectionedRooms.sections.map(\.section) == [Fixtures.company])

        // One that says nothing of a section leaves the room where it is.
        let renamed = Room(id: Fixtures.engines.id, kind: .closed, name: "Difference Engines", icon: "cog")
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomSaved(renamed))
        #expect(await eventually { workspace.room(Fixtures.engines.id)?.room.name == "Difference Engines" })
        #expect(listed == ["Product": [], "Company": [Fixtures.engines.id]])

        // And null takes it out of them all.
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomSaved(renamed, section: nil))
        #expect(await eventually { listed == ["Product": [], "Company": []] })
        #expect(workspace.sectionedRooms.sections.isEmpty)
        #expect(workspace.sectionedRooms.loose.map(\.id) == [Fixtures.general.id, Fixtures.engines.id])
        #expect(sidebarLoads == loads)
    }

    @Test func aRoomSavedInASectionTheSidebarDoesntListLoadsItAgain() async throws {
        try await started()
        let loads = sidebarLoads
        let withOps = [SidebarSection(id: Self.ops.id, name: "Ops", roomIds: [Fixtures.engines.id])] + Fixtures.sidebarSections.map {
            SidebarSection(id: $0.id, name: $0.name)
        }
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON(sections: withOps))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomSaved(Fixtures.engines, section: Self.ops))
        #expect(await eventually { sidebarLoads > loads && workspace.sections == withOps })
        #expect(workspace.sectionedRooms.sections.map(\.section) == [Self.ops])
    }

    @Test func aRoomThatsGoneLeavesItsSection() async throws {
        try await started()
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomGone(Fixtures.engines.id))
        #expect(await eventually { workspace.room(Fixtures.engines.id) == nil })
        #expect(listed == ["Product": [], "Company": []])
        #expect(workspace.sectionedRooms.sections.isEmpty)
    }

    @Test func roomsReorderedLoadsTheSectionsAgain() async throws {
        try await started()
        let loads = sidebarLoads
        let renamed = [SidebarSection(id: Fixtures.company.id, name: "Everyone"), SidebarSection(id: Fixtures.product.id, name: "Product", roomIds: [Fixtures.engines.id])]
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON(sections: renamed))
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomsReordered)
        #expect(await eventually { sidebarLoads > loads && workspace.sections == renamed })
    }

    // MARK: Mention counts

    @Test func anUnreadRoomSaysHowManyMentionsOfYouItHolds() async throws {
        let mentioned = [
            SidebarRoom(room: Fixtures.general, unread: true, unreadCount: 5, mentionCount: 2),
            SidebarRoom(room: Fixtures.engines),
            SidebarRoom(room: Fixtures.directWithGrace),
        ]
        try await started(sidebar: Fixtures.sidebarJSON(rooms: mentioned))
        #expect(workspace.room(Fixtures.general.id)?.mentionCount == 2)
        #expect(workspace.room(Fixtures.engines.id)?.mentionCount == nil)

        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomUnread(Fixtures.engines.id, count: 3, mentions: 1))
        #expect(await eventually { workspace.room(Fixtures.engines.id)?.mentionCount == 1 })
        #expect(workspace.room(Fixtures.engines.id)?.unreadCount == 3)
        // Each frame says the count afresh, and one without it holds none.
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomUnread(Fixtures.engines.id, count: 4))
        #expect(await eventually { workspace.room(Fixtures.engines.id)?.unreadCount == 4 })
        #expect(workspace.room(Fixtures.engines.id)?.mentionCount == nil)

        connector.latest?.serverSends(Fixtures.WorkspaceFrames.roomRead(Fixtures.general.id))
        #expect(await eventually { workspace.room(Fixtures.general.id)?.unread == false })
        #expect(workspace.room(Fixtures.general.id)?.mentionCount == nil)
    }

    @Test func openingARoomClearsItsMentions() async throws {
        let mentioned = [SidebarRoom(room: Fixtures.general, unread: true, unreadCount: 5, mentionCount: 2), SidebarRoom(room: Fixtures.engines)]
        try await started(sidebar: Fixtures.sidebarJSON(rooms: mentioned))
        workspace.markRead(Fixtures.general.id)
        #expect(workspace.room(Fixtures.general.id)?.mentionCount == nil)
        #expect(workspace.room(Fixtures.general.id)?.unreadCount == nil)
    }

    // MARK: Rooms you put in sections

    @Test func aNewRoomIsListedUnderTheSectionItChose() async throws {
        try await started()
        let looms = Room(id: "room-looms", kind: .open, name: "Looms")
        transport.stub("POST", "/api/rooms", json: Fixtures.roomJSON(looms))
        let made = try await workspace.createRoom(NewRoom(name: "Looms", section: .section(Fixtures.company.id)))
        #expect(made.id == looms.id)
        #expect(transport.lastBody("POST", "/api/rooms")?["section"] as? String == "section-company")
        #expect(listed == ["Product": [Fixtures.engines.id], "Company": [looms.id]])
        #expect(workspace.sectionedRooms.sections.map(\.section) == [Fixtures.product, Fixtures.company])
    }

    @Test func aNewRoomInANewSectionWaitsForTheSidebar() async throws {
        try await started()
        let loads = sidebarLoads
        let looms = Room(id: "room-looms", kind: .open, name: "Looms")
        let withOps = Fixtures.sidebarSections + [SidebarSection(id: Self.ops.id, name: "Ops", roomIds: [looms.id])]
        transport.stub("POST", "/api/rooms", json: Fixtures.roomJSON(looms))
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON(rooms: Fixtures.sidebarRooms + [SidebarRoom(room: looms)], sections: withOps))
        try await workspace.createRoom(NewRoom(name: "Looms", section: .new(name: "Ops")))
        // It's in the sidebar at once, and under its section once the server has said which that is.
        #expect(workspace.room(looms.id) != nil)
        #expect(await eventually { sidebarLoads > loads && workspace.sections == withOps })
        #expect(workspace.sectionedRooms.sections.map(\.section) == [Fixtures.product, Self.ops])
    }

    @Test func aRoomIsMovedToASectionAndOutOfThem() async throws {
        try await started()
        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(Fixtures.engines))
        try await workspace.changeRoom(Fixtures.engines.id, RoomChanges(section: .section(Fixtures.company.id)))
        #expect(listed == ["Product": [], "Company": [Fixtures.engines.id]])

        // A change that chooses none leaves it there.
        try await workspace.changeRoom(Fixtures.engines.id, RoomChanges(icon: "gear"))
        #expect(listed == ["Product": [], "Company": [Fixtures.engines.id]])

        try await workspace.changeRoom(Fixtures.engines.id, RoomChanges(section: .noSection))
        #expect(listed == ["Product": [], "Company": []])
        #expect(workspace.sectionedRooms.loose.map(\.id) == [Fixtures.general.id, Fixtures.engines.id])
    }

    @Test func aRefusedMoveLeavesTheRoomWhereItWas() async throws {
        try await started()
        transport.stub("PATCH", "/api/rooms/room-engines", status: 403, json: Fixtures.errorJSON("Only administrators can change a room’s section"))
        await #expect(throws: EmberError.self) { try await workspace.changeRoom(Fixtures.engines.id, RoomChanges(section: .noSection)) }
        #expect(workspace.sections == Fixtures.sidebarSections)
    }

    // MARK: Members

    @Test func peoplePutInOrTakenOutLeaveTheRoomInTheSidebar() async throws {
        try await started()
        transport.stub("PATCH", "/api/rooms/room-engines/members", json: Fixtures.roomJSON(Fixtures.engines))
        let saved = try await workspace.changeMembers(of: Fixtures.engines.id, adding: [Fixtures.alan.id], removing: [Fixtures.grace.id])
        #expect(saved == Fixtures.engines)
        let body = try #require(transport.lastBody("PATCH", "/api/rooms/room-engines/members"))
        #expect(body["addedIds"] as? [String] == ["user_alan"])
        #expect(body["removedIds"] as? [String] == ["user_grace"])
        #expect(workspace.room(Fixtures.engines.id) != nil)
        #expect(workspace.sections == Fixtures.sidebarSections)
    }

    @Test func takingYourselfOutTakesTheRoomOutOfTheSidebar() async throws {
        try await started()
        transport.stub("PATCH", "/api/rooms/room-engines/members", json: Fixtures.roomJSON(Fixtures.engines))
        try await workspace.changeMembers(of: Fixtures.engines.id, removing: [Fixtures.me.id])
        #expect(workspace.room(Fixtures.engines.id) == nil)
        #expect(listed == ["Product": [], "Company": []])
    }

    @Test func aRefusedChangeOfMembersChangesNothing() async throws {
        try await started()
        transport.stub("PATCH", "/api/rooms/room-engines/members", status: 403, json: Fixtures.errorJSON("Only administrators and the room’s creator can change who’s in it"))
        await #expect(throws: EmberError.self) { try await workspace.changeMembers(of: Fixtures.engines.id, removing: [Fixtures.me.id]) }
        #expect(workspace.room(Fixtures.engines.id) != nil)
    }

    // MARK: Sections you make, rename and delete

    @Test func aSectionMadeRenamedOrDeletedLoadsTheSidebarAgain() async throws {
        try await started()
        var loads = sidebarLoads
        let withOps = Fixtures.sidebarSections + [SidebarSection(id: Self.ops.id, name: "Ops")]
        transport.stub("POST", "/api/account/sections", json: Fixtures.sectionJSON(Self.ops))
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON(sections: withOps))
        let made = try await workspace.makeSection(named: "Ops")
        #expect(made == Self.ops)
        #expect(transport.lastBody("POST", "/api/account/sections")?["name"] as? String == "Ops")
        #expect(workspace.sections == withOps)
        #expect(sidebarLoads == loads + 1)

        loads = sidebarLoads
        let operations = RoomSection(id: Self.ops.id, name: "Operations")
        let withOperations = Fixtures.sidebarSections + [SidebarSection(id: Self.ops.id, name: "Operations")]
        transport.stub("PATCH", "/api/account/sections/section-ops", json: Fixtures.sectionJSON(operations))
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON(sections: withOperations))
        let renamed = try await workspace.renameSection(Self.ops.id, to: "Operations")
        #expect(renamed == operations)
        #expect(workspace.sections == withOperations)
        #expect(sidebarLoads == loads + 1)

        loads = sidebarLoads
        transport.stub("DELETE", "/api/account/sections/section-product", status: 204, json: "")
        transport.stub("GET", "/api/sidebar", json: Fixtures.sidebarJSON(sections: [SidebarSection(id: Fixtures.company.id, name: "Company")]))
        try await workspace.deleteSection(Fixtures.product.id)
        // Its rooms are in none now.
        #expect(workspace.sections.map(\.section) == [Fixtures.company])
        #expect(workspace.sectionedRooms.sections.isEmpty)
        #expect(workspace.sectionedRooms.loose.map(\.id) == [Fixtures.general.id, Fixtures.engines.id])
        #expect(sidebarLoads == loads + 1)
    }

    @Test func aRefusedSectionIsThrownAndLoadsNothing() async throws {
        try await started()
        let loads = sidebarLoads
        transport.stub("POST", "/api/account/sections", status: 409, json: Fixtures.errorJSON("There’s already a section with that name"))
        transport.stub("DELETE", "/api/account/sections/section-product", status: 403, json: Fixtures.errorJSON("Only administrators can change sections"))
        await #expect(throws: EmberError.self) { try await workspace.makeSection(named: "Product") }
        await #expect(throws: EmberError.self) { try await workspace.deleteSection(Fixtures.product.id) }
        #expect(workspace.sections == Fixtures.sidebarSections)
        #expect(sidebarLoads == loads)
        #expect(workspace.notice == nil)
    }

    // MARK: The layout

    /// Company first with Engines in it, and Product after it with nothing.
    static let layout = RoomLayout(
        roomIds: [Fixtures.general.id, Fixtures.engines.id],
        sections: [
            RoomLayout.Placement(id: Fixtures.company.id, roomIds: [Fixtures.engines.id]),
            RoomLayout.Placement(id: Fixtures.product.id, roomIds: []),
        ]
    )
    static let laidOut = [
        SidebarSection(id: Fixtures.company.id, name: "Company", roomIds: [Fixtures.engines.id]),
        SidebarSection(id: Fixtures.product.id, name: "Product"),
    ]

    @Test func aLayoutShowsAtOnceAndStays() async throws {
        try await started()
        let gate = transport.hold("PUT", "/api/account/room_order")
        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON(Self.layout.roomIds, sections: Self.laidOut))

        let saving = Task { await workspace.saveRoomLayout(Self.layout) }
        await gate.waitForRequest()
        #expect(workspace.sharedOrder == Self.layout.roomIds)
        #expect(workspace.sections == Self.laidOut)
        #expect(workspace.sectionedRooms.sections.map(\.section) == [Fixtures.company])
        let body = try #require(transport.lastBody("PUT", "/api/account/room_order"))
        #expect(body["roomIds"] as? [String] == ["room-general", "room-engines"])
        let sent = try #require(body["sections"] as? [[String: Any]])
        #expect(sent.map { $0["id"] as? String } == ["section-company", "section-product"])
        #expect(sent.map { $0["roomIds"] as? [String] } == [["room-engines"], []])

        // A sidebar read before the layout was saved doesn't undo it.
        await workspace.reload()
        #expect(workspace.sections == Self.laidOut)

        gate.release()
        await saving.value
        #expect(workspace.sharedOrder == Self.layout.roomIds)
        #expect(workspace.sections == Self.laidOut)
        #expect(workspace.notice == nil)
    }

    @Test func aRefusedLayoutIsPutBack() async throws {
        try await started()
        let loads = sidebarLoads
        transport.stub("PUT", "/api/account/room_order", status: 403, json: Fixtures.errorJSON("Only administrators can put rooms in order for everyone"))
        await workspace.saveRoomLayout(Self.layout)
        #expect(workspace.sections == Fixtures.sidebarSections)
        #expect(workspace.sharedOrder == [Fixtures.engines.id, Fixtures.general.id])
        #expect(workspace.notice == "Only administrators can put rooms in order for everyone")
        #expect(sidebarLoads == loads + 1)
    }

    @Test func movingRoomsLeavesTheSectionsAsTheyAre() async throws {
        try await started()
        let moved = [Fixtures.general.id, Fixtures.engines.id]
        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON(moved, sections: Fixtures.sidebarSections))
        await workspace.moveSharedRooms(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let body = try #require(transport.lastBody("PUT", "/api/account/room_order"))
        #expect(Array(body.keys) == ["roomIds"])
        #expect(workspace.sharedOrder == moved)
        #expect(workspace.sections == Fixtures.sidebarSections)

        transport.stub("PUT", "/api/account/room_order", json: Fixtures.sharedOrderJSON([], sections: Fixtures.sidebarSections))
        await workspace.clearSharedOrder()
        #expect(workspace.sharedOrder.isEmpty)
        #expect(workspace.sections == Fixtures.sidebarSections)
        #expect(workspace.notice == nil)
    }

    @Test func aServerFromBeforeSectionsAnswersTheOrderAlone() async throws {
        try await started(sidebar: Fixtures.sidebarJSON())
        transport.stub("PUT", "/api/account/room_order", json: #"{"sharedOrder":["room-general","room-engines"]}"#)
        await workspace.moveSharedRooms(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(workspace.sharedOrder == [Fixtures.general.id, Fixtures.engines.id])
        #expect(workspace.sections.isEmpty)
        #expect(workspace.notice == nil)
    }
}
