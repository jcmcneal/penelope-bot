import Combine
import Foundation
import SwiftUI

@MainActor
final class MessagingConversationStore: ObservableObject {
    /// How long the optimistic “awaiting reply” dots stay up with no active runs.
    static var awaitingReplyTimeout: Duration = .seconds(20)
    /// After send, poll this often until runs appear or the urgent window ends.
    static var urgentPollInterval: Duration = .seconds(1)
    static var urgentPollWindow: Duration = .seconds(8)

    @Published private(set) var history: MessagingHistory?
    @Published private(set) var error: String?
    @Published private(set) var sending = false
    @Published private(set) var pending: PendingMessagingSend?
    @Published private(set) var awaitingReply = false
    /// Conversation view shortens its history poll while this is true.
    @Published private(set) var prefersUrgentPolling = false
    @Published var draft = ""
    private(set) var destination: MessagingDestination
    private let owner: MessagingStore
    private let epoch: UUID
    private let defaults: UserDefaults
    private let draftKey: String
    private var historySubscription: AnyCancellable?
    private var lastRead = 0
    private var awaitingReplyTimeoutTask: Task<Void, Never>?
    private var urgentPollingTask: Task<Void, Never>?

    init(destination: MessagingDestination, owner: MessagingStore, defaults: UserDefaults = .standard) {
        self.destination = destination; self.owner = owner; self.epoch = owner.generation; self.defaults = defaults
        // DM keys remain profile-based so first-send identity resolution never strands a draft.
        draftKey = "conduit.messaging.draft." + ((try? JSONEncoder().encode([owner.capability?.scope ?? "", destination.id]).base64EncodedString()) ?? UUID().uuidString)
        history = owner.historyCache.snapshot(for: destination)
        historySubscription = owner.historyCache.changes.sink { [weak self] change in
            guard let self, change.key == nil || change.key == self.destination.id else { return }
            guard change.history == nil || self.epoch == self.owner.generation else { return }
            self.adopt(change.history)
        }
        draft = defaults.string(forKey: draftKey) ?? ""
        if let data = defaults.data(forKey: draftKey + ".pending") {
            pending = try? JSONDecoder().decode(PendingMessagingSend.self, from: data)
            if pending != nil {
                owner.startLiveTurn(for: destination, profileID: destination.profileID)
                beginAwaitingReply()
            }
        }
    }

    deinit {
        awaitingReplyTimeoutTask?.cancel()
        urgentPollingTask?.cancel()
    }

    var canWrite: Bool { epoch == owner.generation && owner.isReady }
    func saveDraft() { defaults.set(draft, forKey: draftKey) }

    var historyPollInterval: Duration {
        if owner.liveTurn(for: destination)?.needsFastHistorySettle == true {
            return .milliseconds(250)
        }
        let hasActiveRun = history?.runs.contains { ["queued", "running"].contains($0.status.lowercased()) } == true
        return prefersUrgentPolling || hasActiveRun ? Self.urgentPollInterval : .seconds(4)
    }

    private func adopt(_ value: MessagingHistory?) {
        let merged = value.map { MessagingHistoryCache.merge(history, incoming: $0) }
        if !MessagingHistoryCache.equivalent(history, merged) { history = merged }
        owner.syncLiveTurn(for: destination, history: merged ?? history)
        refreshAwaitingReplyFromRuns()
    }

