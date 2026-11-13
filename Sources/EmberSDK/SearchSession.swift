import Foundation
import Observation

/// A search as a screen holds it: the query being edited, the results of the one last run, and the
/// pages after them. Observable, so SwiftUI redraws as it changes.
///
/// Searching runs when `run(history:)` is called, never as `query` changes. A newer search cancels the
/// one before it, and an answer that arrives after that is dropped, so the results shown are always
/// for the latest search run. A further page continues the query the shown results are for, even if
/// `query` has been edited since.
@MainActor @Observable
public final class SearchSession {
    /// Where a search is.
    public enum Phase: Equatable, Sendable {
        /// Nothing has been run, or the session was reset.
        case idle
        /// A search is on its way.
        case searching
        /// The results are in `matches`.
        case loaded
        /// The search failed, with the server's words.
        case failed(String)
    }

    /// The words and filters being edited.
    public var query: SearchQuery
    /// The order of the matches.
    public var sort: SearchSort

    /// Where the last search is.
    public private(set) var phase: Phase = .idle
    /// The matches found so far, in `sort` order, with the pages loaded since.
    public private(set) var matches: [SearchMatch] = []
    /// The rooms the matches are in, by id.
    public private(set) var rooms: [RoomID: Room] = [:]
    /// The cursor of the next page, or nil when there is none.
    public private(set) var next: Int?
    /// The recent searches the server keeps for the signed-in person.
    public private(set) var recent: [SearchQuery] = []
    /// Whether a further page is on its way.
    public private(set) var isLoadingMore = false
    /// Why the last further page failed, until the next search or page.
    public private(set) var moreFailure: String?

    private let client: EmberClient
    private var task: Task<Void, Never>?
    /// Bumped by every new search, so an answer that arrives late can tell it's out of date.
    private var generation = 0
    /// The query and order the shown results are for, which is what a further page continues.
    private var shown: (query: SearchQuery, sort: SearchSort)?

    /// An empty session that searches through `client`.
    public init(client: EmberClient, query: SearchQuery = SearchQuery(), sort: SearchSort = .newest) {
        self.client = client
        self.query = query
        self.sort = sort
    }

    /// The query with its words trimmed, which is what is sent.
    public var trimmedQuery: SearchQuery {
        var trimmed = query
        trimmed.q = query.q.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    /// Whether more matches can be asked for.
    public var canLoadMore: Bool {
        phase == .loaded && next != nil && !isLoadingMore
    }

    /// Reads the recent searches, which is all a search with no words or filters answers. Does nothing
    /// once a search has been run.
    public func loadRecent() async {
        guard phase == .idle else { return }
        if let results = try? await client.search(SearchQuery()), phase == .idle {
            recent = results.recent
        }
    }

    /// Runs the search `query` describes, and cancels any before it. `.record` is for one someone
    /// typed, which saves it in their recent searches on the server; `.skip` saves nothing. A query
    /// with no words and no filters runs nothing: it resets the session.
    public func run(history: SearchHistory) {
        task?.cancel()
        generation += 1
        let generation = generation
        let query = trimmedQuery
        let sort = sort
        guard query.isSearchable else {
            reset()
            return
        }
        phase = .searching
        isLoadingMore = false
        moreFailure = nil
        let client = client
        task = Task { [weak self] in
            do {
                let results = try await client.search(query, sort: sort, history: history)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.matches = results.matches
                self.rooms = Dictionary(results.rooms.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                self.next = results.next
                self.recent = results.recent
                self.shown = (query, sort)
                self.phase = .loaded
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs a recent search again, as if it had been typed.
    public func run(_ recent: SearchQuery) {
        query = recent
        run(history: .record)
    }

    /// Loads the page after the last one, when there is one. A page already on its way is not asked for twice.
    public func loadMore() {
        guard canLoadMore, let cursor = next, let shown else { return }
        isLoadingMore = true
        moreFailure = nil
        let generation = generation
        let client = client
        task = Task { [weak self] in
            do {
                let results = try await client.search(shown.query, sort: shown.sort, cursor: cursor, history: .skip)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                let known = Set(self.matches.map(\.id))
                self.matches += results.matches.filter { !known.contains($0.id) }
                for room in results.rooms { self.rooms[room.id] = room }
                self.next = results.next
                self.isLoadingMore = false
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.moreFailure = error.localizedDescription
                self.isLoadingMore = false
            }
        }
    }

    /// Runs `query`, as it stands now, without recording it: after a failure.
    public func retry() {
        run(history: .skip)
    }

    /// Clears the filters, keeping the words.
    public func clearFilters() {
        query.roomID = nil
        query.from = nil
        query.withMe = false
        query.hasLink = false
        query.hasFile = false
        query.inThread = false
    }

    /// Drops the results and goes back to idle, cancelling any search on its way. `query` stays as it is.
    public func reset() {
        task?.cancel()
        generation += 1
        phase = .idle
        matches = []
        rooms = [:]
        next = nil
        shown = nil
        isLoadingMore = false
        moreFailure = nil
    }

    /// Asks the server to forget the recent searches, and empties `recent` once it has. A failure
    /// leaves them showing.
    public func clearRecent() async {
        do {
            try await client.clearRecentSearches()
            recent = []
        } catch {
            return
        }
    }
}
