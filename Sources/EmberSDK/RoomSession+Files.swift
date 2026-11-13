import Foundation

/// A file on its way, and where its pending message is shown.
struct UploadJob {
    let clientMessageId: ClientMessageID
    let source: UploadSource
    /// The thread it replies in; nil for the room.
    let thread: ThreadSession?
    let delivery: ReplyDelivery
}

/// What waits in a session's queue.
enum Outgoing {
    case file(UploadJob)
    /// A message written with files, which goes once they have.
    case text(clientMessageId: ClientMessageID, frame: ClientFrame, thread: ThreadSession?)
}

/// The upload going now. `attempt` tells its answers from those of one cancelled or retried.
struct RunningUpload {
    let job: UploadJob
    let attempt: UUID
    let task: Task<Void, Never>
    /// Stops asking for background time for it.
    let endBackground: @Sendable () -> Void
}

extension RoomSession {
    // MARK: Files

    /// Posts `files`, a message each in the order given, then the text if there is any, as the
    /// web's composer does. Each shows as pending at once; the text is held until the files ahead
    /// of it have finished (posted or failed). Answers the client message ids: one for each file, in
    /// the order given, then the text's, so they pair with `files` by position.
    ///
    /// A file whose `isTooLarge` is true (over 250 MB) is refused: its id is answered all the same,
    /// to keep the positions, but nothing is pending or sent under it, one made with
    /// `.deleteWhenFinished` is deleted, and `notice` says `Uploads.tooLarge(name)`.
    ///
    /// Once the workspace has shut the session down (signed out), nothing is sent: files made with
    /// `.deleteWhenFinished` are deleted, nothing is pending, and the answer is empty, as nothing went.
    ///
    /// One file goes up at a time, over HTTP, so a socket reconnecting meanwhile doesn't stop it.
    @discardableResult
    public func send(files: [UploadSource], body: String? = nil, plainText: String? = nil) -> [ClientMessageID] {
        enqueue(files: files, body: body, plainText: plainText, thread: nil, delivery: .threadOnly)
    }

    /// The thread under `parentID`: the one already open if a screen holds it (or one let go of that
    /// still has a reply on its way), else a new one. `replyID` is a reply to open at: on a thread
    /// that's there already, its `timeline.focus` goes to that reply, paging back to it if need be;
    /// nil leaves it where it is.
    public func thread(_ parentID: MessageID, at replyID: MessageID? = nil) -> ThreadSession {
        if let thread = threads.first(where: { $0.parentID == parentID }) {
            if let replyID { thread.go(to: replyID) }
            return thread
        }
        let thread = ThreadSession(room: self, parentID: parentID, at: replyID)
        let parked = parkedReplies.filter { $0.parentId == parentID }
        if !parked.isEmpty, !isShutDown {
            parkedReplies.removeAll { $0.parentId == parentID }
            thread.restore(parked)
            keep(thread)
        }
        return thread
    }

    /// Whether anything is still going that the session has to be kept for: a file, a failed file
    /// waiting to be retried, a thread with a reply unsettled, or a message not yet confirmed. A
    /// failed file the room has since confirmed (its pending gone) isn't waiting for anything.
    var isBusy: Bool {
        // Closures here and below, not the methods by name: Swift 6.0 takes a main-actor method
        // passed by name to a rethrowing call for one that can throw.
        running != nil || !outgoing.isEmpty || !threads.isEmpty || failedUploads.values.contains { isUnconfirmed($0) }
            || hasUnsentMessages
    }

