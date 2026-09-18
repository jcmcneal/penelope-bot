import XCTest
@testable import Conduit

final class MessagingLiveTurnTests: XCTestCase {
    func testTokensAppearWithoutWaitingForComplete() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        XCTAssertTrue(turn.apply(.messageStart(sessionId: "sess-1")))
        XCTAssertTrue(turn.apply(.messageDelta(sessionId: "sess-1", text: "Hel")))
        XCTAssertTrue(turn.apply(.messageDelta(sessionId: "sess-1", text: "lo")))
        XCTAssertEqual(turn.text, "Hello")
        XCTAssertEqual(turn.phase, .streaming)
        XCTAssertTrue(turn.showsStreamingText)
        XCTAssertFalse(turn.settledTextInHistory)
    }

    func testToolCallStreamsArgsThenResult() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        XCTAssertTrue(turn.apply(.toolStart(sessionId: "s", toolName: "web_search", toolInput: "q=")))
        XCTAssertTrue(turn.apply(.toolDelta(sessionId: "s", toolName: "web_search", toolInput: "q=weather", replace: true)))
        XCTAssertEqual(turn.tools.first?.input, "q=weather")
        XCTAssertEqual(turn.tools.first?.status, .running)
        XCTAssertTrue(turn.apply(.toolComplete(sessionId: "s", toolName: "web_search", toolOutput: "sun")))
        XCTAssertEqual(turn.tools.first?.output, "sun")
        XCTAssertEqual(turn.tools.first?.status, .complete)
    }

    func testToolDeltaAppendsWhenNotAReplacement() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.toolStart(sessionId: "s", toolName: "terminal", toolInput: "ls"))
        _ = turn.apply(.toolDelta(sessionId: "s", toolName: "terminal", toolInput: " -la", replace: false))
        XCTAssertEqual(turn.tools.first?.input, "ls -la")
    }

    func testToolFailureKeepsTheCard() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.toolStart(sessionId: "s", toolName: "shell", toolInput: "rm"))
        _ = turn.apply(.toolFailed(sessionId: "s", toolName: "shell", message: "denied"))
        XCTAssertEqual(turn.tools.first?.status, .failed)
        XCTAssertEqual(turn.tools.first?.output, "denied")
        XCTAssertEqual(turn.phase, .usingTool)
    }

    func testActiveTurnAliasesASecondOpaqueSessionId() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        XCTAssertTrue(turn.apply(.messageDelta(sessionId: "id-from-history", text: "Hel")))
        XCTAssertTrue(turn.apply(.messageDelta(sessionId: "id-from-ws", text: "lo")))
        XCTAssertEqual(turn.text, "Hello")
        XCTAssertEqual(turn.sessionIDs, ["id-from-history", "id-from-ws"])
    }

    func testInactiveTurnIgnoresAnUnseenSessionId() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.messageDelta(sessionId: "ours", text: "Hi"))
        _ = turn.apply(.messageInterrupted(sessionId: "ours"))
        XCTAssertFalse(turn.apply(.messageDelta(sessionId: "other", text: "leak")))
        XCTAssertEqual(turn.text, "Hi")
    }

    func testSessionTitleUnionsBothOpaqueIds() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        XCTAssertTrue(
            turn.apply(.sessionTitle(runtimeSessionId: "id-from-ws", storedSessionId: "id-from-history", title: "swe"))
        )
        XCTAssertEqual(turn.sessionIDs, ["id-from-ws", "id-from-history"])
    }

    func testHistorySettlesDuplicateStreamingText() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.messageDelta(sessionId: "s", text: "Done"))
        turn.absorbHistory([
            MessagingMessage(id: "m1", sequence: 1, author: "swe-id", body: "Done", createdAt: 1)
        ])
        XCTAssertTrue(turn.settledTextInHistory)
        XCTAssertFalse(turn.showsStreamingText)
        XCTAssertEqual(turn.phase, .completing)
    }

    func testTransportInterruptKeepsPartialTextWithoutDropCopy() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.messageDelta(sessionId: "s", text: "half"))
        _ = turn.apply(.toolStart(sessionId: "s", toolName: "read", toolInput: "file"))
        turn.markTransportInterrupted()
        XCTAssertEqual(turn.phase, .usingTool)
        XCTAssertEqual(turn.text, "half")
        XCTAssertEqual(turn.tools.first?.status, .running)
        XCTAssertNil(turn.errorMessage)
    }

    func testRunSessionIdIsOptional() throws {
        let data = """
        {"id":"r1","profile":"swe-id","status":"running","detail":""}
        """.data(using: .utf8)!
        let run = try JSONDecoder().decode(MessagingRun.self, from: data)
        XCTAssertNil(run.sessionID)
        let withSession = try JSONDecoder().decode(
            MessagingRun.self,
            from: #"{"id":"r1","profile":"swe-id","status":"running","detail":"","session_id":"abc"}"#.data(using: .utf8)!
        )
        XCTAssertEqual(withSession.sessionID, "abc")
    }

    func testFastHistorySettleOnlyWhileTokensOrToolsAreLive() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        XCTAssertFalse(turn.needsFastHistorySettle)
        _ = turn.apply(.messageDelta(sessionId: "s", text: "Hi"))
        XCTAssertTrue(turn.needsFastHistorySettle)
        turn.absorbHistory([
            MessagingMessage(id: "m1", sequence: 1, author: "swe-id", body: "Hi", createdAt: 1)
        ])
        XCTAssertFalse(turn.needsFastHistorySettle)
    }

    func testHumanYieldSettlesEmptyShellTurn() {
        var turn = MessagingLiveTurn(destinationID: "conversation:c1", profileID: "swe-id")
        XCTAssertTrue(turn.apply(.turnYielded(sessionId: "s", reason: "human")))
        XCTAssertEqual(turn.phase, .yielded)
        XCTAssertFalse(turn.phase.isActive)
        XCTAssertFalse(turn.showsStreamingText)
        XCTAssertTrue(turn.tools.isEmpty)
    }

    func testNonHumanYieldIsIgnored() {
        var turn = MessagingLiveTurn(destinationID: "conversation:c1", profileID: "swe-id")
        XCTAssertTrue(turn.apply(.turnYielded(sessionId: "s", reason: "selector")))
        XCTAssertEqual(turn.phase, .starting)
    }

    func testMessageCompleteSettlesLiveChromeWithoutHistoryPoll() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        turn.lifecycleOverlay = .reconnecting
        _ = turn.apply(.messageDelta(sessionId: "s", text: "Howdy — what can I help with?"))
        _ = turn.apply(.messageComplete(
            sessionId: "s",
            messageId: "m1",
            content: "Howdy — what can I help with?",
            reasoning: nil
        ))
        XCTAssertTrue(turn.settledTextInHistory)
        XCTAssertFalse(turn.showsStreamingText)
        XCTAssertFalse(turn.showsSoftReconnectChrome)
        XCTAssertNil(turn.lifecycleOverlay)
        XCTAssertEqual(turn.phase, .completing)
    }

    func testMessageCompleteDoesNotSettleWhileToolsAreRunning() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.toolStart(sessionId: "s", toolName: "web_search", toolInput: "q="))
        _ = turn.apply(.messageComplete(
            sessionId: "s",
            messageId: "m1",
            content: "Done",
            reasoning: nil
        ))
        XCTAssertFalse(turn.settledTextInHistory)
        XCTAssertTrue(turn.showsStreamingText)
        XCTAssertEqual(turn.phase, .usingTool)
    }
}

