import Foundation
import Testing
@testable import EmberCore

private func room(_ id: RoomID, _ name: String, kind: RoomKind = .open, hidden: Bool = false) -> SidebarRoom {
    SidebarRoom(room: Room(id: id, kind: kind, name: name), involvement: hidden ? .invisible : .mentions)
}

private let invitation = try! EmberJSON.decoder().decode(Invitation.self, from: Data(#"{"roomId":"a","joinCode":"aB3d"}"#.utf8))

private let rooms = [room("a", "Alpha"), room("b", "Beta"), room("c", "Gamma")]

private func state(favorites: [RoomID] = ["a", "b", "c"], version: Int = 1, sharedOrder: [RoomID] = [], invitation: Invitation? = nil) -> SidebarState {
    SidebarState(Sidebar(rooms: rooms, favorites: Favorites(rooms: favorites, version: version), sharedOrder: sharedOrder, invitation: invitation))
}

@Suite struct SidebarOrderListTests {
    @Test func movesAsOnMoveDoes() {
        let ids = ["a", "b", "c", "d"]
        #expect(RoomList.moving(ids, fromOffsets: IndexSet(integer: 3), toOffset: 0) == ["d", "a", "b", "c"])
        #expect(RoomList.moving(ids, fromOffsets: IndexSet(integer: 0), toOffset: 4) == ["b", "c", "d", "a"])
        #expect(RoomList.moving(ids, fromOffsets: IndexSet(integer: 0), toOffset: 2) == ["b", "a", "c", "d"])
        #expect(RoomList.moving(ids, fromOffsets: IndexSet([0, 2]), toOffset: 4) == ["b", "d", "a", "c"])
        #expect(RoomList.moving(ids, fromOffsets: IndexSet(integer: 1), toOffset: 1) == ids)
    }

    @Test func reordersOnlyWhatTheOrderLists() {
        #expect(RoomList.reordered(["a", "b", "c", "d"], by: ["d", "b"]) == ["a", "d", "c", "b"])
        #expect(RoomList.reordered(["a", "b", "c"], by: ["c", "x", "a"]) == ["c", "b", "a"])
        #expect(RoomList.reordered(["a", "b"], by: []) == ["a", "b"])
        #expect(RoomList.reordered(["a", "b"], by: ["b", "b", "a"]) == ["b", "a"])
    }

    @Test func theSharedOrderListsHiddenRoomsAndNoStarsOrDMs() {
        let all = rooms + [room("h", "Hidden", hidden: true), room("dm", "", kind: .direct)]
        #expect(RoomList.inSharedOrder(all, sharedOrder: ["c", "h"]).map(\.id) == ["c", "h", "a", "b"])
        // The sidebar leaves hidden rooms out and puts stars first.
        #expect(RoomList.shared(all, favorites: ["b"], sharedOrder: ["c", "h"]).map(\.id) == ["b", "c", "a"])
    }
}

@Suite struct SidebarOrderStateTests {
    @Test func aStarOrderShowsAtOnceAndGoesWhenRefused() {
        var sidebar = state()
        let guess = sidebar.beginFavoriteOrder(["c", "a", "b"])
        #expect(sidebar.favorites.rooms == ["c", "a", "b"])
        sidebar.rejectFavoriteOrder(guess)
        #expect(sidebar.favorites.rooms == ["a", "b", "c"])
    }

    @Test func aStarOrderAnsweredIsTheServers() {
        var sidebar = state()
        let guess = sidebar.beginFavoriteOrder(["c", "a", "b"])
        sidebar.acceptFavoriteOrder(guess, favorites: Favorites(rooms: ["c", "a", "b"], version: 2))
        #expect(sidebar.favorites == Favorites(rooms: ["c", "a", "b"], version: 2))
    }

    @Test func framesAroundAStarOrderAgreeWithIt() {
        var sidebar = state()
        let guess = sidebar.beginFavoriteOrder(["c", "a", "b"])
        let answer = Favorites(rooms: ["c", "a", "b"], version: 2)
        sidebar.apply(.favoritesChanged(answer))
        #expect(sidebar.favorites == answer)
        sidebar.apply(.favoritesChanged(Favorites(rooms: ["a", "b", "c"], version: 1)))
        #expect(sidebar.favorites == answer)
        sidebar.acceptFavoriteOrder(guess, favorites: answer)
        #expect(sidebar.favorites == answer)
    }

    @Test func aStarOrderSurvivesASidebarReadBeforeIt() {
        var sidebar = state()
        sidebar.willLoad()
        let guess = sidebar.beginFavoriteOrder(["b", "c", "a"])
        sidebar.loaded(Sidebar(rooms: rooms, favorites: Favorites(rooms: ["a", "b", "c"], version: 1)))
        #expect(sidebar.favorites.rooms == ["b", "c", "a"])
        sidebar.rejectFavoriteOrder(guess)
        #expect(sidebar.favorites.rooms == ["a", "b", "c"])
    }

    @Test func aStarredRoomWhileTheOrderIsOnItsWayKeepsBoth() {
        var sidebar = state(favorites: ["a", "b"])
        _ = sidebar.beginFavoriteOrder(["b", "a"])
        _ = sidebar.beginFavorite(true, roomID: "c")
        #expect(sidebar.favorites.rooms == ["b", "a", "c"])
    }

    @Test func aSharedOrderShowsAtOnceAndGoesWhenRefused() {
        var sidebar = state(sharedOrder: ["a", "b"])
        let guess = sidebar.beginSharedOrder(["b", "a"])
        #expect(sidebar.sharedOrder == ["b", "a"])
        sidebar.rejectSharedOrder(guess)
        #expect(sidebar.sharedOrder == ["a", "b"])
    }

    @Test func anAnsweredSharedOrderOutlastsASidebarReadBeforeIt() {
        var sidebar = state(sharedOrder: ["a", "b"])
        sidebar.willLoad()
        let guess = sidebar.beginSharedOrder(["b", "a"])
        sidebar.acceptSharedOrder(guess, order: ["b", "a"])
        sidebar.loaded(Sidebar(rooms: rooms, sharedOrder: ["a", "b"]))
        #expect(sidebar.sharedOrder == ["b", "a"])
        // rooms.reordered asks for the sidebar again.
        let reload = sidebar.apply(.roomsReordered)
        #expect(reload)
    }

    @Test func clearingTheSharedOrderShowsNone() {
        var sidebar = state(sharedOrder: ["a", "b"])
        let guess = sidebar.beginSharedOrder([])
        #expect(sidebar.sharedOrder.isEmpty)
        sidebar.acceptSharedOrder(guess, order: [])
        #expect(sidebar.sharedOrder.isEmpty)
    }

    @Test func aDismissalHidesTheInvitationUntilRefused() {
        var sidebar = state(invitation: invitation)
        sidebar.beginDismissal()
        #expect(sidebar.invitation == nil)
        sidebar.willLoad()
        sidebar.loaded(Sidebar(rooms: rooms, invitation: invitation))
        #expect(sidebar.invitation == nil)
        sidebar.rejectDismissal()
        #expect(sidebar.invitation == invitation)
    }

    @Test func anAcceptedDismissalOutlastsASidebarReadBeforeIt() {
        var sidebar = state(invitation: invitation)
        sidebar.willLoad()
        sidebar.beginDismissal()
        sidebar.acceptDismissal()
        sidebar.loaded(Sidebar(rooms: rooms, invitation: invitation))
        #expect(sidebar.invitation == nil)
        sidebar.apply(.invitationDismissed)
        #expect(sidebar.invitation == nil)
    }

    @Test func theInvitationDismissedFrameHidesIt() {
        var sidebar = state(invitation: invitation)
        let reload = sidebar.apply(.invitationDismissed)
        #expect(!reload)
        #expect(sidebar.invitation == nil)
    }

    @Test func aRemovedRoomLeavesWithItsStar() {
        var sidebar = state()
        sidebar.remove("b")
        #expect(sidebar.rooms.map(\.id) == ["a", "c"])
        #expect(sidebar.favorites.rooms == ["a", "c"])
    }
}
