import Foundation

/// Writes one `UnsentMessageStore`'s lists off the main actor, one operation at a time, in the order
/// they were asked for. Only the newest list for a key waits: a newer one takes the place of one not
/// yet written. Every session on a store shares its writer, so a session made later sees what an
/// earlier one handed over and hasn't been written yet.
///
/// A list that fails to be written is kept, and goes again at the next `retry`. So is a removal,
/// before which nothing of that account is written. Nothing handed over before an account's
/// removal is written after it.
@MainActor final class UnsentWriter {
    // MARK: One writer a store

    private struct Entry {
        weak var store: (any UnsentMessageStore)?
        let writer: UnsentWriter
    }

    /// The writers of the stores still alive. Keyed by identity, and checked with `===`, since a
    /// store gone may leave its address to another.
    private static var entries: [ObjectIdentifier: [Entry]] = [:]

    /// The writer for `store`, made the first time it's asked for.
    static func writer(for store: any UnsentMessageStore) -> UnsentWriter {
        entries = entries.compactMapValues { list in
            let live = list.filter { $0.store != nil }
            return live.isEmpty ? nil : live
        }
        let id = ObjectIdentifier(store)
        if let entry = entries[id]?.first(where: { $0.store === store }) { return entry.writer }
        let writer = UnsentWriter(store: store)
        entries[id, default: []].append(Entry(store: store, writer: writer))
        return writer
    }

    // MARK: State

    struct Account: Hashable {
        var server: URL
        var userID: UserID

        init(server: URL, userID: UserID) {
            self.server = server
            self.userID = userID
        }

        init(_ key: UnsentMessageKey) {
            self.init(server: key.server, userID: key.userID)
        }
    }

    enum Operation: Hashable {
        case save(UnsentMessageKey)
        case remove(Account)
    }

    /// What a session hears of its key.
    enum Outcome {
        case saved([UnsentMessage])
        case failed(UnsentStoreError)
        case removed
    }

    private weak var store: (any UnsentMessageStore)?
    /// The store, held while anything is waiting, going or failed, so none of it is lost.
    private var heldStore: (any UnsentMessageStore)?

    /// Each operation handed over takes the next number, so a flush can wait for those before it
    /// and not for those after. A list that takes the place of one waiting or failed keeps its number.
    private var lastTicket = 0
    /// What's waiting, in order, with its number. A key is in `pending` exactly when its `.save` is here.
    private var queue: [Operation] = []
    private var tickets: [Operation: Int] = [:]
    private var pending: [UnsentMessageKey: [UnsentMessage]] = [:]
    /// The operation going now: for a save, its list, and whether its account was discarded since.
    private var inFlight: (operation: Operation, messages: [UnsentMessage], ticket: Int, discarded: Bool)?
    private var failedSaves: [UnsentMessageKey: (messages: [UnsentMessage], error: UnsentStoreError, ticket: Int)] = [:]
    private var failedSaveOrder: [UnsentMessageKey] = []
    private var failedRemovals: [Account: (error: UnsentStoreError, ticket: Int)] = [:]
    private var failedRemovalOrder: [Account] = []
    private var isDraining = false

    private struct Listener {
        weak var session: RoomSession?
    }

    private var listeners: [UnsentMessageKey: [Listener]] = [:]

    private struct Waiter {
        let id: Int
        /// Nil while not done, else what to resume with.
        let check: @MainActor () -> Result<Void, UnsentStoreError>?
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var lastWaiterID = 0

    private init(store: any UnsentMessageStore) {
        self.store = store
    }

    // MARK: Asking

    /// The list for `key` last handed over and not yet known written: waiting, going or failed. An
    /// account's removal not yet done answers empty. Nil when everything handed over is written.
    func handed(for key: UnsentMessageKey) -> [UnsentMessage]? {
        if let messages = pending[key] { return messages }
        if let failed = failedSaves[key] { return failed.messages }
        let account = Account(key)
        if isRemoving(account) || failedRemovals[account] != nil { return [] }
        if let inFlight, inFlight.operation == .save(key) { return inFlight.messages }
        return nil
    }

    /// Hands over `messages` for `key`, in place of any list for it still waiting.
    func save(_ messages: [UnsentMessage], for key: UnsentMessageKey) {
        let ticket = failedSaves[key]?.ticket ?? nextTicket()
        clearFailure(key)
        pending[key] = messages
        enqueue(.save(key), ticket)
        drain()
    }

