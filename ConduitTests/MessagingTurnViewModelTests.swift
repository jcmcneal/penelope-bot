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
}