    func enqueue(files: [UploadSource], body: String?, plainText: String?, thread: ThreadSession?, delivery: ReplyDelivery) -> [ClientMessageID] {
        // A job would hold the session, and `keep` would tie the thread to it again, after sign-out.
        // No ids: one per file would pair the app's thumbnails with messages that never show.
        guard !isShutDown else {
            files.forEach { removeIfTemporary($0) }
            return []
        }
        var ids: [ClientMessageID] = []
        var refused: [String] = []
        for source in files {
            let id = ClientMessageID(UUID().uuidString.lowercased())
            // Answered all the same, so the ids still pair with `files` by position.
            ids.append(id)
            guard !source.isTooLarge else {
                refused.append(Uploads.tooLarge(source.name))
                // Nothing else would delete it: it never becomes a job.
                removeIfTemporary(source)
                continue
            }
            let upload = PendingUpload(name: source.name, contentType: source.contentType, byteSize: source.byteSize)
            if let thread {
                thread.attach(upload, delivery: delivery, clientMessageId: id)
            } else {
                timeline.attach(upload, clientMessageId: id, now: Date())
            }
            outgoing.append(.file(UploadJob(clientMessageId: id, source: source, thread: thread, delivery: delivery)))
        }
        // Each refused file named, as the web's composer names them, on the screen that sent them.
        if !refused.isEmpty {
            let text = refused.joined(separator: " ")
            if let thread { thread.notice = text } else { notice = text }
        }
        if let body, !body.isEmpty {
            let plainText = plainText ?? body
            if outgoing.isEmpty, running == nil {
                ids.append(thread?.reply(body: body, plainText: plainText, delivery: delivery) ?? send(body: body, plainText: plainText))
            } else {
                let id = ClientMessageID(UUID().uuidString.lowercased())
                let frame = thread?.hold(body: body, plainText: plainText, delivery: delivery, clientMessageId: id)
                    ?? timeline.send(body: body, plainText: plainText, clientMessageId: id)
                outgoing.append(.text(clientMessageId: id, frame: frame, thread: thread))
                ids.append(id)
            }
        }
        if let thread { keep(thread) }
        pump()
        saveUnsent()
        return ids
    }

    /// Starts the next file, sending any texts ahead of it on the way.
    func pump() {
        dropConfirmedFailures()
        guard running == nil else { return }
        while let next = outgoing.first {
            outgoing.removeFirst()
            switch next {
            case let .text(id, frame, thread):
                if let thread {
                    thread.release(frame, clientMessageId: id)
                } else if admittedPending(id) {
                    transmitMessage(frame)
                } else if timeline.pending.contains(where: { $0.clientMessageId == id && $0.failure == nil }) {
                    watchSend(id)
                }
            case let .file(job):
                begin(job)
                return
            }
        }
    }

    /// Whether a held room message is still pending (not discarded meanwhile) and can go now. One
    /// that can't waits for the check that follows the next welcome, as any message does, timed
    /// from its turn.
    private func admittedPending(_ id: ClientMessageID) -> Bool {
        isAdmitted && timeline.pending.contains { $0.clientMessageId == id && $0.failure == nil }
    }

    private func begin(_ job: UploadJob) {
        let attempt = UUID()
        let client = client
        let roomID = roomID
        let id = job.clientMessageId
        let resuming = uploadCheckpoints[id]
        let endBackground = backgroundTime.begin("Sending \(job.source.name)")
        // The task holds the session, so a file finishes even when nothing else does.
        let task = Task { @MainActor in
            do {
                let message = try await client.upload(
                    job.source, in: roomID, clientMessageId: id,
                    parentId: job.thread?.parentID, delivery: job.delivery, resuming: resuming,
                    checkpoint: { [weak self] checkpoint in await self?.checkpointed(id, attempt: attempt, checkpoint) },
                    progress: { [weak self] sent in
                        Task { @MainActor in self?.progressed(id, attempt: attempt, sent: sent) }
                    }
                )
                self.finished(job, attempt: attempt, with: .success(message))
            } catch {
                self.finished(job, attempt: attempt, with: .failure(error))
            }
        }
        running = RunningUpload(job: job, attempt: attempt, task: task, endBackground: endBackground)
    }

    private func checkpointed(_ id: ClientMessageID, attempt: UUID, _ checkpoint: UploadCheckpoint) {
        guard running?.attempt == attempt else { return }
        uploadCheckpoints[id] = checkpoint
    }

