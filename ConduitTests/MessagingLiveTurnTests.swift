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

    func testForeignSessionIsIgnoredOnceBound() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        _ = turn.apply(.messageDelta(sessionId: "ours", text: "Hi"))
        XCTAssertFalse(turn.apply(.messageDelta(sessionId: "other", text: "leak")))
        XCTAssertEqual(turn.text, "Hi")
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
}