@MainActor
final class MessagingStreamRoutingTests: XCTestCase {
    func testUnboundEventsBindToTheWaitingTurn() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        store.handleUnboundStreamEvent(
            .messageDelta(sessionId: "hidden-sess", text: "Grok-fast"),
            join: StreamJoinKey(profileID: "swe-id")
        )
        XCTAssertEqual(store.liveTurn(for: destination)?.text, "Grok-fast")
        XCTAssertEqual(store.liveTurn(for: destination)?.sessionIDs, ["hidden-sess"])
    }

    func testDisconnectDoesNotMarkTransportInterruptAsTurnFailure() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        store.handleUnboundStreamEvent(
            .messageDelta(sessionId: "s", text: "partial"),
            join: StreamJoinKey(profileID: "swe-id")
        )
        store.handleStreamDisconnected(reason: .background)
        let turn = store.liveTurn(for: destination)
        XCTAssertEqual(turn?.phase, .streaming)
        XCTAssertEqual(turn?.text, "partial")
        XCTAssertNil(turn?.errorMessage)
        XCTAssertEqual(turn?.lifecycleOverlay, .appBackground)
    }

    func testRunsWithoutSessionIdDoNotMintALiveTurn() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.syncLiveTurn(for: destination, history: messagingHistory(profile: "swe-id", runSessionID: nil))
        XCTAssertNil(store.liveTurn(for: destination))
    }

    func testHistorySessionIdMismatchStillReceivesLiveDeltasAndTools() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        store.syncLiveTurn(
            for: destination,
            history: messagingHistory(profile: "swe-id", runSessionID: "id-from-history")
        )
        XCTAssertEqual(store.liveTurn(for: destination)?.sessionIDs, ["id-from-history"])

        let join = StreamJoinKey(conversationID: "c1", runID: "run-1", profileID: "swe-id")
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "id-from-ws", text: "Hel"), join: join)
        store.handleUnboundStreamEvent(
            .toolStart(sessionId: "id-from-ws", toolName: "web_search", toolInput: "q="),
            join: join
        )
        store.handleUnboundStreamEvent(
            .toolComplete(sessionId: "id-from-ws", toolName: "web_search", toolOutput: "sun"),
            join: join
        )
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "id-from-ws", text: "lo"), join: join)
        store.handleUnboundStreamEvent(
            .messageComplete(sessionId: "id-from-ws", messageId: "m1", content: "Hello", reasoning: nil),
            join: join
        )

        let turn = store.liveTurn(for: destination)
        XCTAssertEqual(turn?.text, "Hello")
        XCTAssertEqual(turn?.sessionIDs, ["id-from-history", "id-from-ws"])
        XCTAssertEqual(turn?.tools.first?.name, "web_search")
        XCTAssertEqual(turn?.tools.first?.status, .complete)
        XCTAssertEqual(turn?.phase, .completing)
        XCTAssertTrue(turn?.settledTextInHistory == true)
        XCTAssertFalse(turn?.showsStreamingText == true)
    }

    func testMessageCompleteDropsReconnectingOverlayForSimpleReply() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        store.handleScenePhase(.active, gatewaySessionValid: true)
        store.handleUnboundStreamEvent(
            .messageComplete(
                sessionId: "s",
                messageId: "m1",
                content: "Howdy — what can I help with?",
                reasoning: nil
            ),
            join: StreamJoinKey(profileID: "swe-id")
        )
        XCTAssertNil(store.liveTurn(for: destination))
    }

    func testMismatchedSessionIdDoesNotCrossWireAnotherConversation() {
        let store = MessagingStore()
        let swe = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let designer = MessagingDestination(conversationID: nil, profileID: "designer-id")
        store.startLiveTurn(for: swe, profileID: "swe-id")
        store.startLiveTurn(for: designer, profileID: "designer-id")
        store.syncLiveTurn(for: swe, history: messagingHistory(id: "c-swe", profile: "swe-id", runSessionID: "stored-swe"))
        store.syncLiveTurn(
            for: designer,
            history: messagingHistory(id: "c-des", profile: "designer-id", runSessionID: "stored-des")
        )

        store.handleUnboundStreamEvent(.messageDelta(sessionId: "runtime-unknown", text: "leak"))

        XCTAssertEqual(store.liveTurn(for: swe)?.text, "")
        XCTAssertEqual(store.liveTurn(for: designer)?.text, "")
        XCTAssertEqual(store.liveTurn(for: swe)?.sessionIDs, ["stored-swe"])
        XCTAssertEqual(store.liveTurn(for: designer)?.sessionIDs, ["stored-des"])
    }

    func testKnownSessionIdStillRoutesWhenTwoTurnsAreLive() {
        let store = MessagingStore()
        let swe = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let designer = MessagingDestination(conversationID: nil, profileID: "designer-id")
        store.startLiveTurn(for: swe, profileID: "swe-id")
        store.startLiveTurn(for: designer, profileID: "designer-id")
        store.syncLiveTurn(for: swe, history: messagingHistory(id: "c-swe", profile: "swe-id", runSessionID: "stored-swe"))
        store.syncLiveTurn(
            for: designer,
            history: messagingHistory(id: "c-des", profile: "designer-id", runSessionID: "stored-des")
        )

        store.handleUnboundStreamEvent(.messageDelta(sessionId: "stored-swe", text: "ours"))
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "runtime-unknown", text: "leak"))

        XCTAssertEqual(store.liveTurn(for: swe)?.text, "ours")
        XCTAssertEqual(store.liveTurn(for: swe)?.sessionIDs, ["stored-swe"])
        XCTAssertEqual(store.liveTurn(for: designer)?.text, "")
        XCTAssertEqual(store.liveTurn(for: designer)?.sessionIDs, ["stored-des"])
    }

    func testMismatchedSidDoesNotAliasOntoTheOnlyActiveTurn() {
        let store = MessagingStore()
        let swe = MessagingDestination(conversationID: nil, profileID: "swe-id")
        let designer = MessagingDestination(conversationID: nil, profileID: "designer-id")
        store.startLiveTurn(for: swe, profileID: "swe-id")
        store.startLiveTurn(for: designer, profileID: "designer-id")
        store.syncLiveTurn(for: swe, history: messagingHistory(id: "c-swe", profile: "swe-id", runSessionID: "stored-swe"))
        store.syncLiveTurn(
            for: designer,
            history: messagingHistory(id: "c-des", profile: "designer-id", runSessionID: "stored-des")
        )
        store.handleUnboundStreamEvent(.messageInterrupted(sessionId: "stored-des"))

        store.handleUnboundStreamEvent(.messageDelta(sessionId: "id-from-ws", text: "live"))

        XCTAssertEqual(store.liveTurn(for: swe)?.text, "")
        XCTAssertEqual(store.liveTurn(for: swe)?.sessionIDs, ["stored-swe"])
        XCTAssertEqual(store.liveTurn(for: designer)?.text, "")
        XCTAssertEqual(store.liveTurn(for: designer)?.phase, .interrupted)
    }

    func testConversationJoinKeyRoutesAmongTwoLiveTurns() {
        let store = MessagingStore()
        let swe = MessagingDestination(conversationID: "c-swe", profileID: nil)
        let designer = MessagingDestination(conversationID: "c-des", profileID: nil)
        store.startLiveTurn(for: swe, profileID: "swe-id")
        store.startLiveTurn(for: designer, profileID: "designer-id")

        store.handleUnboundStreamEvent(
            .messageDelta(sessionId: "runtime-unknown", text: "ours"),
            join: StreamJoinKey(conversationID: "c-swe", runID: "run-swe")
        )

        XCTAssertEqual(store.liveTurn(for: swe)?.text, "ours")
        XCTAssertEqual(store.liveTurn(for: swe)?.sessionIDs, ["runtime-unknown"])
        XCTAssertEqual(store.liveTurn(for: designer)?.text, "")
        XCTAssertEqual(store.liveTurn(for: designer)?.sessionIDs ?? [], [])
    }

    func testHumanYieldDropsEmptyLiveTurnOverlay() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: "c1", profileID: nil)
        store.startLiveTurn(for: destination, profileID: "swe-id")
        XCTAssertNotNil(store.liveTurn(for: destination))

        store.handleUnboundStreamEvent(
            .turnYielded(sessionId: "live-sid", reason: "human"),
            join: StreamJoinKey(conversationID: "c1", runID: "r1", profileID: "swe-id")
        )

        XCTAssertNil(store.liveTurn(for: destination), "yielded shell overlay must drop immediately")
        XCTAssertTrue(store.humanYieldedDestinationIDs.contains(destination.id))
        store.consumeHumanYieldNotice(for: destination)
        XCTAssertFalse(store.humanYieldedDestinationIDs.contains(destination.id))
    }

    func testHumanYieldWithEmptyJoinSettlesEmptyAutoShell() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: "mora-1", profileID: nil)
        store.startLiveTurn(for: destination, profileID: nil)
        XCTAssertNotNil(store.liveTurn(for: destination))
        XCTAssertTrue(store.liveTurn(for: destination)?.sessionIDs.isEmpty == true)

        store.handleUnboundStreamEvent(
            .turnYielded(sessionId: "yield-sid", reason: "human"),
            join: .none
        )

        XCTAssertNil(store.liveTurn(for: destination), "empty Auto shell must settle without join keys")
        XCTAssertTrue(store.humanYieldedDestinationIDs.contains(destination.id))
    }

    func testHumanYieldClearsSoftReconnectCatchingUpChrome() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: "mora-1", profileID: nil)
        store.startLiveTurn(for: destination, profileID: nil)
        store.handleStreamDisconnected(reason: .foregroundTransport)
        XCTAssertEqual(store.liveTurn(for: destination)?.lifecycleOverlay, .resumeSync)

        store.handleUnboundStreamEvent(
            .turnYielded(sessionId: "yield-sid", reason: "human"),
            join: .none
        )

        XCTAssertNil(store.liveTurn(for: destination))
        XCTAssertTrue(store.humanYieldedDestinationIDs.contains(destination.id))
    }

    func testCompletedAssistantHistoryClearsCatchingUpWithoutYield() {
        let store = MessagingStore()
        let destination = MessagingDestination(
            conversationID: "06492b61-7bda-43ca-b754-c702335cbee2",
            profileID: nil
        )
        store.startLiveTurn(
            for: destination,
            profileID: "a454f9edec9d5de0b6560bb155803bf2",
            clientTurnID: "turn-send"
        )
        store.handleStreamDisconnected(reason: .foregroundTransport)
        XCTAssertEqual(store.liveTurn(for: destination)?.lifecycleOverlay, .resumeSync)

        store.syncLiveTurn(for: destination, history: Self.frustratingTurnHistory)

        XCTAssertNil(
            store.liveTurn(for: destination),
            "COMPLETE assistant in history must drop Catching up without turn.yielded"
        )
    }

    func testCompletedAssistantClearsCatchingUpEvenWithStaleRunningRun() {
        let store = MessagingStore()
        let destination = MessagingDestination(
            conversationID: "06492b61-7bda-43ca-b754-c702335cbee2",
            profileID: nil
        )
        store.startLiveTurn(
            for: destination,
            profileID: "a454f9edec9d5de0b6560bb155803bf2",
            clientTurnID: "turn-send"
        )
        store.handleStreamDisconnected(reason: .foregroundTransport)

        let base = Self.frustratingTurnHistory
        let history = MessagingHistory(
            conversation: base.conversation,
            messages: base.messages,
            runs: [
                MessagingRun(
                    id: "stale-run",
                    profile: "a454f9edec9d5de0b6560bb155803bf2",
                    status: "running",
                    detail: "",
                    sessionID: "s1"
                )
            ],
            before: nil
        )
        store.syncLiveTurn(for: destination, history: history)

        let turn = store.liveTurn(for: destination)
        XCTAssertNotNil(turn, "stale running run keeps shell until run clears")
        XCTAssertNil(turn?.lifecycleOverlay, "Catching up must clear once assistant is durable")
        XCTAssertTrue(turn?.settledTextInHistory == true)
    }

    func testSendReceiptBindsSessionBeforeFirstToken() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: "c1", profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        let receipt = MessagingSendReceipt(
            conversation: MessagingConversation(
                id: "c1", kind: "dm", title: "SWE", profiles: ["swe-id"],
                defaultResponder: "swe-id", revision: 1, preview: "", updatedAt: 1,
                unread: 0, archived: false, pinned: false, muted: false
            ),
            message: MessagingMessage(id: "m1", sequence: 1, author: "user", body: "hi", createdAt: 1),
            runs: [MessagingRun(id: "run-1", profile: "swe-id", status: "running", detail: "", sessionID: "admit-sid")]
        )
        store.bindAdmittedRun(for: destination, receipt: receipt)

        store.handleUnboundStreamEvent(
            .messageDelta(sessionId: "admit-sid", text: "Hel"),
            join: StreamJoinKey(conversationID: "c1", runID: "run-1", profileID: "swe-id")
        )
        store.handleUnboundStreamEvent(
            .messageDelta(sessionId: "admit-sid", text: "lo"),
            join: StreamJoinKey(conversationID: "c1", runID: "run-1", profileID: "swe-id")
        )

        let turn = store.liveTurn(for: destination)
        XCTAssertEqual(turn?.text, "Hello")
        XCTAssertEqual(turn?.runID, "run-1")
        XCTAssertEqual(turn?.sessionIDs, ["admit-sid"])
    }

    func testAdmittedRunIDRoutesAmongTwoLiveTurns() {
        let store = MessagingStore()
        let swe = MessagingDestination(conversationID: "c-swe", profileID: nil)
        let designer = MessagingDestination(conversationID: "c-des", profileID: nil)
        store.startLiveTurn(for: swe, profileID: "swe-id")
        store.startLiveTurn(for: designer, profileID: "designer-id")
        store.bindAdmittedRun(
            for: swe,
            receipt: MessagingSendReceipt(
                conversation: MessagingConversation(
                    id: "c-swe", kind: "dm", title: "SWE", profiles: ["swe-id"],
                    defaultResponder: "swe-id", revision: 1, preview: "", updatedAt: 1,
                    unread: 0, archived: false, pinned: false, muted: false
                ),
                message: MessagingMessage(id: "m1", sequence: 1, author: "user", body: "hi", createdAt: 1),
                runs: [MessagingRun(id: "run-swe", profile: "swe-id", status: "running", detail: "", sessionID: "sid-swe")]
            )
        )

        store.handleUnboundStreamEvent(
            .messageDelta(sessionId: "runtime-unknown", text: "ours"),
            join: StreamJoinKey(conversationID: "c-swe", runID: "run-swe")
        )

        XCTAssertEqual(store.liveTurn(for: swe)?.text, "ours")
        XCTAssertEqual(store.liveTurn(for: designer)?.text, "")
    }

    func testMessagingRunStartBindsOpaqueSessionThenTokensFollow() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        let join = StreamJoinKey(conversationID: "c1", runID: "run-1", profileID: "swe-id")

        store.handleUnboundStreamEvent(.messagingRunStart(sessionId: "id-from-ws"), join: join)
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "id-from-ws", text: "Hel"))

        let turn = store.liveTurn(for: destination)
        XCTAssertEqual(turn?.text, "Hel")
        XCTAssertEqual(turn?.sessionIDs, ["id-from-ws"])
        XCTAssertEqual(turn?.conversationID, "c1")
        XCTAssertEqual(turn?.runID, "run-1")
    }

    func testForeignToolDoesNotAttachToABoundTextTurn() {
        var turn = MessagingLiveTurn(destinationID: "dm:default", profileID: "default")
        _ = turn.apply(.messageDelta(sessionId: "5e933ea7", text: "Yeah"))
        XCTAssertFalse(turn.apply(.toolStart(sessionId: "6cea0e91", toolName: "team_inbox", toolInput: "inbox")))
        XCTAssertTrue(turn.tools.isEmpty)
        XCTAssertEqual(turn.text, "Yeah")
        XCTAssertEqual(turn.sessionIDs, ["5e933ea7"])
    }

    func testMessageCompleteReplacesLongerDivergedOverlayText() {
        var turn = MessagingLiveTurn(destinationID: "dm:default", profileID: "default")
        _ = turn.apply(.messageDelta(sessionId: "6cea0e91", text: String(repeating: "x", count: 200)))
        _ = turn.apply(.messageComplete(
            sessionId: "5e933ea7",
            messageId: "64789",
            content: Self.hermesReply,
            reasoning: nil
        ))
        XCTAssertEqual(turn.text, Self.hermesReply)
    }

    func testScrambledOverlayLosesToTheSavedAssistant() {
        var turn = MessagingLiveTurn(destinationID: "dm:default", profileID: "default")
        _ = turn.apply(.toolStart(sessionId: "6cea0e91", toolName: "team_inbox", toolInput: nil))
        _ = turn.apply(.messageDelta(sessionId: "6cea0e91", text: String(repeating: "x", count: 200)))
        turn.markTransportInterrupted()
        turn.absorbHistory(Self.frustratingTurnHistory.messages)
        XCTAssertEqual(turn.text, Self.hermesReply)
        XCTAssertTrue(turn.settledTextInHistory)
        XCTAssertTrue(turn.tools.isEmpty)
        XCTAssertNil(turn.errorMessage)
        XCTAssertFalse(turn.showsStreamingText)
    }

    func testBusyGatewayEventsDoNotBlockTheSavedReply() {
        let store = MessagingStore()
        let destination = MessagingDestination(
            conversationID: "06492b61-7bda-43ca-b754-c702335cbee2",
            profileID: "a454f9edec9d5de0b6560bb155803bf2"
        )
        store.startLiveTurn(for: destination, profileID: "a454f9edec9d5de0b6560bb155803bf2")

        // Night of 2026-09-14: other plugin sessions were tool-flooding /api/ws
        // with no join keys. PR #10 aliased those onto this overlay.
        store.handleUnboundStreamEvent(.toolStart(sessionId: "6cea0e91", toolName: "team_inbox", toolInput: nil))
        store.handleUnboundStreamEvent(.toolStart(sessionId: "a87696c3", toolName: "tool_describe", toolInput: nil))
        store.handleUnboundStreamEvent(.toolStart(sessionId: "d4a959b6", toolName: "read_file", toolInput: nil))
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "6cea0e91", text: "Workflow report for peer pm"))
        store.handleUnboundStreamEvent(.messageComplete(
            sessionId: "5e933ea7",
            messageId: "64789",
            content: Self.hermesReply,
            reasoning: nil
        ))
        store.handleStreamDisconnected(reason: .foregroundTransport)

        XCTAssertEqual(store.liveTurn(for: destination)?.tools ?? [], [])
        XCTAssertNotEqual(store.liveTurn(for: destination)?.text, Self.hermesReply)

        store.syncLiveTurn(for: destination, history: Self.frustratingTurnHistory)
        XCTAssertNil(store.liveTurn(for: destination), "history has the reply; overlay and spinner must go")
    }

    func testBoundRuntimeSidKeepsTheRealCompleteAndDropsForeignTools() {
        let store = MessagingStore()
        let destination = MessagingDestination(
            conversationID: "06492b61-7bda-43ca-b754-c702335cbee2",
            profileID: "a454f9edec9d5de0b6560bb155803bf2"
        )
        store.startLiveTurn(for: destination, profileID: "a454f9edec9d5de0b6560bb155803bf2")
        store.syncLiveTurn(
            for: destination,
            history: messagingHistory(
                id: "06492b61-7bda-43ca-b754-c702335cbee2",
                profile: "a454f9edec9d5de0b6560bb155803bf2",
                runSessionID: "5e933ea7"
            )
        )

        store.handleUnboundStreamEvent(.toolStart(sessionId: "6cea0e91", toolName: "team_inbox", toolInput: nil))
        store.handleUnboundStreamEvent(.messageComplete(
            sessionId: "5e933ea7",
            messageId: "64789",
            content: Self.hermesReply,
            reasoning: nil
        ))

        XCTAssertNil(
            store.liveTurn(for: destination),
            "message.complete with final text must drop overlay without waiting for history"
        )

        store.syncLiveTurn(for: destination, history: Self.frustratingTurnHistory)
        XCTAssertNil(store.liveTurn(for: destination))
    }
}

