import XCTest
@testable import Conduit

@MainActor
final class MessagingTests: XCTestCase {
    private func capability(server: String = "server", principal: String = "alice", version: Int = 1) -> [String: Any] {
        ["server_id": server, "principal_id": principal, "api_version": version, "state": "ready",
         "features": ["dm", "groups"], "profiles": [["id": "swe-id", "name": "swe", "displayName": "SWE"]]]
    }
    private func hub(_ status: String = "enabled") -> [String: Any] {
        ["plugins": [["name": "bot-coms", "runtime_status": status]]]
    }
    func testMissingAndDisabledNeverProbeMessaging() async {
        for response in [["plugins": []], hub("disabled")] as [[String: Any]] {
            let requester = MessagingRequester { path, _, _ in
                XCTAssertTrue(["/api/dashboard/plugins/hub", "/api/auth/me"].contains(path))
                return response
            }
            let store = MessagingStore()
            store.connect(requester: requester, scope: "server")
            await store.refresh()
            XCTAssertFalse(store.isReady)
            XCTAssertEqual(requester.paths.count, 2)
        }
    }
    func testInstalledWithoutAdapterNeedsConfiguration() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            throw DashboardTicketBridgeError.http(status: 404, detail: "missing")
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertEqual(store.availability, .needsConfiguration)
    }
    func testNetworkFailureIsNotMissingPlugin() async {
        let requester = MessagingRequester { _, _, _ in throw URLError(.timedOut) }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertEqual(store.availability, .unavailable)
        XCTAssertFalse(store.isRefreshing)
    }
    func testIncompatibleVersionDoesNotListConversations() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path == "/api/auth/me" { return [:] }
            XCTAssertTrue(path.hasSuffix("/capabilities"))
            return self.capability(version: 2)
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertEqual(store.availability, .needsUpdate)
    }
    func testForbiddenClearsStateAndRefreshCanRetry() async {
        var forbidden = false
        let requester = MessagingRequester { path, _, _ in
            if forbidden { throw DashboardTicketBridgeError.http(status: 403, detail: "revoked") }
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            return ["conversations": []]
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertTrue(store.isReady)
        forbidden = true
        await store.refresh()
        XCTAssertNil(store.capability)
        XCTAssertEqual(store.availability, .forbidden)
        XCTAssertFalse(store.isRefreshing)
        forbidden = false
        await store.refresh()
        XCTAssertTrue(store.isReady)
    }
    func testOldConnectionResponseCannotReplaceNewState() async {
        var resume: CheckedContinuation<[String: Any], Error>?
        let first = MessagingRequester { _, _, _ in try await withCheckedThrowingContinuation { resume = $0 } }
        let second = MessagingRequester { _, _, _ in ["plugins": []] }
        let store = MessagingStore()
        store.connect(requester: first, scope: "first")
        let fetch = Task { await store.refresh() }
        while resume == nil { await Task.yield() }
        store.connect(requester: second, scope: "second")
        await store.refresh()
        resume?.resume(returning: hub())
        await fetch.value
        XCTAssertEqual(store.availability, .missing)
        XCTAssertNil(store.capability)
    }
    func testOpenDMDoesNotWriteAndLostSendReusesClientID() async {
        var writes: [[String: Any]] = []
        let requester = MessagingRequester { path, method, body in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                writes.append(body ?? [:])
                throw URLError(.timedOut)
            }
            throw DashboardTicketBridgeError.http(status: 404, detail: "absent")
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = MessagingConversationStore(destination: .init(conversationID: nil, profileID: "swe-id"), owner: store, defaults: defaults)
        await model.load()
        XCTAssertTrue(writes.isEmpty)
        model.draft = "hello"
        await model.send(recipients: [])
        XCTAssertNotNil(model.pending)
        await model.waitForSubmitCompletion()
        await model.checkDelivery()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0]["client_message_id"] as? String, writes[1]["client_message_id"] as? String)
        XCTAssertEqual(model.draft, "hello")
    }
    func testRefreshKeepsEarlierPagesAndRejectsWrongDMIdentity() async {
        var loads = 0
        var wrongIdentity = false
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path == "/api/auth/me" { return [:] }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            loads += 1
            let sequences = loads == 1 ? [3, 4] : (loads == 2 ? [1, 2] : [3, 4, 5])
            var result: [String: Any] = [
                "conversation": ["id": "dm", "kind": "dm", "title": "SWE", "profiles": [wrongIdentity ? "other" : "swe-id"],
                    "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1, "unread": 0, "archived": false, "pinned": false, "muted": false],
                "messages": sequences.map { ["id": "m\($0)", "sequence": $0, "author": "user", "body": "Message \($0)", "created_at": 1] as [String: Any] },
                "runs": []
            ]
            if loads != 2 { result["before"] = 3 }
            return result
        }
        let owner = MessagingStore()
        owner.connect(requester: requester, scope: "server")
        await owner.refresh()
        let model = MessagingConversationStore(destination: .init(conversationID: nil, profileID: "swe-id"), owner: owner, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.load()
        await model.load(older: true)
        await model.load()
        XCTAssertEqual(model.history?.messages.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertNil(model.history?.before)
        wrongIdentity = true
        await model.load()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.history?.conversation.profiles, ["swe-id"])
    }

    func testRequestsCarryTheVerifiedAccountAndEscapePlusSigns() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability(principal: "alice+one") }
            return ["conversations": []]
        }
        let owner = MessagingStore()
        owner.connect(requester: requester, scope: "server")
        await owner.refresh()
        let path = requester.paths.last ?? ""
        XCTAssertTrue(path.contains("expected_principal=alice%2Bone"))
        XCTAssertTrue(path.contains("expected_server=server"))
    }

    func testPendingSendSurvivesViewRecreationAndDraftsAreIsolated() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            throw URLError(.timedOut)
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dm = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let first = MessagingConversationStore(destination: dm, owner: store, defaults: defaults)
        first.draft = "keep me"; first.saveDraft()
        await first.send(recipients: [])
        let restored = MessagingConversationStore(destination: dm, owner: store, defaults: defaults)
        XCTAssertEqual(restored.pending, first.pending)
        XCTAssertEqual(restored.draft, "keep me")
        let other = MessagingConversationStore(destination: .init(conversationID: "group", profileID: nil), owner: store, defaults: defaults)
        XCTAssertTrue(other.draft.isEmpty)
        XCTAssertNil(other.pending)
    }

    func testSetupPromptPrincipalFormatting() {
        XCTAssertEqual(
            MessagingSetupPrompt.principal(from: ["provider": "nous", "user_id": "abc"]),
            "nous:abc"
        )
        XCTAssertEqual(
            MessagingSetupPrompt.principal(from: ["provider": "basic", "user_id": "u1", "org_id": "org9"]),
            "basic:u1:org9"
        )
        XCTAssertNil(MessagingSetupPrompt.principal(from: ["provider": "nous"]))
        XCTAssertNil(MessagingSetupPrompt.principal(from: ["user_id": "abc"]))
    }

    func testSetupPromptEmbedsPrincipalAndSkipsBrowserScavengerHunt() {
        let withPrincipal = MessagingSetupPrompt.text(principal: "nous:abc", activeProfile: "hermes")
        XCTAssertTrue(withPrincipal.contains("Operator principal (authenticated in this client): nous:abc"))
        XCTAssertTrue(withPrincipal.contains("auto_enroll_profiles"))
        XCTAssertTrue(withPrincipal.contains("Do NOT ask me to open a browser"))
        XCTAssertTrue(withPrincipal.contains("Active Hermes profile in this client: hermes"))

        let without = MessagingSetupPrompt.text(principal: nil, activeProfile: "default")
        XCTAssertTrue(without.contains("could not read your signed-in account id"))
        XCTAssertTrue(without.contains("Do NOT ask me to open a browser"))
        XCTAssertFalse(without.contains("Operator principal (authenticated in this client):"))
    }

    func testBotPinsTogglePersistAndPruneUnknownIds() async throws {
        let suite = "messaging-bot-pins-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Penelope Bot"],
                    ],
                ]
            }
            return ["conversations": []]
        }
        let store = MessagingStore(defaults: defaults)
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        XCTAssertTrue(store.isReady)

        store.toggleBotPinned("swe-id")
        store.toggleBotPinned("ghost-id")
        XCTAssertEqual(store.pinnedBotIDs, ["swe-id", "ghost-id"])
        XCTAssertTrue(store.isBotPinned("swe-id"))

        await store.refresh()
        XCTAssertEqual(store.pinnedBotIDs, ["swe-id"], "Unknown bot ids are pruned after capability refresh")

        let reloaded = MessagingStore(defaults: defaults)
        reloaded.connect(requester: requester, scope: "server")
        await reloaded.refresh()
        XCTAssertEqual(reloaded.pinnedBotIDs, ["swe-id"])
        reloaded.toggleBotPinned("swe-id")
        XCTAssertFalse(reloaded.isBotPinned("swe-id"))
        XCTAssertTrue(reloaded.pinnedBotIDs.isEmpty)
    }

    func testGroupPinsPersistSurviveRefreshAndPruneAfterConversationsLoad() async throws {
        let suite = "messaging-group-pins-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var includeHot = true
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Penelope Bot"],
                    ],
                ]
            }
            var rows: [[String: Any]] = [
                ["id": "g-hot", "kind": "group", "title": "Hot crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "now", "updated_at": 80, "unread": 1, "archived": false, "pinned": false, "muted": false],
                ["id": "g-arch", "kind": "group", "title": "Archived crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "gone", "updated_at": 100, "unread": 0, "archived": true, "pinned": false, "muted": false],
            ]
            if !includeHot {
                rows.removeAll { ($0["id"] as? String) == "g-hot" }
            }
            return ["conversations": rows]
        }
        let store = MessagingStore(defaults: defaults)
        store.connect(requester: requester, scope: "server")
        await store.refresh()

        store.toggleGroupPinned("g-hot")
        store.toggleGroupPinned("g-gone")
        store.toggleBotPinned("swe-id")
        XCTAssertTrue(store.isGroupPinned("g-hot"))
        XCTAssertEqual(
            store.pinnedBotIDs,
            ["group:g-hot", "group:g-gone", "swe-id"],
            "Group pins use a group: prefix alongside bot ids"
        )

        await store.refresh()
        XCTAssertEqual(
            store.pinnedBotIDs,
            ["group:g-hot", "swe-id"],
            "Unknown/archived group pins prune only after conversations load; bot pins stay"
        )
        XCTAssertEqual(store.pinnedShelfItems.map(\.id), ["group:g-hot", "swe-id"])

        includeHot = false
        await store.refresh()
        XCTAssertEqual(store.pinnedBotIDs, ["swe-id"], "Missing groups prune after the next conversations fetch")
        XCTAssertFalse(store.isGroupPinned("g-hot"))
    }

    func testUnpinnedShelfSkipsDMsAndArchivedAndInterleavesPinOrder() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Penelope Bot"],
                    ],
                ]
            }
            return [
                "conversations": [
                    ["id": "dm-1", "kind": "dm", "title": "SWE", "profiles": ["swe-id"], "default_responder": "swe-id", "revision": 1, "preview": "hi", "updated_at": 90, "unread": 0, "archived": false, "pinned": false, "muted": false],
                    ["id": "g-old", "kind": "group", "title": "Old crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "later", "updated_at": 40, "unread": 0, "archived": false, "pinned": false, "muted": false],
                    ["id": "g-hot", "kind": "group", "title": "Hot crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "now", "updated_at": 80, "unread": 1, "archived": false, "pinned": false, "muted": false],
                    ["id": "g-arch", "kind": "group", "title": "Archived crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "gone", "updated_at": 100, "unread": 0, "archived": true, "pinned": true, "muted": false],
                ]
            ]
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()

        store.toggleGroupPinned("g-old")
        store.toggleBotPinned("designer-id")
        XCTAssertEqual(store.pinnedShelfItems.map(\.id), ["group:g-old", "designer-id"])
        XCTAssertEqual(
            store.unpinnedShelfItems.map(\.id),
            ["swe-id", "group:g-hot"],
            "Unpinned: remaining bots in capability order, then active groups by recency; DMs and archived stay out"
        )
    }

    func testDeleteGroupIssuesDeleteAndClearsHistory() async {
        var deletedPath: String?
        var methods: [String] = []
        let requester = MessagingRequester { path, method, _ in
            methods.append(method)
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Penelope Bot"],
                    ],
                ]
            }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            // MessagingService.component percent-encodes non-alphanumerics (hyphen → %2D).
            if path.contains("/conversations/g%2D1") && method == "GET" {
                return [
                    "conversation": [
                        "id": "g-1", "kind": "group", "title": "Room",
                        "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id",
                        "revision": 1, "preview": "hi", "updated_at": 1, "unread": 0,
                        "archived": false, "pinned": false, "muted": false,
                    ],
                    "messages": [["id": "m1", "sequence": 1, "author": "user", "body": "hi", "created_at": 1]],
                    "runs": [],
                ]
            }
            if path.contains("/conversations/g%2D1") && method == "DELETE" {
                deletedPath = path
                return ["ok": true]
            }
            return [:]
        }
        let owner = MessagingStore()
        owner.connect(requester: requester, scope: "server")
        await owner.refresh()
        let model = MessagingConversationStore(
            destination: .init(conversationID: "g-1", profileID: nil),
            owner: owner,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.load()
        XCTAssertEqual(model.history?.conversation.id, "g-1")
        let ok = await model.deleteGroup()
        XCTAssertTrue(ok)
        XCTAssertNil(model.history)
        XCTAssertNotNil(deletedPath)
        XCTAssertTrue(deletedPath?.contains("/conversations/") == true)
        XCTAssertTrue(methods.contains("DELETE"))
    }

    func testMentionDisplayRewritesProfileIdsOnly() {
        let profiles = [
            MessagingProfile(id: "designer-id", name: "designer", displayName: "Penelope Bot"),
            MessagingProfile(id: "swe-id", name: "swe", displayName: "SWE"),
        ]
        let body = "Ask @designer-id and @Designer; also `@swe-id` stays code-like but still rewrites outside fences."
        let rewritten = MessagingMentionDisplay.rewriteBody(body, profiles: profiles)
        XCTAssertEqual(
            rewritten,
            "Ask @Penelope Bot and @Designer; also `@SWE` stays code-like but still rewrites outside fences."
        )
        XCTAssertEqual(
            MessagingMentionDisplay.rewriteBody("Ping @unknown-bot please", profiles: profiles),
            "Ping @unknown-bot please"
        )
        XCTAssertEqual(
            MessagingMentionDisplay.rewriteBody("Hand to @{swe-id} please", profiles: profiles),
            "Hand to @SWE please"
        )
    }

    func testMessagingComposerActionIsSendOnly() {
        XCTAssertEqual(
            MessagingComposerAction.resolve(hasText: true, canWrite: true, isSending: false, hasPending: false),
            .send
        )
        XCTAssertEqual(
            MessagingComposerAction.resolve(hasText: false, canWrite: true, isSending: false, hasPending: false),
            .unavailable
        )
        XCTAssertEqual(
            MessagingComposerAction.resolve(hasText: true, canWrite: false, isSending: false, hasPending: false),
            .unavailable
        )
        XCTAssertEqual(
            MessagingComposerAction.resolve(hasText: true, canWrite: true, isSending: true, hasPending: false),
            .unavailable
        )
        XCTAssertEqual(
            MessagingComposerAction.resolve(hasText: true, canWrite: true, isSending: false, hasPending: true),
            .unavailable
        )
        // LOCAL_SENT cool-down blocks briefly; pending delivery reconciliation does not.
        XCTAssertEqual(
            MessagingComposerAction.resolve(hasText: true, canWrite: true, isSending: false, hasPending: false),
            .send
        )
    }

    func testMessagingViewportKeysStayOutsideHermesProfiles() {
        let dm = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let key = MessagingConversationChrome.sessionKey(for: dm)
        XCTAssertEqual(key.profile, MessagingConversationChrome.reservedProfile)
        XCTAssertEqual(key.sessionID, dm.id)
        XCTAssertNotEqual(key.profile, "swe")
        XCTAssertEqual(
            MessagingConversationChrome.draftKey(for: dm).profile,
            MessagingConversationChrome.reservedProfile
        )
        XCTAssertTrue(AppState.isSlashCommand("/model"))
        XCTAssertFalse(AppState.isSlashCommand("hello"))
    }

    func testSendAcceptsExplicitComposerText() async {
        var bodies: [String] = []
        let requester = MessagingRequester { path, method, body in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                bodies.append(body?["body"] as? String ?? "")
                return [
                    "conversation": ["id": "dm", "kind": "dm", "title": "SWE", "profiles": ["swe-id"],
                        "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1, "unread": 0, "archived": false, "pinned": false, "muted": false],
                    "message": ["id": "m1", "sequence": 1, "author": "user", "body": body?["body"] as? String ?? "", "created_at": 1],
                ]
            }
            throw DashboardTicketBridgeError.http(status: 404, detail: "absent")
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let model = MessagingConversationStore(
            destination: .init(conversationID: nil, profileID: "swe-id"),
            owner: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        model.draft = "stale"
        let ok = await model.send(recipients: [], text: "from composer")
        XCTAssertTrue(ok)
        await model.waitForSubmitCompletion()
        XCTAssertEqual(bodies, ["from composer"])
    }

    func testGroupStackOverflowBadgeAndThreadSubtitle() {
        XCTAssertNil(GroupStackOverflow.badge(memberCount: 0))
        XCTAssertNil(GroupStackOverflow.badge(memberCount: 2))
        XCTAssertEqual(GroupStackOverflow.badge(memberCount: 3), "+1")
        XCTAssertEqual(GroupStackOverflow.badge(memberCount: 5), "+3")
        XCTAssertNil(GroupStackOverflow.badge(memberCount: 5, visibleLimit: 5))

        let members = [
            MessagingProfile(id: "designer-id", name: "designer", displayName: "Penelope Bot"),
            MessagingProfile(id: "swe-id", name: "swe", displayName: "SWE"),
        ]
        XCTAssertEqual(
            MessagingThreadChrome.memberSubtitle(members: members),
            "Penelope Bot · SWE · You"
        )
        XCTAssertEqual(
            MessagingThreadChrome.memberSubtitle(members: members, includeYou: false),
            "Penelope Bot · SWE"
        )
        XCTAssertTrue(ConduitAvatarIdentity.usesBrandMark(displayName: "Penelope Bot", name: "default"))
        XCTAssertFalse(ConduitAvatarIdentity.usesBrandMark(displayName: "SWE", name: "research"))
    }

    func testShelfPresentationLooksUpBotDMPreview() async throws {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") {
                return [
                    "server_id": "server", "principal_id": "alice", "api_version": 1, "state": "ready",
                    "features": ["dm", "groups"],
                    "profiles": [
                        ["id": "swe-id", "name": "swe", "displayName": "SWE"],
                        ["id": "designer-id", "name": "designer", "displayName": "Penelope Bot"],
                    ],
                ]
            }
            return [
                "conversations": [
                    ["id": "dm-1", "kind": "dm", "title": "SWE", "profiles": ["swe-id"], "default_responder": "swe-id", "revision": 1, "preview": "Route references sent", "updated_at": 1_700_000_000, "unread": 0, "archived": false, "pinned": false, "muted": false],
                    ["id": "g-hot", "kind": "group", "title": "Design crew", "profiles": ["swe-id", "designer-id"], "default_responder": "swe-id", "revision": 1, "preview": "Let's ship the picker together.", "updated_at": 80, "unread": 1, "archived": false, "pinned": false, "muted": false],
                ]
            ]
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()

        let swe = store.presentation(for: .bot(MessagingProfile(id: "swe-id", name: "swe", displayName: "SWE")))
        XCTAssertEqual(swe.preview, "Route references sent")
        XCTAssertFalse(swe.time.isEmpty)
        XCTAssertEqual(swe.members.map(\.id), ["swe-id"])

        let penelope = store.presentation(for: .bot(MessagingProfile(id: "designer-id", name: "designer", displayName: "Penelope Bot")))
        XCTAssertEqual(penelope.preview, "", "No DM conversation means no preview")
        XCTAssertEqual(penelope.time, "")

        let group = try XCTUnwrap(store.unarchivedGroups.first)
        let presented = store.presentation(for: .group(group))
        XCTAssertEqual(presented.preview, "Let's ship the picker together.")
        XCTAssertEqual(presented.members.map(\.displayName), ["SWE", "Penelope Bot"])
        XCTAssertEqual(
            MessagingThreadChrome.memberSubtitle(members: presented.members),
            "SWE · Penelope Bot · You"
        )
    }

    func testRelativeTimestampEmptyInputs() {
        XCTAssertEqual(RelativeTimestamp.format(nil), "")
        XCTAssertEqual(RelativeTimestamp.format(0), "")
        XCTAssertEqual(RelativeTimestamp.format(-1), "")
    }
}

