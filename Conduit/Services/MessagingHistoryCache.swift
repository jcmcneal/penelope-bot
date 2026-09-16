import Combine
import Foundation

/// A connection-owned query cache. The owner resets it whenever its verified identity changes.
/// Eviction only removes warm snapshots: an open reader keeps all of its loaded pages.
@MainActor
final class MessagingHistoryCache {
    let changes = PassthroughSubject<(key: String?, history: MessagingHistory?), Never>()
    private struct Entry {
        let history: MessagingHistory
        let cost: Int
        var access: UInt64
        let savedAt: Date
    }
    private struct RequestKey: Hashable {
        let destination: String
        let before: Int?
    }
    private struct Flight {
        let id: UUID
        let task: Task<MessagingHistory, Error>
    }
    private var entries: [String: Entry] = [:]
    private var flights: [RequestKey: Flight] = [:]
    private var access: UInt64 = 0
    private var epoch = UUID()
    private var revisions: [String: UUID] = [:]
    private let maxConversations: Int
    private let maxBytes: Int
    private let persistence: MessagingHistoryPersistence
    private let persistenceDelay: Duration
    private var persistenceTask: Task<Void, Never>?
    private var persistenceDirty = false
    private var partition: String?
    private var isHydrated = false

    init(maxConversations: Int = 24, maxBytes: Int = 8_000_000, persistenceDirectory: URL? = nil,
         persistenceTTL: TimeInterval = 7 * 24 * 60 * 60, persistenceDelay: Duration = .milliseconds(250)) {
        self.maxConversations = maxConversations
        self.maxBytes = maxBytes
        self.persistenceDelay = persistenceDelay
        persistence = MessagingHistoryPersistence(directory: persistenceDirectory, ttl: persistenceTTL,
                                                   maxConversations: maxConversations, maxBytes: maxBytes)
    }

    deinit {
        persistenceTask?.cancel()
        if persistenceDirty, let partition {
            let records = entries.mapValues { entry in
                let display = MessagingHistory(conversation: entry.history.conversation, messages: entry.history.messages,
                                               runs: [], before: entry.history.before)
                return MessagingHistoryPersistence.Record(history: display, savedAt: entry.savedAt, access: entry.access)
            }
            persistence.save(partition: partition, records: records)
        }
    }

    /// Await local hydration before discovery/history requests. Restored rows are display-only;
    /// live run state and messaging authority always come from the fresh authenticated service.
    func configure(partition: String?) async {
        let normalized = partition.flatMap { $0.isEmpty ? nil : $0 }
        guard normalized != self.partition || !isHydrated else { return }
        reset()
        self.partition = normalized
        guard let normalized else { return }
        let expectedEpoch = epoch
        let records = await persistence.load(partition: normalized)
        guard !Task.isCancelled, expectedEpoch == epoch, self.partition == normalized else { return }
        for (key, record) in records.sorted(by: { $0.value.access < $1.value.access }) {
            let display = Self.displayOnly(record.history)
            access &+= 1
            entries[key] = Entry(history: display, cost: Self.cost(display), access: access, savedAt: record.savedAt)
        }
        trimEntries()
        isHydrated = true
        for (key, entry) in entries { changes.send((key, entry.history)) }
    }

