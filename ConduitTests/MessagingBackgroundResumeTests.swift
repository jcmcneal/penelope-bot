import XCTest
@testable import Conduit

@MainActor
final class MessagingBackgroundResumeTests: XCTestCase {
    func testBackgroundInterruptDoesNotSetDropCopyOnEmptyShell() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", profileID: "swe-id")
        turn.markTransportInterrupted()
        turn.lifecycleOverlay = .appBackground
        XCTAssertNil(turn.errorMessage)
        XCTAssertEqual(turn.phase, .starting)
    }

    func testSoftReconnectAppearsOnlyAfterResumeSyncDelay() async {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id", clientTurnID: "turn-1")

        store.handleScenePhase(.active, gatewaySessionValid: true)
        XCTAssertEqual(store.liveTurn(for: destination)?.lifecycleOverlay, .resumeSync)

        try? await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(store.liveTurn(for: destination)?.lifecycleOverlay, .reconnecting)
    }

    func testHistoryAbsorbClearsSoftReconnectAndKeepsOneBubble() {
        var turn = MessagingLiveTurn(destinationID: "dm:swe", clientTurnID: "turn-1", profileID: "swe-id")
        turn.lifecycleOverlay = .reconnecting
        turn.resumeSyncLossDue = true
        _ = turn.apply(.messageDelta(sessionId: "s", text: "Hel"))
        turn.absorbHistory([
            MessagingMessage(id: "m1", sequence: 1, author: "swe-id", body: "Hello", createdAt: 1)
        ])
        XCTAssertNil(turn.lifecycleOverlay)
        XCTAssertFalse(turn.resumeSyncLossDue)
        XCTAssertTrue(turn.settledTextInHistory)
        XCTAssertEqual(turn.text, "Hello")
    }

    func testLossBudgetMarksTurnLostWhenHistoryStaysEmpty() async {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id", clientTurnID: "turn-1")
        store.handleScenePhase(.active, gatewaySessionValid: true)

        try? await Task.sleep(for: .milliseconds(3100))
        store.syncLiveTurn(for: destination, history: emptyHistory(profile: "swe-id"))

        let lost = store.liveTurn(for: destination)
        XCTAssertEqual(lost?.lifecycleOverlay, .turnLost)
        XCTAssertEqual(lost?.errorMessage, MessagingResumeCopy.turnLost)
        XCTAssertEqual(lost?.phase, .failed)
    }

    func testSessionDeadDisconnectDoesNotSurfaceDropCopy() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id")
        store.handleStreamDisconnected(reason: .sessionDead)
        let turn = store.liveTurn(for: destination)
        XCTAssertEqual(turn?.phase, .starting)
        XCTAssertNil(turn?.errorMessage)
    }

    func testRapidBackgroundForegroundKeepsSingleTurnPerClientTurnID() async {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id", clientTurnID: "turn-1")

        store.handleScenePhase(.background, gatewaySessionValid: true)
        store.handleStreamDisconnected(reason: .background)
        store.handleScenePhase(.active, gatewaySessionValid: true)
        store.handleScenePhase(.background, gatewaySessionValid: true)
        store.handleScenePhase(.active, gatewaySessionValid: true)

        let turns = store.liveTurns.values.filter { $0.clientTurnID == "turn-1" }
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.destinationID, destination.id)
    }

    func testRetryClearsLostTurnOverlay() {
        let store = MessagingStore()
        let destination = MessagingDestination(conversationID: nil, profileID: "swe-id")
        store.startLiveTurn(for: destination, profileID: "swe-id", clientTurnID: "turn-1")
        store.markLiveTurnFailed(for: destination, message: MessagingResumeCopy.turnLost)
        store.retryLostTurn(for: destination)
        XCTAssertNil(store.liveTurn(for: destination))
    }
}

private func emptyHistory(profile: String) -> MessagingHistory {
    MessagingHistory(
        conversation: MessagingConversation(
            id: "c1",
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
        runs: [],
        before: nil
    )
}