final class MessagingRunPresenceTests: XCTestCase {
    func testMapsStatusesOntoAvatarStates() {
        XCTAssertNil(MessagingRunPresence.avatarState(for: "completed"))
        XCTAssertEqual(MessagingRunPresence.avatarState(for: "queued"), .waiting)
        XCTAssertEqual(MessagingRunPresence.avatarState(for: "running"), .working)
        XCTAssertEqual(MessagingRunPresence.avatarState(for: "failed"), .blocked)
        XCTAssertEqual(MessagingRunPresence.avatarState(for: "interrupted"), .blocked)
        XCTAssertEqual(MessagingRunPresence.avatarState(for: "cancelled"), .blocked)
        XCTAssertEqual(MessagingRunPresence.avatarState(for: "error"), .blocked)
        XCTAssertEqual(MessagingRunPresence.avatarState(for: "starting"), .thinking)
    }

    func testCollapseKeepsOneAvatarPerProfilePreferringRunning() {
        let runs = [
            MessagingRun(id: "a", profile: "pm", status: "queued", detail: ""),
            MessagingRun(id: "b", profile: "pm", status: "running", detail: "tools"),
            MessagingRun(id: "c", profile: "swe", status: "queued", detail: ""),
            MessagingRun(id: "d", profile: "swe", status: "completed", detail: ""),
            MessagingRun(id: "e", profile: "ops", status: "failed", detail: "timeout"),
            MessagingRun(id: "f", profile: "ops", status: "queued", detail: ""),
        ]
        let items = MessagingRunPresence.collapsed(runs)
        XCTAssertEqual(items.map(\.profile), ["ops", "pm", "swe"])
        XCTAssertEqual(items.first { $0.profile == "pm" }?.avatarState, .working)
        XCTAssertEqual(items.first { $0.profile == "swe" }?.avatarState, .waiting)
        XCTAssertEqual(items.first { $0.profile == "ops" }?.avatarState, .waiting)
        XCTAssertTrue(items.first { $0.profile == "ops" }?.showsDetail == false)
        XCTAssertEqual(
            MessagingRunPresence.collapsed([
                MessagingRun(id: "fail", profile: "ops", status: "failed", detail: "timeout")
            ]).first?.showsDetail,
            true
        )
    }
}