    private func progressed(_ id: ClientMessageID, attempt: UUID, sent: Int) {
        guard let running, running.attempt == attempt else { return }
        if let thread = running.job.thread {
            thread.uploadProgress(id, sentBytes: sent)
        } else {
            timeline.uploadProgress(id, sentBytes: sent)
        }
    }

    /// Whether `id` is a text held behind files. A reconnect's `message.check` finds it missing, and
    /// it isn't sent then: it goes in its turn.
    func isHeldText(_ id: ClientMessageID) -> Bool {
        outgoing.contains { if case let .text(held, _, _) = $0 { held == id } else { false } }
    }

    private func finished(_ job: UploadJob, attempt: UUID, with result: Result<Message, any Error>) {
        guard let current = running, current.attempt == attempt else { return }
        current.endBackground()
        running = nil
        let id = job.clientMessageId
        if case .success = result { uploadCheckpoints[id] = nil }
        switch result {
        case let .success(message):
            timeline.posted(message)
            job.thread?.posted(message)
            removeIfTemporary(job.source)
        case let .failure(error):
            if error is CancellationError { break }
            // The room confirmed it (`message.created` landed before the last part's answer, which
            // was then lost): it's posted, whatever the HTTP said, so it's done, not failed.
            guard isUnconfirmed(job) else {
                uploadCheckpoints[id] = nil
                removeIfTemporary(job.source)
                break
            }
            let reason = (error as? EmberError).flatMap { $0.isUnreachable ? nil : $0.message } ?? Uploads.failed
            // It may have been posted all the same, which only the room can say.
            let check = job.thread?.fail(id, reason: reason) ?? timeline.fail(id, reason: reason)
            if let check, isAdmitted { transmit(check) }
            failedUploads[id] = job
        }
        if let thread = job.thread { settle(thread) }
        pump()
    }

    /// Queues a failed file to go again, from the part after the last the server took.
    func retryUpload(_ id: ClientMessageID) {
        guard let job = failedUploads.removeValue(forKey: id) else { return }
        // Confirmed since it failed: sending it again would only post it twice.
        guard isUnconfirmed(job) else {
            uploadCheckpoints[id] = nil
            removeIfTemporary(job.source)
            return
        }
        outgoing.append(.file(job))
        if let thread = job.thread { keep(thread) }
        pump()
    }

    /// Stops a file wherever it is (going, waiting or failed) and deletes it if it was temporary.
    func discardUpload(_ id: ClientMessageID) {
        var job: UploadJob?
        uploadCheckpoints[id] = nil
        if let running, running.job.clientMessageId == id {
            running.task.cancel()
            running.endBackground()
            self.running = nil
            job = running.job
        } else if let index = outgoing.firstIndex(where: { if case let .file(job) = $0 { job.clientMessageId == id } else { false } }) {
            if case let .file(waiting) = outgoing.remove(at: index) { job = waiting }
        } else {
            job = failedUploads.removeValue(forKey: id)
        }
        guard let job else { return }
        removeIfTemporary(job.source)
        pump()
    }

    /// Stops every file, as the session is shut down.
    func cancelUploads() {
        running?.task.cancel()
        running?.endBackground()
        uploadCheckpoints = [:]
        // A cancelled job never finishes, so its temporary file goes here, as a discarded one's does.
        var dropped = running.map { [$0.job] } ?? []
        running = nil
        for item in outgoing { if case let .file(job) = item { dropped.append(job) } }
        outgoing = []
        dropped += failedUploads.values
        failedUploads = [:]
        for job in dropped { removeIfTemporary(job.source) }
    }

    /// Whether a file of `thread`'s is going or waiting, or a text of its is held behind files. A
    /// failed one isn't counted: `settle` lets go of it with the thread, as no screen can retry it.
    func hasUploads(for thread: ThreadSession) -> Bool {
        if running?.job.thread === thread { return true }
        return outgoing.contains {
            switch $0 {
            case let .file(job): job.thread === thread
            case let .text(_, _, owner): owner === thread
            }
        }
    }