private extension MessagingStreamRoutingTests {
    static let hermesReply = """
        Yeah — the gap between what you meant and what it actually did is the part that wears you down.

        @a454f9edec9d5de0b6560bb155803bf2
        """

    static var frustratingTurnHistory: MessagingHistory {
        MessagingHistory(
            conversation: MessagingConversation(
                id: "06492b61-7bda-43ca-b754-c702335cbee2",
                kind: "dm",
                title: "default",
                profiles: ["a454f9edec9d5de0b6560bb155803bf2"],
                defaultResponder: "a454f9edec9d5de0b6560bb155803bf2",
                revision: 1,
                preview: "",
                updatedAt: 1,
                unread: 0,
                archived: false,
                pinned: false,
                muted: false
            ),
            messages: [
                MessagingMessage(
                    id: "f507fac0-f7b2-4ff1-b3fe-fe62c37c0543",
                    sequence: 19,
                    author: "user",
                    body: "AI is frustrating",
                    createdAt: 1
                ),
                MessagingMessage(
                    id: "c30549e6-450d-44ae-a9b7-a717f812bf28",
                    sequence: 20,
                    author: "a454f9edec9d5de0b6560bb155803bf2",
                    body: hermesReply,
                    createdAt: 2
                )
            ],
            runs: [],
            before: nil
        )
    }
}

private func messagingHistory(
    id: String = "c1",
    profile: String,
    runSessionID: String?
) -> MessagingHistory {
    MessagingHistory(
        conversation: MessagingConversation(
            id: id,
            kind: "dm",
            title: profile,
            profiles: [profile],
            defaultResponder: profile,
            revision: 1,
            preview: "",
            updatedAt: 1,
            unread: 0,
            archived: false,
            pinned: false,
            muted: false
        ),
        messages: [],
        runs: [MessagingRun(id: "r1", profile: profile, status: "running", detail: "", sessionID: runSessionID)],
        before: nil
    )
}