@MainActor
final class MessagingAwaitingReplyTests: XCTestCase {
    override func tearDown() async throws {
        MessagingConversationStore.awaitingReplyTimeout = .seconds(20)
        MessagingConversationStore.urgentPollWindow = .seconds(8)
        try await super.tearDown()
    }

    private func conversationJSON(runs: [[String: Any]] = []) -> [String: Any] {
        [
            "conversation": [
                "id": "dm", "kind": "dm", "title": "SWE", "profiles": ["swe-id"],
                "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1,
                "unread": 0, "archived": false, "pinned": false, "muted": false,
            ],
            "messages": [
                ["id": "m1", "sequence": 1, "author": "user", "body": "hi", "created_at": 1],
            ],
            "runs": runs,
        ]
    }

    func testHumanYieldClearsAwaitingReplyAndShowsRecipientHint() async {
        let requester = MessagingRequester { path, method, body in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                return [
                    "conversation": [
                        "id": "group-1", "kind": "group", "title": "Bots", "profiles": ["swe-id", "designer-id"],
                        "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1,
                        "unread": 0, "archived": false, "pinned": false, "muted": false,
                    ],
                    "message": [
                        "id": body?["client_message_id"] ?? "m", "sequence": 2, "author": "user",
                        "body": body?["body"] ?? "", "created_at": 2,
                    ],
                ]
            }
            return [
                "conversation": [
                    "id": "group-1", "kind": "group", "title": "Bots", "profiles": ["swe-id", "designer-id"],
                    "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1,
                    "unread": 0, "archived": false, "pinned": false, "muted": false,
                ],
                "messages": [
                    ["id": "m1", "sequence": 1, "author": "user", "body": "hi", "created_at": 1],
                    ["id": "m2", "sequence": 2, "author": "user", "body": "ping", "created_at": 2],
                ],
                "runs": [],
            ] as [String: Any]
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let destination = MessagingDestination(conversationID: "group-1", profileID: nil)
        let model = MessagingConversationStore(
            destination: destination,
            owner: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.load()
        _ = await model.send(recipients: [], text: "ping")
        await model.waitForSubmitCompletion()
        XCTAssertTrue(model.turnViewModel.isLoading)

        store.handleUnboundStreamEvent(
            .turnYielded(sessionId: "live-sid", reason: "human"),
            join: StreamJoinKey(conversationID: "group-1")
        )

        XCTAssertFalse(model.turnViewModel.isLoading)
        XCTAssertTrue(model.turnViewModel.data.showRecipientPickerHint)
        model.noteRecipientsUpdated(["swe-id"])
        XCTAssertFalse(model.turnViewModel.data.showRecipientPickerHint)
    }

    func testSendKeepsTurnLoadingUntilTerminalWire() async {
        var includeRun = false
        let requester = MessagingRequester { path, method, body in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                return [
                    "conversation": [
                        "id": "dm", "kind": "dm", "title": "SWE", "profiles": ["swe-id"],
                        "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1,
                        "unread": 0, "archived": false, "pinned": false, "muted": false,
                    ],
                    "message": [
                        "id": body?["client_message_id"] ?? "m", "sequence": 2, "author": "user",
                        "body": body?["body"] ?? "", "created_at": 2,
                    ],
                    "runs": [["id": "r1", "profile": "swe-id", "status": "running", "detail": "", "session_id": "live-sid"]],
                ]
            }
            return self.conversationJSON(runs: includeRun
                ? [["id": "r1", "profile": "swe-id", "status": "running", "detail": "", "session_id": "live-sid"]]
                : [])
        }
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let model = MessagingConversationStore(
            destination: destination,
            owner: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.load()
        XCTAssertFalse(model.turnViewModel.isLoading)
        let ok = await model.send(recipients: [], text: "ping")
        XCTAssertTrue(ok)
        XCTAssertTrue(model.turnViewModel.isLoading)
        await model.waitForSubmitCompletion()
        includeRun = true
        await model.load()
        XCTAssertNotNil(store.liveTurn(for: destination))
        XCTAssertTrue(model.turnViewModel.isLoading, "queued runs alone must not settle the send mutation")

        store.handleUnboundStreamEvent(
            .messageComplete(sessionId: "live-sid", messageId: "assistant-1", content: "pong", reasoning: nil),
            join: StreamJoinKey(conversationID: "dm", runID: "r1", profileID: "swe-id")
        )
        XCTAssertNil(store.liveTurn(for: destination))
        XCTAssertFalse(model.turnViewModel.isLoading)
    }

    func testHardRejectionKeepsPendingBubbleAndMarksFailed() async {
        let requester = MessagingRequester { path, method, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                throw DashboardTicketBridgeError.http(status: 422, detail: "rejected")
            }
            return self.conversationJSON()
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let model = MessagingConversationStore(
            destination: .init(conversationID: nil, profileID: "swe-id"),
            owner: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.load()
        _ = await model.send(recipients: [], text: "nope")
        await model.waitForSubmitCompletion()
        XCTAssertNotNil(model.pending)
        XCTAssertEqual(model.pendingDelivery, .failed)
        XCTAssertFalse(model.turnViewModel.isLoading)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.composerSendBlocked)
    }

    func testLocalSendAckReturnsBeforeHTTPCompletes() async {
        let requester = MessagingRequester { path, method, body in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                try await Task.sleep(for: .milliseconds(500))
                return [
                    "conversation": [
                        "id": "dm", "kind": "dm", "title": "SWE", "profiles": ["swe-id"],
                        "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1,
                        "unread": 0, "archived": false, "pinned": false, "muted": false,
                    ],
                    "message": [
                        "id": body?["client_message_id"] ?? "m", "sequence": 2, "author": "user",
                        "body": body?["body"] ?? "", "created_at": 2,
                    ],
                ]
            }
            return self.conversationJSON()
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let model = MessagingConversationStore(
            destination: .init(conversationID: nil, profileID: "swe-id"),
            owner: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let started = Date()
        let ok = await model.send(recipients: [], text: "fast")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(ok)
        XCTAssertNotNil(model.pending)
        XCTAssertLessThan(elapsed, 0.2)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.pendingDelivery, .inFlight)
        await model.waitForSubmitCompletion()
        XCTAssertNil(model.pending)
        XCTAssertFalse(model.composerSendBlocked)
    }

    func testAwaitingReplyTimesOutWithoutRuns() async {
        MessagingConversationStore.awaitingReplyTimeout = .milliseconds(80)
        let requester = MessagingRequester { path, method, body in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            if method == "POST" {
                return [
                    "conversation": [
                        "id": "dm", "kind": "dm", "title": "SWE", "profiles": ["swe-id"],
                        "default_responder": "swe-id", "revision": 1, "preview": "", "updated_at": 1,
                        "unread": 0, "archived": false, "pinned": false, "muted": false,
                    ],
                    "message": [
                        "id": body?["client_message_id"] ?? "m", "sequence": 2, "author": "user",
                        "body": body?["body"] ?? "", "created_at": 2,
                    ],
                ]
            }
            return self.conversationJSON()
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let model = MessagingConversationStore(
            destination: .init(conversationID: nil, profileID: "swe-id"),
            owner: store,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        _ = await model.send(recipients: [], text: "hang")
        XCTAssertTrue(model.turnViewModel.isLoading)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.turnViewModel.isLoading)
    }

    func testRestoredPendingStartsAwaitingReply() async {
        let requester = MessagingRequester { path, _, _ in
            if path.hasSuffix("/hub") { return self.hub() }
            if path.hasSuffix("/capabilities") { return self.capability() }
            if path.hasSuffix("/conversations") { return ["conversations": []] }
            throw URLError(.timedOut)
        }
        let store = MessagingStore()
        store.connect(requester: requester, scope: "server")
        await store.refresh()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dm = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let first = MessagingConversationStore(destination: dm, owner: store, defaults: defaults)
        _ = await first.send(recipients: [], text: "keep")
        XCTAssertTrue(first.turnViewModel.isLoading)
        let restored = MessagingConversationStore(destination: dm, owner: store, defaults: defaults)
        XCTAssertNotNil(restored.pending)
        XCTAssertTrue(restored.turnViewModel.isLoading)
    }

    private func capability(server: String = "server", principal: String = "alice", version: Int = 1) -> [String: Any] {
        ["server_id": server, "principal_id": principal, "api_version": version, "state": "ready",
         "features": ["dm", "groups"], "profiles": [["id": "swe-id", "name": "swe", "displayName": "SWE"]]]
    }

    private func hub(_ status: String = "enabled") -> [String: Any] {
        ["plugins": [["name": "bot-coms", "runtime_status": status]]]
    }
}

@MainActor
private final class MessagingRequester: DashboardJSONRequester {
    let handler: (String, String, [String: Any]?) async throws -> [String: Any]
    var paths: [String] = []
    init(_ handler: @escaping (String, String, [String: Any]?) async throws -> [String: Any]) { self.handler = handler }
    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        paths.append(path)
        return try await handler(String(path.split(separator: "?", maxSplits: 1)[0]), method, body)
    }
}
