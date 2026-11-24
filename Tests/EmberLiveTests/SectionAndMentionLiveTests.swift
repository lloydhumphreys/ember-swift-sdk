import EmberRichText
import EmberSDK
import Foundation
import Testing

/// Sections and the layout that places rooms in them, a closed room's members, who a room-wide
/// mention would notify and how mentions are counted, and pausing notifications. Each test makes
/// its own sections and rooms and deletes them, and puts the seeded layout back as it found it.
extension LiveTests {
    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func makesRenamesAndDeletesASection() async throws {
        let client = try await signedIn()
        let name = uniqueRoomName()
        let section = try await client.makeSection(named: "  \(name)  ")
        var deleted = false
        try await afterwards({ if !deleted { try await client.deleteSection(section.id) } }) {
            #expect(section.name == name)
            // An administrator's sidebar lists it last, empty; New room offers it to everyone.
            let listed = try await client.sidebar().sections
            #expect(listed.last?.id == section.id)
            #expect(listed.last?.roomIds.isEmpty == true)
            let sam = try await signedIn(as: "sam@example.com")
            #expect(try await sam.newRoomForm().sections.contains { $0.id == section.id && $0.rooms == 0 })
            #expect(try await sam.sidebar().sections.contains { $0.id == section.id } == false)

            let forbidden = await #expect(throws: EmberError.self) { try await sam.makeSection(named: uniqueRoomName()) }
            #expect(forbidden?.status == 403)
            let taken = await #expect(throws: EmberError.self) { try await client.makeSection(named: name.uppercased()) }
            #expect(taken?.status == 409)

            let renamed = try await client.renameSection(section.id, to: name + " renamed")
            #expect(renamed == RoomSection(id: section.id, name: name + " renamed"))
            #expect(try await client.sidebar().sections.last?.name == name + " renamed")

            try await client.deleteSection(section.id)
            deleted = true
            #expect(try await client.sidebar().sections.contains { $0.id == section.id } == false)
            let gone = await #expect(throws: EmberError.self) { try await client.renameSection(section.id, to: name) }
            #expect(gone?.status == 404)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aRoomGoesInASectionWhenItsMadeAndWhenItsChanged() async throws {
        let client = try await signedIn()
        let section = try await client.makeSection(named: uniqueRoomName())
        var room: RoomID?
        var sections = [section.id]
        try await afterwards({
            if let room { try? await client.deleteRoom(room) }
            for id in sections { try? await client.deleteSection(id) }
        }) {
            let made = try await client.createRoom(NewRoom(name: uniqueRoomName(), section: .section(section.id)))
            room = made.id
            let settings = try await client.roomSettings(made.id)
            #expect(settings.section == section)
            #expect(settings.sections.contains { $0.id == section.id && $0.rooms == 1 })
            #expect(try await client.sidebar().sections.first { $0.id == section.id }?.roomIds == [made.id])

            _ = try await client.changeRoom(made.id, RoomChanges(section: .noSection))
            #expect(try await client.roomSettings(made.id).section == nil)
            #expect(try await client.sidebar().sections.first { $0.id == section.id }?.roomIds.isEmpty == true)

            // A name that is no section's makes one, last, and puts the room in it.
            let other = uniqueRoomName()
            _ = try await client.changeRoom(made.id, RoomChanges(section: .new(name: other)))
            let placed = try #require(try await client.roomSettings(made.id).section)
            sections.append(placed.id)
            #expect(placed.name == other)
            #expect(placed.id != section.id)
            #expect(try await client.sidebar().sections.last?.id == placed.id)

            // Only an administrator makes a section that way.
            let sam = try await signedIn(as: "sam@example.com")
            let forbidden = await #expect(throws: EmberError.self) {
                try await sam.createRoom(NewRoom(name: uniqueRoomName(), section: .new(name: uniqueRoomName())))
            }
            #expect(forbidden?.status == 403)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aWorkspaceMakesASectionAndListsItsRoomUnderIt() async throws {
        let client = try await signedIn()
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        let section = try await workspace.makeSection(named: uniqueRoomName())
        var room: RoomID?
        try await afterwards({
            if let room { try? await client.deleteRoom(room) }
            try? await client.deleteSection(section.id)
        }) {
            #expect(workspace.sections.last?.id == section.id)
            // With no room in it, the sidebar has nothing to list under it.
            #expect(workspace.sectionedRooms.sections.contains { $0.id == section.id } == false)

            let made = try await workspace.createRoom(NewRoom(name: uniqueRoomName(), section: .section(section.id)))
            room = made.id
            #expect(await eventually { workspace.sectionedRooms.sections.first { $0.id == section.id }?.rooms.map(\.id) == [made.id] })
            #expect(workspace.sectionedRooms.loose.contains { $0.id == made.id } == false)

            let renamed = try await workspace.renameSection(section.id, to: section.name + " renamed")
            #expect(renamed.name == section.name + " renamed")
            #expect(workspace.sectionedRooms.sections.first { $0.id == section.id }?.section == renamed)

            try await workspace.changeRoom(made.id, RoomChanges(section: .noSection))
            #expect(await eventually { workspace.sectionedRooms.loose.contains { $0.id == made.id } })
            #expect(workspace.sectionedRooms.sections.contains { $0.id == section.id } == false)

            try await workspace.deleteSection(section.id)
            #expect(workspace.sections.contains { $0.id == section.id } == false)
            #expect(try await client.sidebar().sections.contains { $0.id == section.id } == false)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aLayoutOrdersTheSectionsAndPlacesRoomsForEveryoneAndIsPutBack() async throws {
        let client = try await signedIn()
        let before = try await client.sidebar()
        let product = try #require(before.sections.first { $0.name == "Product" }, "The seed has a Product section.")
        let company = try #require(before.sections.first { $0.name == "Company" }, "The seed has a Company section.")
        let support = try #require(before.rooms.first { $0.room.name == "Support" }?.id)
        try #require(!before.sections.contains { $0.roomIds.contains(support) }, "Support is in no section in the seed.")
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        let sam = try await loadedWorkspace(on: try await signedIn(as: "sam@example.com"))
        defer { sam.stop() }

        #expect(workspace.sections == before.sections)
        let listed = workspace.sectionedRooms
        // A room you've starred is listed with the ones in no section.
        let starred = Set(before.favorites.rooms)
        #expect(Set(listed.sections.first { $0.id == product.id }?.rooms.map(\.id) ?? []) == Set(product.roomIds).subtracting(starred))
        #expect(product.roomIds.filter(starred.contains).allSatisfy { id in listed.loose.contains { $0.id == id } })
        #expect(listed.sections.first { $0.id == company.id }?.rooms.map(\.id) == company.roomIds)
        #expect(listed.loose.contains { $0.id == support })

        // Every room the layout touches: the order as it is, then the sections' rooms it leaves out.
        let placed = before.sections.flatMap(\.roomIds) + [support]
        let rooms = before.sharedOrder + placed.filter { !before.sharedOrder.contains($0) }
        try await afterwards({
            // The sections first, with every room named, then the order alone, which leaves them be.
            _ = try await client.setRoomLayout(RoomLayout(roomIds: rooms, sections: before.sections.map { RoomLayout.Placement(id: $0.id, roomIds: $0.roomIds) }))
            _ = try await client.setSharedOrder(before.sharedOrder)
        }) {
            await workspace.saveRoomLayout(RoomLayout(roomIds: rooms, sections: [
                RoomLayout.Placement(id: company.id, roomIds: company.roomIds),
                RoomLayout.Placement(id: product.id, roomIds: product.roomIds + [support]),
            ]))
            #expect(workspace.notice == nil)
            #expect(workspace.sharedOrder == rooms)
            #expect(workspace.sections.prefix(2).map(\.name) == ["Company", "Product"])
            #expect(workspace.sectionedRooms.sections.first { $0.id == product.id }?.rooms.contains { $0.id == support } == true)
            #expect(workspace.sectionedRooms.loose.contains { $0.id == support } == false)

            let saved = try await client.sidebar()
            #expect(saved.sharedOrder == rooms)
            #expect(saved.sections == workspace.sections)
            // Everyone is told, and reads it again.
            #expect(await eventually {
                sam.sections.prefix(2).map(\.name) == ["Company", "Product"]
                    && sam.sectionedRooms.sections.first { $0.id == product.id }?.rooms.contains { $0.id == support } == true
            })

            // Someone who isn't an administrator is refused, and what's there stays.
            await sam.saveRoomLayout(RoomLayout(roomIds: [support]))
            #expect(sam.notice != nil)
            #expect(try await client.sidebar().sharedOrder == rooms)
        }
        let after = try await client.sidebar()
        #expect(after.sharedOrder == before.sharedOrder)
        #expect(after.sections == before.sections)
        #expect(await eventually { workspace.sections == before.sections && workspace.sharedOrder == before.sharedOrder })
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func addsAndRemovesAClosedRoomsMembers() async throws {
        let client = try await signedIn()
        let me = try await client.me()
        // People, as a mention notifies no bot.
        let others = try await client.directory().users.filter { $0.id != me.id && $0.role != .bot && $0.status == .active }.map(\.id)
        try #require(others.count >= 2)
        let room = try await client.createRoom(NewRoom(name: uniqueRoomName(), access: .closed(memberIDs: [me.id, others[0]])))
        try await afterwards({ try await client.deleteRoom(room.id) }) {
            #expect(Set(try await client.roomSettings(room.id).people.filter(\.member).map(\.id)) == [me.id, others[0]])

            let changed = try await client.changeMembers(of: room.id, adding: [others[1]], removing: [others[0]])
            #expect(changed.id == room.id)
            #expect(changed.kind == .closed)
            #expect(Set(try await client.roomSettings(room.id).people.filter(\.member).map(\.id)) == [me.id, others[1]])

            // A closed room has @here and @channel, which reach the one other person in it.
            let counts = try await client.notified(in: room.id)
            #expect(counts.members == 2)
            #expect(counts.mentions[.channel] == 1)
            #expect(counts.mentions[.everyone] == nil)
            // A room this small isn't one to ask about first.
            #expect(counts.members < Limits.warnedRoom)
            #expect(counts.notifying([.channel]) == nil)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func anOpenRoomSaysWhomItsMentionsWouldNotifyUntilTheyreTurnedOff() async throws {
        let client = try await signedIn()
        let room = try await client.createRoom(NewRoom(name: uniqueRoomName()))
        try await afterwards({ try await client.deleteRoom(room.id) }) {
            #expect(room.allowsChannelMentions)
            let counts = try await client.notified(in: room.id)
            let channel = try #require(counts.mentions[.channel])
            #expect(counts.members == channel + 1)
            #expect(counts.mentions[.everyone] == channel)
            let here = try #require(counts.mentions[.here])
            #expect(here <= channel)
            // The widest mention made is the one that notifies.
            #expect(counts.notifying([.here, .everyone]) == Notifying(mention: .everyone, people: channel))
            #expect(counts.notifying([]) == nil)
            #expect(try await client.roomSettings(room.id).canChangeChannelMentions)

            let off = try await client.changeRoom(room.id, RoomChanges(channelMentions: false))
            #expect(off.channelMentions == false)
            #expect(!off.allowsChannelMentions)
            #expect(try await client.sidebar().rooms.first { $0.id == room.id }?.room.allowsChannelMentions == false)
            let none = try await client.notified(in: room.id)
            #expect(none.mentions.isEmpty)
            #expect(none.notifying([.channel]) == nil)

            let on = try await client.changeRoom(room.id, RoomChanges(channelMentions: true))
            #expect(on.allowsChannelMentions)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func mentionsAreCountedForWhomTheyReachAndReadingClearsThem() async throws {
        let client = try await signedIn()
        let samClient = try await signedIn(as: "sam@example.com")
        let sam = try await loadedWorkspace(on: samClient)
        defer { sam.stop() }
        let room = try await client.createRoom(NewRoom(name: uniqueRoomName()))
        try await afterwards({ try await client.deleteRoom(room.id) }) {
            #expect(await eventually { sam.room(room.id) != nil })
            let session = RoomSession(client: client, roomID: room.id)
            session.start()
            defer { session.stop() }
            try #require(await eventually { session.timeline.isLoaded && session.status == .open })

            // Unread, with nobody mentioned, has no count.
            _ = session.send(body: "<p>Morning</p>", plainText: "Morning")
            #expect(await eventually { sam.room(room.id)?.unread == true })
            #expect(sam.room(room.id)?.mentionCount == nil)

            let standup = session.send(body: RichText.body(from: [.specialMention(.channel), .text(" standup")]), plainText: "@channel standup")
            #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == standup } })
            let sent = try #require(session.timeline.messages.first { $0.clientMessageId == standup })
            #expect(sent.notifies == .channel)
            #expect(sent.plainText == "@channel standup")
            let document = RichText.document(html: sent.body, plainText: sent.plainText, host: origin.host() ?? "")
            if case let .paragraph(inlines)? = document.blocks.first {
                #expect(inlines.first?.special == .channel)
            } else {
                Issue.record("The body isn't one paragraph.")
            }
            #expect(await eventually { sam.room(room.id)?.mentionCount == 1 })
            #expect(try await samClient.sidebar().rooms.first { $0.id == room.id }?.mentionCount == 1)

            // A mention of the person counts as well.
            let named = RichText.body(from: [.mention(sam.me.id, name: sam.me.name), .text(" one for you")])
            _ = session.send(body: named, plainText: "@\(sam.me.name) one for you")
            #expect(await eventually { sam.room(room.id)?.mentionCount == 2 })

            // Opening the room reads it.
            let reading = RoomSession(client: samClient, roomID: room.id)
            reading.start()
            defer { reading.stop() }
            #expect(await eventually { sam.room(room.id)?.unread == false })
            #expect(sam.room(room.id)?.mentionCount == nil)
            #expect(try await samClient.sidebar().rooms.first { $0.id == room.id }?.mentionCount == nil)
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func aMentionOfARoomIsKeptAndReadsAsItsName() async throws {
        let client = try await signedIn()
        let design = try #require(try await client.sidebar().rooms.first { $0.room.name == "Design" }?.id)
        let room = try await client.createRoom(NewRoom(name: uniqueRoomName()))
        try await afterwards({ try await client.deleteRoom(room.id) }) {
            let session = RoomSession(client: client, roomID: room.id)
            session.start()
            defer { session.stop() }
            try #require(await eventually { session.timeline.isLoaded && session.status == .open })

            let segments = RichText.segments("See #Design first", mentions: [:], rooms: [design: "Design"])
            #expect(segments == [.text("See "), .roomMention(design, name: "Design"), .text(" first")])
            let id = session.send(body: RichText.body(from: segments), plainText: "See #Design first")
            #expect(await eventually { session.timeline.messages.contains { $0.clientMessageId == id } })
            let sent = try #require(session.timeline.messages.first { $0.clientMessageId == id })
            #expect(sent.plainText == "See #Design first")
            #expect(sent.notifies == nil)
            #expect(EditableBody(body: sent.body, mentionNames: [:], roomNames: [design: "Design"]).text == "See #Design first")
        }
    }

    @MainActor @Test(.enabled(if: liveStandIn, "Only against the local stand-in"))
    func pausesNotificationsAndResumesThem() async throws {
        let client = try await signedIn()
        let workspace = try await loadedWorkspace(on: client)
        defer { workspace.stop() }
        let sam = try await loadedWorkspace(on: try await signedIn(as: "sam@example.com"))
        defer { sam.stop() }
        let me = workspace.me.id
        try #require(workspace.person(me)?.pausedUntil == nil, "Nobody is paused in the seed.")
        // To the second, as the server keeps it to the millisecond.
        let until = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 3600).rounded())

        try await afterwards({ _ = try await client.pauseNotifications(until: nil) }) {
            try await workspace.pauseNotifications(until: until)
            #expect(workspace.person(me)?.pausedUntil == until)
            #expect(try await client.directory().users.first { $0.id == me }?.pausedUntil == until)
            #expect(await eventually { sam.person(me)?.pausedUntil == until })

            // A week at most.
            let error = await #expect(throws: EmberError.self) {
                try await workspace.pauseNotifications(until: Date.now.addingTimeInterval(Limits.longestPause + 86400))
            }
            #expect(error?.status == 422)
            #expect(workspace.person(me)?.pausedUntil == until)

            try await workspace.pauseNotifications(until: nil)
            #expect(workspace.person(me)?.pausedUntil == nil)
            #expect(await eventually { sam.person(me)?.pausedUntil == nil })
            #expect(try await client.directory().users.first { $0.id == me }?.pausedUntil == nil)
        }
    }
}