    /// Forgets what's saved for an account, after what's going now: its saves still waiting or
    /// failed are dropped, and one going now isn't kept should it fail. Throws what the store threw.
    func discard(server: URL, userID: UserID) async throws {
        let account = Account(server: server, userID: userID)
        for key in pending.keys where Account(key) == account {
            pending[key] = nil
            dequeue(.save(key))
        }
        for key in failedSaveOrder where Account(key) == account { clearFailure(key) }
        if case let .save(key)? = inFlight?.operation, Account(key) == account { inFlight?.discarded = true }
        let ticket = nextTicket()
        enqueue(.remove(account), ticket)
        drain()
        try await wait { writer in writer.outcome(through: ticket) { $0 == .remove(account) } }
    }

    /// Hands over again what failed: removals first, then saves. Only for `key` (and its account's
    /// removal) when given.
    func retry(_ key: UnsentMessageKey? = nil) {
        for account in failedRemovalOrder where key.map({ Account($0) == account }) ?? true {
            if let failed = failedRemovals[account] { enqueue(.remove(account), failed.ticket) }
        }
        for failedKey in failedSaveOrder where key.map({ $0 == failedKey }) ?? true {
            if let failed = failedSaves[failedKey], pending[failedKey] == nil {
                clearFailure(failedKey)
                pending[failedKey] = failed.messages
                enqueue(.save(failedKey), failed.ticket)
            }
        }
        drain()
    }

    /// Waits for `key`'s list, as handed over before the call, to be written, failures tried again
    /// first. Throws the store's error should it fail again, and `CancellationError` once the task
    /// is cancelled.
    func flush(_ key: UnsentMessageKey) async throws {
        retry(key)
        let mark = lastTicket
        try await wait { writer in writer.outcome(through: mark) { $0 == .save(key) || $0 == .remove(Account(key)) } }
    }

    /// Waits for everything handed over before the call to be written, failures tried again first;
    /// what's handed over after doesn't hold it up. Throws the first failure, should any stay, and
    /// `CancellationError` once the task is cancelled.
    func flush() async throws {
        retry()
        let mark = lastTicket
        try await wait { writer in writer.outcome(through: mark) { _ in true } }
    }

    /// Whether `key`'s list is written, waiting or failed.
    func state(for key: UnsentMessageKey) -> UnsentState {
        if pending[key] != nil || inFlight?.operation == .save(key) { return .saving }
        if let failed = failedSaves[key] { return .failed(failed.error) }
        let account = Account(key)
        if isRemoving(account) { return .saving }
        if let failed = failedRemovals[account] { return .failed(failed.error) }
        return .saved
    }

    /// Tells `session` how each operation on `key` goes.
    func listen(_ session: RoomSession, to key: UnsentMessageKey) {
        var list = listeners[key, default: []].filter { $0.session != nil }
        if !list.contains(where: { $0.session === session }) { list.append(Listener(session: session)) }
        listeners[key] = list
    }

    // MARK: Writing

    private func nextTicket() -> Int {
        lastTicket += 1
        return lastTicket
    }

    private func isRemoving(_ account: Account) -> Bool {
        tickets[.remove(account)] != nil || inFlight?.operation == .remove(account)
    }

    /// Puts `operation` in the queue, or, when it's there already, leaves it in its place with the
    /// older of the two numbers.
    private func enqueue(_ operation: Operation, _ ticket: Int) {
        if let queued = tickets[operation] {
            tickets[operation] = min(queued, ticket)
        } else {
            queue.append(operation)
            tickets[operation] = ticket
        }
    }

    private func dequeue(_ operation: Operation) {
        guard tickets.removeValue(forKey: operation) != nil else { return }
        queue.removeAll { $0 == operation }
    }

    private func clearFailure(_ key: UnsentMessageKey) {
        guard failedSaves.removeValue(forKey: key) != nil else { return }
        failedSaveOrder.removeAll { $0 == key }
    }

    private func drain() {
        guard !isDraining, !queue.isEmpty, let store = heldStore ?? store else {
            resolveWaiters()
            releaseIfIdle()
            return
        }
        heldStore = store
        isDraining = true
        Task { await run(store) }
    }

