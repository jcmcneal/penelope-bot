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
        turn.markDropped()
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

    func testDroppedStreamKeepsPartialText() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.messageDelta(sessionId: "s", text: "half"))
        _ = turn.apply(.toolStart(sessionId: "s", toolName: "read", toolInput: "file"))
        turn.markDropped()
        XCTAssertEqual(turn.phase, .interrupted)
        XCTAssertEqual(turn.text, "half")
        XCTAssertEqual(turn.tools.first?.status, .failed)
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
}

@MainActor
final class MessagingStreamRoutingTests: XCTestCase {
    func testUnboundEventsBindToTheWaitingTurn() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "hidden-sess", text: "Grok-fast"))
        XCTAssertEqual(store.liveTurn(for: destination)?.text, "Grok-fast")
        XCTAssertEqual(store.liveTurn(for: destination)?.sessionIDs, ["hidden-sess"])
    }

    func testDisconnectMarksTheLiveTurnInterrupted() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "s", text: "partial"))
        store.handleStreamDisconnected()
        XCTAssertEqual(store.liveTurn(for: destination)?.phase, .interrupted)
        XCTAssertEqual(store.liveTurn(for: destination)?.text, "partial")
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

        store.handleUnboundStreamEvent(.messageDelta(sessionId: "id-from-ws", text: "Hel"))
        store.handleUnboundStreamEvent(
            .toolStart(sessionId: "id-from-ws", toolName: "web_search", toolInput: "q=")
        )
        store.handleUnboundStreamEvent(
            .toolComplete(sessionId: "id-from-ws", toolName: "web_search", toolOutput: "sun")
        )
        store.handleUnboundStreamEvent(.messageDelta(sessionId: "id-from-ws", text: "lo"))
        store.handleUnboundStreamEvent(
            .messageComplete(sessionId: "id-from-ws", messageId: "m1", content: "Hello", reasoning: nil)
        )

        let turn = store.liveTurn(for: destination)
        XCTAssertEqual(turn?.text, "Hello")
        XCTAssertEqual(turn?.sessionIDs, ["id-from-history", "id-from-ws"])
        XCTAssertEqual(turn?.tools.first?.name, "web_search")
        XCTAssertEqual(turn?.tools.first?.status, .complete)
        XCTAssertEqual(turn?.phase, .completing)
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

    func testMismatchedSidAliasesOntoTheOnlyActiveTurn() {
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

        XCTAssertEqual(store.liveTurn(for: swe)?.text, "live")
        XCTAssertEqual(store.liveTurn(for: swe)?.sessionIDs, ["stored-swe", "id-from-ws"])
        XCTAssertEqual(store.liveTurn(for: designer)?.text, "")
        XCTAssertEqual(store.liveTurn(for: designer)?.phase, .interrupted)
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