    /// Whether `job`'s pending message is still shown. The pending goes only when the room confirms
    /// the message (`message.created`, a check that finds it stored, or a part's answer) or when it's
    /// discarded, which stops the job first; so a job without one was posted.
    private func isUnconfirmed(_ job: UploadJob) -> Bool {
        let id = job.clientMessageId
        let pending = job.thread?.timeline.pending ?? timeline.pending
        return pending.contains { $0.clientMessageId == id }
    }

    /// Lets go of failed files the room has confirmed since (`message.created`, or a check after the
    /// failure found them stored): there's nothing left to retry, and a temporary one is deleted.
    /// Called on every room frame, a thread's replies included, and as the queue moves.
    func dropConfirmedFailures() {
        for (id, job) in failedUploads where !isUnconfirmed(job) {
            failedUploads[id] = nil
            uploadCheckpoints[id] = nil
            removeIfTemporary(job.source)
        }
    }

    /// Deletes a source made with `.deleteWhenFinished`, and the folder it was in once that's empty:
    /// the app stages each file in a folder of its own. Never the temporary directory itself, and
    /// never further up.
    func removeIfTemporary(_ source: UploadSource) {
        guard source.disposition == .deleteWhenFinished else { return }
        try? FileManager.default.removeItem(at: source.fileURL)
        let folder = source.fileURL.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory
        guard folder.standardizedFileURL.resolvingSymlinksInPath().path != temporary.standardizedFileURL.resolvingSymlinksInPath().path else { return }
        // `rmdir` refuses a folder with anything in it, even something added since the file went.
        _ = folder.withUnsafeFileSystemRepresentation { path in path.map { rmdir($0) } }
    }

    // MARK: Threads

    /// A screen has taken a lease on `thread`: it's the most recent, and open on the socket now.
    func threadOpened(_ thread: ThreadSession) {
        threads.removeAll { $0 === thread }
        threads.append(thread)
        guard isAdmitted else { return }
        transmit(thread.opening())
        openThread = thread.parentID
    }

    /// `thread`'s last lease has closed: the server stops counting it as viewed, and the next most
    /// recent one a screen still holds is opened again in its place.
    func threadClosed(_ thread: ThreadSession) {
        if isAdmitted, openThread == thread.parentID {
            transmit(.closeThread(parentId: thread.parentID))
            openThread = nil
            if let next = threads.last(where: { $0 !== thread && $0.isHeld }) {
                transmit(next.opening())
                openThread = next.parentID
            }
        }
        settle(thread)
    }

    /// Makes sure `thread` hears the room's frames, without making it the most recent.
    func keep(_ thread: ThreadSession) {
        guard !threads.contains(where: { $0 === thread }) else { return }
        threads.insert(thread, at: 0)
    }

    /// Lets go of a thread no screen holds once nothing of it is left to settle.
    func settle(_ thread: ThreadSession) {
        guard !thread.isHeld, !thread.hasUnsettled, !hasUploads(for: thread) else { return }
        guard threads.contains(where: { $0 === thread }) else { return }
        threads.removeAll { $0 === thread }
        // Its failed replies wait for the thread to be asked for again, kept across launches meanwhile.
        if !isShutDown {
            parkedReplies += thread.timeline.pending.filter { $0.upload == nil }.map(UnsentMessage.init)
        }
        // Its failed files can't be retried once no screen has it, so they go too.
        for (id, job) in failedUploads where job.thread === thread {
            failedUploads[id] = nil
            uploadCheckpoints[id] = nil
            removeIfTemporary(job.source)
        }
    }

    /// After a welcome or resumed: each thread opens again on the new connection, the ones let go
    /// of first and the most recently opened last, since the server keeps only the last. Those let go
    /// of open only to have their replies checked, so when no screen holds a thread the last is
    /// closed again.
    func reopenThreads() {
        openThread = nil
        let lingering = threads.filter { !$0.isHeld }
        let held = threads.filter(\.isHeld)
        for thread in lingering + held {
            transmit(thread.opening())
            openThread = thread.parentID
        }
        if held.isEmpty, let last = openThread {
            transmit(.closeThread(parentId: last))
            openThread = nil
        }
    }
}
