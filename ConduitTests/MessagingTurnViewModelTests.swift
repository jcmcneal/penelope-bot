import XCTest
@testable import Conduit

@MainActor
final class MessagingTurnViewModelTests: XCTestCase {
    func testBeginMutationSetsLoadingAndQueryKey() {
        let model = MessagingTurnViewModel(conversationID: "dm-1")
        model.beginMutation(clientTurnID: "turn-1", conversationID: "dm-1")
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.queryKey, MessagingTurnQueryKey(conversationID: "dm-1", turnID: "turn-1"))
    }

    func testYieldedTurnSettlesMutation() async {
        let model = MessagingTurnViewModel(conversationID: "group-1")
        model.beginMutation(clientTurnID: "turn-1", conversationID: "group-1")
        var turn = MessagingLiveTurn(destinationID: "conversation:group-1", clientTurnID: "turn-1", profileID: "swe-id")
        turn.phase = .yielded

        model.sync(history: nil, liveTurn: turn, recipientHint: true, conversationID: "group-1")

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.queryKey, .idle(conversationID: "group-1"))
        XCTAssertTrue(model.data.showRecipientPickerHint)
    }

    func testSettledTextInHistorySettlesMutation() async {
        let model = MessagingTurnViewModel(conversationID: "dm-1")
        model.beginMutation(clientTurnID: "turn-1", conversationID: "dm-1")
        var turn = MessagingLiveTurn(destinationID: "dm:swe-id", clientTurnID: "turn-1", profileID: "swe-id")
        turn.text = "Done"
        turn.settledTextInHistory = true

        model.sync(history: nil, liveTurn: turn, recipientHint: false, conversationID: "dm-1")

        XCTAssertFalse(model.isLoading)
    }

    func testDroppedLiveTurnSettlesMutation() {
        let model = MessagingTurnViewModel(conversationID: "dm-1")
        model.beginMutation(clientTurnID: "turn-1", conversationID: "dm-1")
        var turn = MessagingLiveTurn(destinationID: "dm:swe-id", clientTurnID: "turn-1", profileID: "swe-id")
        model.sync(history: nil, liveTurn: turn, recipientHint: false, conversationID: "dm-1")
        XCTAssertTrue(model.isLoading)

        model.sync(history: nil, liveTurn: nil, recipientHint: false, conversationID: "dm-1")
        XCTAssertFalse(model.isLoading)
    }

    func testFailedTurnSurfacesError() {
        let model = MessagingTurnViewModel(conversationID: "dm-1")
        model.beginMutation(clientTurnID: "turn-1", conversationID: "dm-1")
        var turn = MessagingLiveTurn(destinationID: "dm:swe-id", clientTurnID: "turn-1", profileID: "swe-id")
        turn.phase = .failed
        turn.errorMessage = "nope"

        model.sync(history: nil, liveTurn: turn, recipientHint: false, conversationID: "dm-1")

        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.isError)
        XCTAssertEqual(model.errorMessage, "nope")
    }

    func testWaitForSettleResumesOnTerminal() async {
        let model = MessagingTurnViewModel(conversationID: "dm-1")
        model.beginMutation(clientTurnID: "turn-1", conversationID: "dm-1")
        let settleTask = Task { await model.waitForSettle() }
        await Task.yield()
        model.sync(history: nil, liveTurn: nil, recipientHint: false, conversationID: "dm-1")
        await settleTask.value
        XCTAssertFalse(model.isLoading)
    }

    func testSettleIfStillLoadingIsSafetyValve() {
        let model = MessagingTurnViewModel(conversationID: "dm-1")
        model.beginMutation(clientTurnID: "turn-1", conversationID: "dm-1")
        model.settleIfStillLoading()
        XCTAssertFalse(model.isLoading)
    }

    func testHistoryAssistantSettlesEvenWhenLiveTurnClientIDMismatches() {
        let model = MessagingTurnViewModel(conversationID: "dm-1")
        model.beginMutation(clientTurnID: "turn-send", conversationID: "dm-1")
        var turn = MessagingLiveTurn(destinationID: "dm:swe-id", clientTurnID: "rebound-other", profileID: "swe-id")
        turn.settledTextInHistory = true
        turn.lifecycleOverlay = .reconnecting
        let history = MessagingHistory(
            conversation: MessagingConversation(
                id: "dm-1",
                kind: "dm",
                title: "SWE",
                profiles: ["swe-id"],
                defaultResponder: "swe-id",
                revision: 1,
                preview: "",
                updatedAt: 2,
                unread: 0,
                archived: false,
                pinned: false,
                muted: false
            ),
            messages: [
                MessagingMessage(id: "u1", sequence: 1, author: "user", body: "How are you?", createdAt: 1),
                MessagingMessage(id: "a1", sequence: 2, author: "swe-id", body: "Doing well", createdAt: 2),
            ],
            runs: [],
            before: nil
        )

        model.sync(history: history, liveTurn: turn, recipientHint: false, conversationID: "dm-1")

        XCTAssertFalse(model.isLoading, "COMPLETE history must settle without matching clientTurnID")
    }

    func testHistoryAssistantSettlesWithoutLiveTurn() {
        let model = MessagingTurnViewModel(conversationID: "group-1")
        model.beginMutation(clientTurnID: "turn-send", conversationID: "group-1")
        let history = MessagingHistory(
            conversation: MessagingConversation(
                id: "group-1",
                kind: "group",
                title: "Mora",
                profiles: ["pm"],
                defaultResponder: "pm",
                revision: 1,
                preview: "",
                updatedAt: 2,
                unread: 0,
                archived: false,
                pinned: false,
                muted: false
            ),
            messages: [
                MessagingMessage(id: "u1", sequence: 1, author: "user", body: "Hello there", createdAt: 1),
                MessagingMessage(id: "a1", sequence: 2, author: "pm", body: "Ready", createdAt: 2),
            ],
            runs: [],
            before: nil
        )

        model.sync(history: history, liveTurn: nil, recipientHint: false, conversationID: "group-1")
        XCTAssertFalse(model.isLoading)
    }

}