    private func run(_ store: any UnsentMessageStore) async {
        while !queue.isEmpty {
            let operation = queue.removeFirst()
            let ticket = tickets.removeValue(forKey: operation) ?? lastTicket
            switch operation {
            case let .save(key):
                guard let messages = pending.removeValue(forKey: key) else { continue }
                if let removal = failedRemovals[Account(key)] {
                    // Written now, it would come back once the removal goes.
                    fail(key, messages, removal.error, ticket)
                    break
                }
                inFlight = (operation, messages, ticket, false)
                let error = await Task.detached { () -> (any Error)? in
                    do { try store.save(messages, for: key) } catch { return error }
                    return nil
                }.value
                let discarded = inFlight?.discarded ?? false
                inFlight = nil
                if let error {
                    // Handed over before its account was discarded, it mustn't be written after.
                    if !discarded { fail(key, messages, UnsentStoreError(error, as: .unwritable), ticket) }
                } else {
                    tell(key, .saved(messages))
                }
            case let .remove(account):
                inFlight = (operation, [], ticket, false)
                let error = await Task.detached { () -> (any Error)? in
                    do { try store.removeAll(server: account.server, userID: account.userID) } catch { return error }
                    return nil
                }.value
                inFlight = nil
                if let error {
                    let error = UnsentStoreError(error, as: .couldNotRemove)
                    if failedRemovals.updateValue((error, ticket), forKey: account) == nil { failedRemovalOrder.append(account) }
                    for key in listeners.keys where Account(key) == account { tell(key, .failed(error)) }
                } else {
                    failedRemovals[account] = nil
                    failedRemovalOrder.removeAll { $0 == account }
                    for key in listeners.keys where Account(key) == account { tell(key, .removed) }
                    // Saves held back behind the removal were handed over after it, so go now.
                    for key in failedSaveOrder where Account(key) == account && pending[key] == nil {
                        if let failed = failedSaves[key] {
                            clearFailure(key)
                            pending[key] = failed.messages
                            enqueue(.save(key), failed.ticket)
                        }
                    }
                }
            }
            resolveWaiters()
        }
        isDraining = false
        resolveWaiters()
        releaseIfIdle()
    }

    private func fail(_ key: UnsentMessageKey, _ messages: [UnsentMessage], _ error: UnsentStoreError, _ ticket: Int) {
        if failedSaves.updateValue((messages, error, ticket), forKey: key) == nil { failedSaveOrder.append(key) }
        tell(key, .failed(error))
    }

    private func tell(_ key: UnsentMessageKey, _ outcome: Outcome) {
        for listener in listeners[key] ?? [] { listener.session?.unsentWritten(outcome) }
    }

    private func releaseIfIdle() {
        if queue.isEmpty, inFlight == nil, failedSaves.isEmpty, failedRemovals.isEmpty { heldStore = nil }
    }

    // MARK: Waiting

    /// Nil while an operation `matching` numbered up to `mark` is waiting or going; then the first
    /// failure of one, else success.
    private func outcome(through mark: Int, matching: (Operation) -> Bool) -> Result<Void, UnsentStoreError>? {
        if queue.contains(where: { matching($0) && (tickets[$0] ?? 0) <= mark }) { return nil }
        if let inFlight, matching(inFlight.operation), inFlight.ticket <= mark { return nil }
        for account in failedRemovalOrder where matching(.remove(account)) {
            if let failed = failedRemovals[account], failed.ticket <= mark { return .failure(failed.error) }
        }
        for key in failedSaveOrder where matching(.save(key)) {
            if let failed = failedSaves[key], failed.ticket <= mark { return .failure(failed.error) }
        }
        return .success(())
    }

    /// Returns once `check` answers, with what it answers. It's asked now and after each operation.
    /// Throws `CancellationError` once the task is cancelled, and `.unwritable` should the store
    /// be gone with work still waiting.
    private func wait(_ check: @escaping @MainActor (UnsentWriter) -> Result<Void, UnsentStoreError>?) async throws {
        if let result = check(self) { return try result.get() }
        lastWaiterID += 1
        let id = lastWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, check: { check(self) }, continuation: continuation))
                    resolveWaiters()
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resolveWaiters() {
        if !isDraining, !queue.isEmpty, heldStore == nil, store == nil {
            // The store is gone, so nothing waiting will be written.
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.continuation.resume(throwing: UnsentStoreError(.unwritable)) }
            return
        }
        var waiting: [Waiter] = []
        for waiter in waiters {
            if let result = waiter.check() {
                waiter.continuation.resume(with: result.mapError { $0 as any Error })
            } else {
                waiting.append(waiter)
            }
        }
        waiters = waiting
    }
}