    /// Remove the active account's durable data. Pending old writes are ordered before the
    /// removal on the I/O queue, so a delayed completion cannot restore signed-out content.
    func purge() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceDirty = false
        if let partition { persistence.purge(partition: partition) }
        reset()
        partition = nil
    }

    /// Used at app backgrounding and by tests to drain the coalesced write plus disk queue.
    func flushPersistence() async {
        enqueuePersistence()
        await persistence.flush()
    }

    func snapshot(for destination: MessagingDestination) -> MessagingHistory? {
        guard var entry = entries[destination.id] else { return nil }
        access &+= 1
        entry.access = access
        entries[destination.id] = entry
        return entry.history
    }

    func reset() {
        enqueuePersistence()
        isHydrated = false
        epoch = UUID()
        flights.values.forEach { $0.task.cancel() }
        flights.removeAll()
        entries.removeAll()
        revisions.removeAll()
        changes.send((nil, nil))
    }

    /// Invalidate outstanding reads before a mutation refresh so a pre-mutation response cannot win.
    func invalidate(_ destination: MessagingDestination, removeSnapshot: Bool = false) {
        let key = destination.id
        revisions[key] = UUID()
        for request in flights.keys.filter({ $0.destination == key }) {
            flights.removeValue(forKey: request)?.task.cancel()
        }
        if removeSnapshot {
            entries.removeValue(forKey: key)
            changes.send((key, nil))
            persistenceDirty = true
            enqueuePersistence()
        }
    }

    func accept(_ receipt: MessagingSendReceipt, for destination: MessagingDestination, current: MessagingHistory?) {
        invalidate(destination)
        let previous = snapshot(for: destination) ?? current
        let incoming = MessagingHistory(
            conversation: receipt.conversation,
            messages: [receipt.message],
            runs: receipt.runs.isEmpty ? (previous?.runs ?? []) : receipt.runs,
            before: previous?.before
        )
        publish(Self.merge(previous, incoming: incoming), for: destination)
    }

    func load(_ destination: MessagingDestination, current: MessagingHistory?, older: Bool,
              service: MessagingService) async throws -> MessagingHistory {
        let cached = snapshot(for: destination)
        // A reader may hold more pages than the bounded warm cache retains.
        let seed = cached.map { Self.merge(current, incoming: $0) } ?? current
        let cursor = older ? seed?.before : nil
        let key = RequestKey(destination: destination.id, before: cursor)
        if let flight = flights[key] { return try await flight.task.value }
        let requestEpoch = epoch
        let revision = revisions[destination.id]
        let id = UUID()
        let task = Task { @MainActor [self] in
            do {
                let result = try await service.history(destination, before: cursor)
                try validate(result, for: destination)
                try checkContext(requestEpoch, revision: revision, destination: destination)
                var incoming = result
                if !older, let last = seed?.messages.last {
                    var messages = result.messages
                    var before = result.before
                    while let first = messages.first, first.sequence > last.sequence + 1, let pageCursor = before {
                        let page = try await service.history(destination, before: pageCursor)
                        try checkContext(requestEpoch, revision: revision, destination: destination)
                        try validate(page, for: destination)
                        guard page.conversation.id == result.conversation.id, !page.messages.isEmpty,
                              page.before == nil || page.before! < pageCursor else { throw MessagingError.invalidResponse }
                        messages = page.messages + messages
                        before = page.before
                    }
                    incoming = MessagingHistory(conversation: result.conversation, messages: messages, runs: result.runs, before: before)
                }
                try checkContext(requestEpoch, revision: revision, destination: destination)
                let previous = snapshot(for: destination).map { Self.merge(seed, incoming: $0) } ?? seed
                // Pagination may finish after a newer latest-page poll. Keep the live metadata.
                let merged = Self.merge(previous, incoming: incoming, keepCurrentMetadata: older)
                publish(merged, for: destination)
                return merged
            } catch {
                // Superseded reads cannot publish auth failures from an older request either.
                try checkContext(requestEpoch, revision: revision, destination: destination)
                throw error
            }
        }
        flights[key] = Flight(id: id, task: task)
        defer { if flights[key]?.id == id { flights.removeValue(forKey: key) } }
        return try await task.value
    }

    private func checkContext(_ expected: UUID, revision: UUID?, destination: MessagingDestination) throws {
        try Task.checkCancellation()
        guard epoch == expected, revisions[destination.id] == revision else { throw MessagingError.staleContext }
    }

    private func validate(_ result: MessagingHistory, for destination: MessagingDestination) throws {
        if let expected = destination.conversationID, result.conversation.id != expected { throw MessagingError.invalidResponse }
        if let profile = destination.profileID,
           result.conversation.kind != "dm" || result.conversation.profiles != [profile] { throw MessagingError.invalidResponse }
    }

    static func equivalent(_ lhs: MessagingHistory?, _ rhs: MessagingHistory?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.conversation == rhs.conversation && lhs.messages == rhs.messages
                && lhs.runs == rhs.runs && lhs.before == rhs.before
        default: return false
        }
    }

    static func merge(_ current: MessagingHistory?, incoming: MessagingHistory,
                              keepCurrentMetadata: Bool = false) -> MessagingHistory {
        guard let current else { return incoming }
        if equivalent(current, incoming) { return incoming }
        let messages = Dictionary((current.messages + incoming.messages).map { ($0.id, $0) },
                                  uniquingKeysWith: { _, new in new }).values.sorted { $0.sequence < $1.sequence }
        let retainsEarlierPage = (current.messages.first?.sequence ?? Int.max) < (incoming.messages.first?.sequence ?? Int.max)
        return MessagingHistory(conversation: keepCurrentMetadata ? current.conversation : incoming.conversation,
                                messages: messages, runs: keepCurrentMetadata ? current.runs : incoming.runs,
                                before: retainsEarlierPage ? current.before : incoming.before)
    }

    private func publish(_ history: MessagingHistory, for destination: MessagingDestination) {
        let existing = entries[destination.id]
        let changed = !Self.equivalent(existing?.history, history)
        let durableChanged = existing.map {
            $0.history.conversation != history.conversation || $0.history.messages != history.messages || $0.history.before != history.before
        } ?? true
        access &+= 1
        entries[destination.id] = Entry(history: history, cost: Self.cost(history), access: access,
                                       savedAt: durableChanged ? Date() : (existing?.savedAt ?? Date()))
        trimEntries()
        if changed {
            changes.send((destination.id, history))
        }
        if durableChanged { schedulePersistence() }
    }

    private func trimEntries() {
        var total = entries.values.reduce(0) { $0 + $1.cost }
        while entries.count > maxConversations || total > maxBytes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            total -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
    }

    private func schedulePersistence() {
        guard partition != nil else { return }
        persistenceDirty = true
        // Coalesce a burst without indefinitely postponing persistence during a live reply.
        guard persistenceTask == nil else { return }
        persistenceTask = Task { @MainActor [weak self, persistenceDelay] in
            do { try await Task.sleep(for: persistenceDelay) } catch { return }
            self?.enqueuePersistence()
        }
    }

    private func enqueuePersistence() {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard persistenceDirty, let partition else { return }
        persistenceDirty = false
        let records = entries.mapValues {
            MessagingHistoryPersistence.Record(history: Self.displayOnly($0.history), savedAt: $0.savedAt, access: $0.access)
        }
        persistence.save(partition: partition, records: records)
    }

    private static func displayOnly(_ history: MessagingHistory) -> MessagingHistory {
        MessagingHistory(conversation: history.conversation, messages: history.messages, runs: [], before: history.before)
    }

    private static func cost(_ history: MessagingHistory) -> Int {
        let conversation = history.conversation
        let metadataCost = [conversation.id, conversation.kind, conversation.title, conversation.defaultResponder,
                            conversation.preview].reduce(512) { $0 + $1.utf8.count }
            + conversation.profiles.reduce(0) { $0 + $1.utf8.count + 32 }
        let runsCost = history.runs.reduce(0) { $0 + $1.id.utf8.count + $1.profile.utf8.count
            + $1.status.utf8.count + $1.detail.utf8.count + 128 }
        return history.messages.reduce(metadataCost + runsCost) {
            $0 + $1.body.utf8.count + $1.id.utf8.count + $1.author.utf8.count + 192
        }
    }
}
