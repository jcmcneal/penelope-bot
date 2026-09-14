import Foundation
import SwiftUI

/// Owned by a connection, independent of the currently selected session profile.
@MainActor
final class MessagingStore: ObservableObject {
    @Published private(set) var availability: MessagingAvailability = .checking
    @Published private(set) var capability: MessagingCapability?
    @Published private(set) var conversations: [MessagingConversation] = []
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var cardDismissed = false
    @Published private(set) var pinnedBotIDs: [String] = []
    @Published private(set) var cachedDisplayProfiles: [MessagingProfile] = []
    @Published private(set) var liveTurns: [String: MessagingLiveTurn] = [:]
    private(set) var service: MessagingService?
    private(set) var generation = UUID()
    let historyCache = MessagingHistoryCache()
    private var conversationRefresh: (id: UUID, task: Task<Void, Never>)?
    private var bridgeID: ObjectIdentifier?
    private var presentationScope = ""
    private var dismissalScope = ""
    private var verifiedIdentityScope: String?
    /// True after a successful conversations fetch in this connection generation.
    private var hasLoadedConversations = false
    private let defaults: UserDefaults
    private let namespaceStore: ConnectionCacheNamespaceStore
    private let catalogCache: MessagingCatalogCache
    private var catalogPartition: String?
    private var catalogScope: String?
    private weak var dashboardBridge: DashboardTicketBridge?
    var onCacheIdentityChanged: (() -> Void)?
    private var catalogBootstrapID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        catalogCache = MessagingCatalogCache(defaults: defaults)
        namespaceStore = ConnectionCacheNamespaceStore(defaults: defaults)
    }
    var isReady: Bool { availability == .ready && capability?.isReady == true }
    var profiles: [MessagingProfile] { capability?.profiles ?? cachedDisplayProfiles }

    var unarchivedGroups: [MessagingConversation] {
        conversations.filter { $0.kind == "group" && !$0.archived }
    }

    /// Pinned shelf items in stored pin order (bots and groups interleaved).
    var pinnedShelfItems: [MessagingShelfItem] {
        let bots = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let groups = Dictionary(uniqueKeysWithValues: unarchivedGroups.map { ($0.id, $0) })
        return pinnedBotIDs.compactMap { key in
            if let groupID = MessagingShelfItem.groupID(fromPinKey: key), let group = groups[groupID] {
                return .group(group)
            }
            if let bot = bots[key] {
                return .bot(bot)
            }
            return nil
        }
    }

    func conversation(for destination: MessagingDestination) -> MessagingConversation? {
        if let conversationID = destination.conversationID {
            return conversations.first { $0.id == conversationID }
        }
        if let profileID = destination.profileID {
            return dmConversation(for: profileID)
        }
        return nil
    }

    func dmConversation(for profileID: String) -> MessagingConversation? {
        conversations.first {
            $0.kind != "group" && !$0.archived && $0.profiles.contains(profileID)
        }
    }

    func members(for conversation: MessagingConversation) -> [MessagingProfile] {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return conversation.profiles.compactMap { byID[$0] }
    }

    func members(for item: MessagingShelfItem) -> [MessagingProfile] {
        switch item {
        case .bot(let profile):
            return [profile]
        case .group(let conversation):
            return members(for: conversation)
        }
    }

    func presentation(for item: MessagingShelfItem) -> MessagingShelfPresentation {
        switch item {
        case .bot(let profile):
            let conversation = dmConversation(for: profile.id)
            return MessagingShelfPresentation(
                item: item,
                preview: conversation?.preview ?? "",
                time: RelativeTimestamp.format(conversation?.updatedAt),
                members: [profile]
            )
        case .group(let conversation):
            return MessagingShelfPresentation(
                item: item,
                preview: conversation.preview,
                time: RelativeTimestamp.format(conversation.updatedAt),
                members: members(for: conversation)
            )
        }
    }

    /// Unpinned bots (capability order) then unpinned groups (newest first).
    var unpinnedShelfItems: [MessagingShelfItem] {
        let pinned = Set(pinnedBotIDs)
        var items: [MessagingShelfItem] = profiles
            .filter { !pinned.contains($0.id) }
            .map { .bot($0) }
        let unpinnedGroups = unarchivedGroups
            .filter { !pinned.contains(MessagingShelfItem.groupPinKey($0.id)) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
        items.append(contentsOf: unpinnedGroups.map { .group($0) })
        return items
    }

    func connect(requester: (any DashboardJSONRequester)?, scope: String, catalogPartition: String? = nil) {
        let identity = requester.map { ObjectIdentifier($0) }
        guard identity != bridgeID || scope != presentationScope
                || (catalogPartition != nil && catalogPartition != self.catalogPartition) else { return }
        if requester == nil || (scope == presentationScope && catalogPartition != nil
            && self.catalogPartition != nil && catalogPartition != self.catalogPartition) { purgeCatalog() }
        generation = UUID()
        resetQueries()
        bridgeID = identity
        dashboardBridge = nil
        catalogBootstrapID = nil
        self.catalogPartition = catalogPartition
        catalogScope = nil
        if !cachedDisplayProfiles.isEmpty { cachedDisplayProfiles = [] }
        presentationScope = scope
        dismissalScope = scope
        verifiedIdentityScope = nil
        service = requester.map(MessagingService.init)
        liveTurns = [:]
        capability = nil
        conversations = []
        hasLoadedConversations = false
        error = nil
        isRefreshing = false
        availability = requester == nil ? .unavailable : .checking
        cardDismissed = defaults.bool(forKey: dismissalKey)
        restoreCatalog()
        loadPinnedBots()
    }

    /// Local credential partitioning finishes before the caller starts any network refresh.
    /// Cached profiles are display-only: capability and readiness remain unverified.
    func connectDashboard(_ bridge: DashboardTicketBridge?, scope: String) async {
        guard !Task.isCancelled else { return }
        let partition = bridge == nil ? nil : namespaceStore.namespace(for: scope)
        connect(requester: bridge, scope: scope, catalogPartition: partition)
        let epoch = generation
        guard let bridge else { return }
        let bootstrapID = UUID()
        catalogBootstrapID = bootstrapID
        defer { if catalogBootstrapID == bootstrapID { catalogBootstrapID = nil } }
        dashboardBridge = bridge
        await historyCache.configure(partition: partition)
        guard !Task.isCancelled, epoch == generation else { return }
    }

    private func restoreCatalog() {
        guard let catalogPartition, let snapshot = catalogCache.snapshot(for: catalogPartition) else { return }
        catalogScope = snapshot.verifiedScope
        if let saved = snapshot.conversations { conversations = saved }
        if cachedDisplayProfiles != snapshot.profiles { cachedDisplayProfiles = snapshot.profiles }
    }

    private func purgeCatalog() {
        historyCache.purge()
        if let catalogPartition { catalogCache.remove(catalogPartition) }
        catalogScope = nil
        if !cachedDisplayProfiles.isEmpty { cachedDisplayProfiles = [] }
    }

    private func rejectCatalog() {
        purgeCatalog()
        capability = nil
        service?.capability = nil
    }

    private var dismissalKey: String { "conduit.messaging.discovery.v1." + dismissalScope }
    private var pinnedBotsKey: String {
        "conduit.messaging.pinnedBots.v1." + (capability?.scope ?? catalogScope ?? presentationScope)
    }
    func dismissCard() { cardDismissed = true; defaults.set(true, forKey: dismissalKey) }

    func isBotPinned(_ profileID: String) -> Bool {
        pinnedBotIDs.contains(profileID)
    }

    func toggleBotPinned(_ profileID: String) {
        guard !profileID.isEmpty else { return }
        togglePinKey(profileID)
    }

    func isGroupPinned(_ conversationID: String) -> Bool {
        guard !conversationID.isEmpty else { return false }
        return pinnedBotIDs.contains(MessagingShelfItem.groupPinKey(conversationID))
    }

    func toggleGroupPinned(_ conversationID: String) {
        guard !conversationID.isEmpty else { return }
        togglePinKey(MessagingShelfItem.groupPinKey(conversationID))
    }

    private func togglePinKey(_ key: String) {
        if let index = pinnedBotIDs.firstIndex(of: key) {
            pinnedBotIDs.remove(at: index)
        } else {
            pinnedBotIDs.append(key)
        }
        defaults.set(pinnedBotIDs, forKey: pinnedBotsKey)
    }

    private func loadPinnedBots() {
        pinnedBotIDs = defaults.stringArray(forKey: pinnedBotsKey) ?? []
        prunePinnedBots()
    }

    private func prunePinnedBots() {
        // A stale display catalog must never remove a stored pin.
        let knownProfiles = capability.map { Set($0.profiles.map(\.id)) }
        // Keep group pins until conversations have loaded; otherwise a mid-refresh
        // capability prune would wipe every group favourite.
        let knownGroups: Set<String>? = hasLoadedConversations
            ? Set(unarchivedGroups.map(\.id))
            : nil
        let pruned = pinnedBotIDs.filter { key in
            if let groupID = MessagingShelfItem.groupID(fromPinKey: key) {
                guard let knownGroups else { return true }
                return knownGroups.contains(groupID)
            }
            guard let knownProfiles, !knownProfiles.isEmpty else { return true }
            return knownProfiles.contains(key)
        }
        guard pruned != pinnedBotIDs else { return }
        pinnedBotIDs = pruned
        defaults.set(pinnedBotIDs, forKey: pinnedBotsKey)
    }

    func refresh() async {
        guard let service, !isRefreshing, catalogBootstrapID == nil else { return }
        var epoch = generation
        var refreshPartition = catalogPartition
        let refreshBridge = dashboardBridge
        isRefreshing = true
        defer { if generation == epoch { isRefreshing = false } }
        do {
            let hub = try await service.hub()
            guard epoch == generation else { return }
            do {
                let identity = try await service.identity()
                guard epoch == generation else { return }
                if let user = identity["user_id"] as? String {
                    let parts = [presentationScope, identity["provider"] as? String ?? "", user, identity["org_id"] as? String ?? ""]
                    dismissalScope = (try? JSONEncoder().encode(parts).base64EncodedString()) ?? presentationScope
                    if let previous = verifiedIdentityScope, previous != dismissalScope {
                        onCacheIdentityChanged?()
                        generation = UUID(); epoch = generation
                        resetQueries()
                        purgeCatalog()
                        capability = nil; service.capability = nil; conversations = []
                        hasLoadedConversations = false
                    }
                    verifiedIdentityScope = dismissalScope
                    cardDismissed = defaults.bool(forKey: dismissalKey)
                }
            } catch DashboardTicketBridgeError.signInRequired { throw DashboardTicketBridgeError.signInRequired }
            catch DashboardTicketBridgeError.http(let status, let detail) where status == 401 || status == 403 {
                throw DashboardTicketBridgeError.http(status: status, detail: detail)
            } catch { /* Older servers can omit the identity probe; capability identity still fences data. */ }
            guard epoch == generation else { return }
            let rows = hub["plugins"] as? [[String: Any]] ?? []
            guard let plugin = rows.first(where: { $0["name"] as? String == "bot-coms" }) else {
                rejectCatalog()
                availability = .missing
                return
            }
            guard plugin["runtime_status"] as? String == "enabled" else {
                rejectCatalog()
                availability = .disabled
                return
            }
            do {
                let result = try await service.request(MessagingCapability.self, "/capabilities")
                guard epoch == generation else { return }
                if result.serverID.isEmpty || result.principalID.isEmpty {
                    rejectCatalog()
                    availability = .needsConfiguration
                    return
                }
                if let oldScope = capability?.scope ?? catalogScope, oldScope != result.scope {
                    onCacheIdentityChanged?()
                    purgeCatalog()
                    conversations = []
                    hasLoadedConversations = false
                    generation = UUID()
                    epoch = generation
                    resetQueries()
                }
                if refreshBridge != nil {
                    guard !Task.isCancelled else { return }
                    guard let actualPartition = namespaceStore.verify(principal: result.scope, for: presentationScope,
                                                                          expectedNamespace: refreshPartition) else { return }
                    if actualPartition != refreshPartition {
                        onCacheIdentityChanged?()
                        purgeCatalog()
                        generation = UUID(); epoch = generation
                        resetQueries()
                        conversations = []
                        hasLoadedConversations = false
                        catalogPartition = actualPartition
                        refreshPartition = actualPartition
                        await historyCache.configure(partition: actualPartition)
                        guard !Task.isCancelled, epoch == generation else { return }
                    }
                }
                if capability != result { capability = result }
                service.capability = result
                let nextAvailability: MessagingAvailability = result.apiVersion != 1 ? .needsUpdate : (result.isReady ? .ready : .needsConfiguration)
                if availability != nextAvailability { availability = nextAvailability }
                if result.isReady {
                    catalogScope = result.scope
                    if cachedDisplayProfiles != result.profiles { cachedDisplayProfiles = result.profiles }
                    if let refreshPartition, refreshPartition == catalogPartition {
                        catalogCache.save(profiles: result.profiles, verifiedScope: result.scope, for: refreshPartition, conversations: conversations)
                    }
                } else {
                    rejectCatalog()
                }
                if error != nil { error = nil }
                loadPinnedBots()
                if isReady { await refreshConversations() }
            } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
                if epoch == generation { rejectCatalog(); availability = .needsConfiguration }
            }
        } catch {
            guard epoch == generation else { return }
            if case DashboardTicketBridgeError.http(let status, _) = error, status == 404 {
                rejectCatalog()
                availability = .legacy
            } else {
                handle(error)
            }
        }
    }

    func handle(_ failure: Error) {
        isRefreshing = false
        if case DashboardTicketBridgeError.signInRequired = failure {
            purgeCatalog()
            availability = .forbidden; capability = nil; conversations = []; hasLoadedConversations = false; generation = UUID(); resetQueries()
        } else if case DashboardTicketBridgeError.http(let status, _) = failure, status == 401 || status == 403 {
            purgeCatalog()
            availability = .forbidden; capability = nil; conversations = []; hasLoadedConversations = false; generation = UUID(); resetQueries()
        } else { availability = .unavailable }
        error = failure.localizedDescription
    }

    private func resetQueries() {
        historyCache.reset()
        conversationRefresh?.task.cancel()
        conversationRefresh = nil
    }

    func refreshConversations(force: Bool = false) async {
        guard isReady else { return }
        if force {
            conversationRefresh?.task.cancel()
            conversationRefresh = nil
        }
        if let current = conversationRefresh { await current.task.value; return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchConversations()
        }
        conversationRefresh = (id, task)
        await task.value
        if conversationRefresh?.id == id { conversationRefresh = nil }
    }

    private func fetchConversations() async {
        guard isReady, let service else { return }
        struct Page: Decodable { let conversations: [MessagingConversation]; let cursor: String? }
        let epoch = generation
        do {
            var collected: [MessagingConversation] = []
            var cursor: String?
            var seen = Set<String>()
            repeat {
                let path = try cursor.map { "/conversations?cursor=" + (try service.component($0)) } ?? "/conversations"
                let page = try await service.request(Page.self, path)
                guard epoch == generation, !Task.isCancelled else { return }
                collected.append(contentsOf: page.conversations)
                cursor = page.cursor
                if let cursor, !seen.insert(cursor).inserted { throw MessagingError.invalidResponse }
            } while cursor != nil
            if conversations != collected { conversations = collected }
            hasLoadedConversations = true
            if let catalogPartition, let capability {
                catalogCache.save(profiles: capability.profiles, verifiedScope: capability.scope,
                                  for: catalogPartition, conversations: collected)
            }
            prunePinnedBots()
            if error != nil { error = nil }
        } catch { if epoch == generation, !Task.isCancelled { handle(error) } }
    }

    func createGroup(name: String, members: [String], responder: String, requestID: String) async throws -> MessagingConversation {
        guard isReady, capability?.supportsGroups == true, let service else { throw MessagingError.unavailable }
        let epoch = generation
        let result = try await service.request(MessagingConversation.self, "/conversations", method: "POST", body: [
            "title": name, "profiles": members, "default_responder": responder, "client_request_id": requestID
        ])
        guard epoch == generation else { throw MessagingError.staleContext }
        await refreshConversations(force: true)
        return result
    }

    func liveTurn(for destination: MessagingDestination) -> MessagingLiveTurn? {
        liveTurns[destination.id]
    }

    func startLiveTurn(for destination: MessagingDestination, profileID: String?) {
        liveTurns[destination.id] = MessagingLiveTurn(
            destinationID: destination.id,
            profileID: profileID
        )
    }

    func syncLiveTurn(for destination: MessagingDestination, history: MessagingHistory?) {
        guard var turn = liveTurns[destination.id] else {
            guard let history else { return }
            let active = history.runs.filter { ["queued", "running"].contains($0.status.lowercased()) }
            guard !active.isEmpty else { return }
            var turn = MessagingLiveTurn(
                destinationID: destination.id,
                profileID: active.first?.profile ?? destination.profileID
            )
            for run in active {
                if let sessionID = run.sessionID { turn.bindSession(sessionID) }
                turn.bindProfile(run.profile)
            }
            liveTurns[destination.id] = turn
            return
        }
        if let history {
            for run in history.runs where ["queued", "running"].contains(run.status.lowercased()) {
                if let sessionID = run.sessionID { turn.bindSession(sessionID) }
                turn.bindProfile(run.profile)
            }
            turn.absorbHistory(history.messages)
        }
        liveTurns[destination.id] = turn
    }

    func clearLiveTurn(for destination: MessagingDestination) {
        liveTurns[destination.id] = nil
    }
}

extension MessagingStore: MessagingStreamRouting {
    func handleUnboundStreamEvent(_ event: StreamEvent) {
        guard !liveTurns.isEmpty else { return }
        if case .unparsed = event { return }
        let sessionID = event.sessionID
        if !sessionID.isEmpty, let key = liveTurns.first(where: { $0.value.sessionIDs.contains(sessionID) })?.key {
            apply(event, to: key)
            return
        }
        let waiting = liveTurns.filter { $0.value.acceptsNewSession }
        if waiting.count == 1, let key = waiting.keys.first {
            apply(event, to: key)
            return
        }
        if waiting.count > 1, !sessionID.isEmpty {
            return
        }
        if waiting.isEmpty, liveTurns.count == 1, let key = liveTurns.keys.first,
           liveTurns[key]?.phase.isActive == true {
            apply(event, to: key)
        }
    }

    func handleStreamDisconnected() {
        for key in liveTurns.keys {
            guard var turn = liveTurns[key] else { continue }
            turn.markDropped()
            liveTurns[key] = turn
        }
    }

    private func apply(_ event: StreamEvent, to key: String) {
        guard var turn = liveTurns[key] else { return }
        guard turn.apply(event) else { return }
        liveTurns[key] = turn
    }
}
