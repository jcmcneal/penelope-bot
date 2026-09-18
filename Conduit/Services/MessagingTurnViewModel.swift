import Foundation

/// React-Query-shaped key for one messaging thread turn.
/// `turnID` is the client send id while a mutation is in flight, otherwise `"idle"`.
struct MessagingTurnQueryKey: Hashable, Equatable {
    let conversationID: String?
    let turnID: String

    static func idle(conversationID: String?) -> MessagingTurnQueryKey {
        MessagingTurnQueryKey(conversationID: conversationID, turnID: "idle")
    }
}

/// Projected thread state for chrome and bubbles. Durable history comes from
/// `MessagingHistoryCache`; the live overlay is keyed by the same query key.
struct MessagingTurnViewData {
    var history: MessagingHistory?
    var liveTurn: MessagingLiveTurn?
    var showRecipientPickerHint = false
}

/// One query/mutation surface for bot DM and group turns. Wire events (or a
/// history absorb that drops the overlay) resolve the send mutation and write
/// the in-memory snapshot — the UI reads `isLoading` / `isError` / `data` only.
@MainActor
final class MessagingTurnViewModel: ObservableObject {
    @Published private(set) var queryKey: MessagingTurnQueryKey
    @Published private(set) var isLoading = false
    @Published private(set) var isError = false
    @Published private(set) var data = MessagingTurnViewData()
    @Published private(set) var errorMessage: String?

    private var mutationTurnID: String?
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private var cache: [MessagingTurnQueryKey: MessagingTurnViewData] = [:]

    init(conversationID: String?) {
        queryKey = .idle(conversationID: conversationID)
    }

    func cachedSnapshot(for key: MessagingTurnQueryKey) -> MessagingTurnViewData? {
        cache[key]
    }

    func beginMutation(clientTurnID: String, conversationID: String?) {
        mutationTurnID = clientTurnID
        queryKey = MessagingTurnQueryKey(conversationID: conversationID, turnID: clientTurnID)
        isLoading = true
        isError = false
        errorMessage = nil
    }

    func failMutation(_ message: String) {
        guard isLoading else {
            isError = true
            errorMessage = message
            return
        }
        settleMutation(error: message)
    }

    func sync(
        history: MessagingHistory?,
        liveTurn: MessagingLiveTurn?,
        recipientHint: Bool,
        conversationID: String?
    ) {
        let convID = conversationID ?? history?.conversation.id
        let activeTurnID = liveTurn?.clientTurnID ?? mutationTurnID
        let key = MessagingTurnQueryKey(
            conversationID: convID,
            turnID: isLoading ? (activeTurnID ?? "idle") : "idle"
        )
        let snapshot = MessagingTurnViewData(
            history: history,
            liveTurn: liveTurn,
            showRecipientPickerHint: recipientHint
        )
        data = snapshot
        cache[key] = snapshot
        queryKey = key
        evaluateTerminal(liveTurn: liveTurn)
    }

    func waitForSettle() async {
        guard isLoading else { return }
        await withCheckedContinuation { continuation in
            settleWaiters.append(continuation)
        }
    }

    /// Safety valve when no terminal wire arrives (matches legacy awaiting-reply timeout).
    func settleIfStillLoading() {
        guard isLoading else { return }
        settleMutation()
    }

    private func evaluateTerminal(liveTurn: MessagingLiveTurn?) {
        guard isLoading, let expected = mutationTurnID else { return }

        if liveTurn == nil {
            settleMutation()
            return
        }

        guard let turn = liveTurn, turn.clientTurnID == expected else { return }

        if turn.phase == .failed {
            settleMutation(error: turn.errorMessage)
            return
        }
        if turn.phase == .yielded {
            settleMutation()
            return
        }
        if turn.settledTextInHistory && turn.tools.isEmpty && !turn.showsTurnLostChrome {
            settleMutation()
        }
    }

    private func settleMutation(error: String? = nil) {
        guard isLoading else { return }
        isLoading = false
        if let error, !error.isEmpty {
            isError = true
            errorMessage = error
        }
        mutationTurnID = nil
        queryKey = .idle(conversationID: queryKey.conversationID)
        let waiters = settleWaiters
        settleWaiters = []
        waiters.forEach { $0.resume() }
    }
}