    func load(older: Bool = false) async {
        guard canWrite, let service = owner.service else { return }
        if older, history?.before == nil { return }
        do {
            _ = try await owner.historyCache.load(destination, current: history, older: older, service: service)
            guard canWrite else { return }
            if error != nil { error = nil }
        } catch is CancellationError {
            // A mutation or identity change superseded this read.
        } catch MessagingError.staleContext {
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 && destination.conversationID == nil {
            // An unsaved DM has no history and opening it must remain read-only.
        } catch { record(error) }
    }
    func send(recipients: [String], text: String? = nil) async -> Bool {
        let payload = (text ?? draft)
        guard canWrite, !sending, pending == nil, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let text { draft = text; saveDraft() }
        let value = PendingMessagingSend(id: UUID().uuidString, text: payload, recipients: recipients)
        pending = value
        defaults.set(try? JSONEncoder().encode(value), forKey: draftKey + ".pending")
        owner.startLiveTurn(
            for: destination,
            profileID: destination.profileID ?? recipients.first
        )
        beginAwaitingReply()
        await submit(value)
        return pending != nil || error == nil
    }
    private func submit(_ value: PendingMessagingSend) async {
        guard canWrite, let service = owner.service else { return }
        sending = true
        defer { sending = false }
        do {
            let receipt = try await service.send(value, to: destination, revision: history?.conversation.revision)
            guard canWrite else { return }
            await accepted(receipt, pending: value)
        } catch DashboardTicketBridgeError.http(let status, let detail) where [400, 403, 409, 422].contains(status) {
            guard epoch == owner.generation else { return }
            pending = nil; defaults.removeObject(forKey: draftKey + ".pending")
            owner.clearLiveTurn(for: destination)
            clearAwaitingReply()
            record(DashboardTicketBridgeError.http(status: status, detail: detail))
        } catch { if epoch == owner.generation { self.error = MessagingError.unknownOutcome.localizedDescription } }
    }
    func checkDelivery() async {
        guard canWrite, !sending, let pending, let service = owner.service else { return }
        sending = true
        do {
            let receipt = try await service.reconcile(pending, to: destination)
            guard canWrite else { sending = false; return }
            await accepted(receipt, pending: pending)
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
            // Reusing the same ID is safe even if the original request is still committing.
            sending = false
            await submit(pending)
            return
        } catch { record(error) }
        sending = false
    }
    private func accepted(_ receipt: MessagingSendReceipt, pending value: PendingMessagingSend) async {
        if let expected = destination.conversationID, receipt.conversation.id != expected {
            error = MessagingError.invalidResponse.localizedDescription; return
        }
        if let profile = destination.profileID, receipt.conversation.kind != "dm" || receipt.conversation.profiles != [profile] {
            error = MessagingError.invalidResponse.localizedDescription; return
        }
        owner.historyCache.accept(receipt, for: destination, current: history)
        pending = nil; defaults.removeObject(forKey: draftKey + ".pending")
        if draft == value.text { draft = ""; saveDraft() }
        error = nil
        let followUpDestination = destination
        Task { @MainActor [weak self] in
            guard let self, self.canWrite, self.destination == followUpDestination else { return }
            await self.load()
            await self.owner.refreshConversations(force: true)
        }
    }
    func markRead(through sequence: Int) async {
        guard canWrite, sequence > lastRead, let service = owner.service, let conversation = history?.conversation else { return }
        lastRead = sequence
        struct ReadReceipt: Decodable { let sequence: Int }
        do { _ = try await service.request(ReadReceipt.self, "/conversations/" + service.component(conversation.id) + "/read-state", method: "PUT", body: ["sequence": sequence]) }
        catch { lastRead = 0; record(error) }
    }
    func updateUserState(_ values: [String: Any]) async {
        guard canWrite, let service = owner.service, let conversation = history?.conversation else { return }
        do {
            _ = try await service.request(MessagingConversation.self, "/conversations/" + service.component(conversation.id) + "/user-state", method: "PATCH", body: values)
            guard canWrite else { return }
            owner.historyCache.invalidate(destination)
            await load(); await owner.refreshConversations(force: true)
        } catch { record(error) }
    }
    func cancelRun(_ id: String) async {
        guard canWrite, let service = owner.service else { return }
        struct Receipt: Decodable { let ok: Bool }
        do {
            _ = try await service.request(Receipt.self, "/runs/" + service.component(id) + "/cancel", method: "POST")
            guard canWrite else { return }
            owner.historyCache.invalidate(destination)
            await load()
        } catch { record(error) }
    }
    func updateGroup(title: String, profiles: [String], responder: String, revision: Int) async throws {
        guard canWrite, let service = owner.service, let conversation = history?.conversation else { throw MessagingError.unavailable }
        _ = try await service.request(MessagingConversation.self, "/conversations/" + service.component(conversation.id), method: "PATCH", body: [
            "title": title, "profiles": profiles, "default_responder": responder, "revision": revision
        ])
        guard canWrite else { throw MessagingError.staleContext }
        owner.historyCache.invalidate(destination)
        await load(); await owner.refreshConversations(force: true)
    }

    func deleteGroup() async -> Bool {
        guard canWrite, let service = owner.service, let conversation = history?.conversation, conversation.kind == "group" else { return false }
        struct Receipt: Decodable { let ok: Bool }
        do {
            _ = try await service.request(Receipt.self, "/conversations/" + service.component(conversation.id), method: "DELETE")
            guard canWrite else { return false }
            owner.historyCache.invalidate(destination, removeSnapshot: true)
            await owner.refreshConversations(force: true)
            return true
        } catch {
            record(error)
            return false
        }
    }

    private func beginAwaitingReply() {
        awaitingReply = true
        prefersUrgentPolling = true
        awaitingReplyTimeoutTask?.cancel()
        urgentPollingTask?.cancel()
        awaitingReplyTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.awaitingReplyTimeout) } catch { return }
            guard let self, !Task.isCancelled else { return }
            if MessagingRunPresence.collapsed(self.history?.runs ?? []).isEmpty {
                self.clearAwaitingReply()
            }
        }
        urgentPollingTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.urgentPollWindow) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.prefersUrgentPolling = false
        }
    }

    private func clearAwaitingReply() {
        awaitingReply = false
        prefersUrgentPolling = false
        awaitingReplyTimeoutTask?.cancel()
        awaitingReplyTimeoutTask = nil
        urgentPollingTask?.cancel()
        urgentPollingTask = nil
    }

    private func refreshAwaitingReplyFromRuns() {
        guard awaitingReply else { return }
        if !MessagingRunPresence.collapsed(history?.runs ?? []).isEmpty {
            clearAwaitingReply()
            return
        }
        if MessagingTurnHistory.completedAssistant(in: history?.messages ?? []) != nil {
            clearAwaitingReply()
        }
    }

    private func record(_ failure: Error) {
        guard epoch == owner.generation else { return }
        if case DashboardTicketBridgeError.http(let status, _) = failure, status == 403 || status == 401 {
            history = nil; owner.handle(failure)
        } else if case DashboardTicketBridgeError.signInRequired = failure {
            history = nil; owner.handle(failure)
        }
        error = failure.localizedDescription
    }
}
