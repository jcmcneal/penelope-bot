import Foundation
import SwiftUI

/// In-flight bot reply projected into a messaging thread: tokens, tool cards,
/// and failure/interrupt state. Durable history still wins once the public
/// message lands; this overlay exists so the UI never waits for that dump.
struct MessagingLiveTurn: Equatable {
    enum Phase: Equatable {
        case starting
        case streaming
        case usingTool
        case completing
        case interrupted
        case failed
        /// bot-coms yielded without dispatching a bot (e.g. empty @ To).
        case yielded

        var isActive: Bool {
            switch self {
            case .starting, .streaming, .usingTool, .completing: return true
            case .interrupted, .failed, .yielded: return false
            }
        }
    }

    var destinationID: String
    /// Stable key for one user send ↔ one assistant bubble across background.
    var clientTurnID: String
    var profileID: String?
    var conversationID: String?
    var runID: String?
    var sessionIDs: Set<String> = []
    var text = ""
    var reasoning = ""
    var tools: [ToolActivity] = []
    var phase: Phase = .starting
    var errorMessage: String?
    var lifecycleOverlay: MessagingLifecycleOverlay?
    /// Armed by the resume loss budget; evaluated on the next history sync.
    var resumeSyncLossDue = false
    /// True once a durable assistant message covers `text`, so the streaming
    /// bubble can hide without dropping live tool cards.
    var settledTextInHistory = false

    init(
        destinationID: String,
        clientTurnID: String = UUID().uuidString,
        profileID: String? = nil,
        conversationID: String? = nil
    ) {
        self.destinationID = destinationID
        self.clientTurnID = clientTurnID
        self.profileID = profileID
        self.conversationID = conversationID
    }

    var showsSoftReconnectChrome: Bool {
        lifecycleOverlay == .reconnecting
    }

    var showsTurnLostChrome: Bool {
        lifecycleOverlay == .turnLost
    }

    var softReconnectMessage: String {
        text.isEmpty && tools.isEmpty
            ? MessagingResumeCopy.softReconnect
            : MessagingResumeCopy.softReconnectAlt
    }

    var showsStreamingText: Bool {
        !settledTextInHistory && (!text.isEmpty || phase == .streaming || phase == .starting)
    }

    /// History poll should only go sub-second while tokens or tools are live.
    /// A shell turn or a settled overlay must not collapse the 1s/4s cadence.
    var needsFastHistorySettle: Bool {
        if settledTextInHistory {
            return tools.contains { $0.status == .running }
        }
        return !text.isEmpty || tools.contains { $0.status == .running }
    }

    mutating func bindSession(_ sessionID: String) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionIDs.insert(trimmed)
    }

    mutating func bindProfile(_ profileID: String?) {
        guard let profileID, !profileID.isEmpty else { return }
        if self.profileID == nil { self.profileID = profileID }
    }

    mutating func bindJoin(_ join: StreamJoinKey) {
        if conversationID == nil { conversationID = join.conversationID }
        if runID == nil { runID = join.runID }
        bindProfile(join.profileID)
    }

    /// Returns false when the event cannot belong to this turn: an inactive
    /// overlay must not absorb a stream whose ids it has never seen.
    @discardableResult
    mutating func apply(_ event: StreamEvent) -> Bool {
        let incoming = Self.sessionIDs(for: event)
        if !incoming.isEmpty {
            if sessionIDs.isEmpty {
                sessionIDs.formUnion(incoming)
            } else if sessionIDs.isDisjoint(with: incoming) {
                guard phase.isActive else { return false }
                // History and live WS may name the same text turn with two ids.
                // Another session's tools are not that turn.
                if Self.isToolEvent(event) { return false }
                sessionIDs.formUnion(incoming)
            } else {
                sessionIDs.formUnion(incoming)
            }
        }

        switch event {
        case .messageStart:
            phase = .streaming
            settledTextInHistory = false
            noteProofOfLife()
        case .messageDelta(_, let delta):
            text += delta
            phase = .streaming
            settledTextInHistory = false
            noteProofOfLife()
        case .reasoningDelta(_, let delta):
            reasoning += delta
            if phase == .starting { phase = .streaming }
        case .messageComplete(_, _, let content, let reasoning):
            if let content {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    text = content
                }
            }
            if let reasoning, !reasoning.isEmpty {
                self.reasoning = reasoning
            }
            phase = tools.contains(where: { $0.status == .running }) ? .usingTool : .completing
            noteProofOfLife()
        case .messageError(_, let message):
            errorMessage = message
            failRunningTools(message)
            phase = .failed
        case .messageInterrupted:
            interruptRunningTools()
            phase = .interrupted
        case .sessionBusy(_, let busy):
            if busy {
                if phase == .starting { phase = .streaming }
            } else if !tools.contains(where: { $0.status == .running }) {
                phase = text.isEmpty && tools.isEmpty ? .interrupted : .completing
            }
        case .toolStart(_, let name, let input):
            guard name.lowercased() != "clarify" else { break }
            upsertRunningTool(name: name, input: input, replace: true)
            phase = .usingTool
        case .toolDelta(_, let name, let input, let replace):
            guard name.lowercased() != "clarify" else { break }
            upsertRunningTool(name: name, input: input, replace: replace)
            phase = .usingTool
        case .toolComplete(_, let name, let output):
            guard name.lowercased() != "clarify" else { break }
            completeTool(name: name, output: output, status: .complete)
            phase = text.isEmpty ? .usingTool : .streaming
        case .toolFailed(_, let name, let message):
            completeTool(name: name, output: message, status: .failed)
            phase = .usingTool
        case .turnYielded(_, let reason):
            guard reason == "human" else { break }
            tools.removeAll()
            errorMessage = nil
            phase = .yielded
            noteProofOfLife()
        case .sessionInfo, .sessionTitle, .reviewSummary, .clarify, .clarifyExpire,
                .approval, .contextUpdate, .cwdUpdate, .modelUpdate, .agentCount,
                .delegateAgent, .messagingRunStart, .unparsed:
            break
        }
        return true
    }

    /// Durable history is the product. Overlay text that diverged (aliased
    /// tokens, a shorter complete, a dropped stream) must not keep the spinner.
    mutating func absorbHistory(_ messages: [MessagingMessage]) {
        guard let settled = MessagingTurnHistory.completedAssistant(in: messages) else { return }
        bindProfile(settled.author)
        text = settled.body
        settledTextInHistory = true
        errorMessage = nil
        tools.removeAll()
        phase = .completing
        noteProofOfLife()
    }

    mutating func noteProofOfLife() {
        resumeSyncLossDue = false
        if lifecycleOverlay == .appBackground || lifecycleOverlay == .resumeSync
            || lifecycleOverlay == .reconnecting {
            lifecycleOverlay = .resumedStream
        }
        if lifecycleOverlay == .resumedStream {
            lifecycleOverlay = nil
        }
    }

    /// Transport tear-down (background or brief WS sleep) — not user-visible failure.
    mutating func markTransportInterrupted() {
        guard phase.isActive else { return }
    }

    /// Sync proved the run cannot be recovered.
    mutating func markTurnLost(message: String = MessagingResumeCopy.turnLost) {
        interruptRunningTools()
        errorMessage = message
        lifecycleOverlay = .turnLost
        resumeSyncLossDue = false
        phase = .failed
    }

    static func isToolEvent(_ event: StreamEvent) -> Bool {
        switch event {
        case .toolStart, .toolDelta, .toolComplete, .toolFailed: return true
        default: return false
        }
    }

    private mutating func upsertRunningTool(name: String, input: String?, replace: Bool) {
        if let index = tools.lastIndex(where: { $0.name == name && $0.status == .running }) {
            let current = tools[index].input ?? ""
            let incoming = input ?? ""
            if replace || current.isEmpty || incoming.hasPrefix(current) {
                tools[index].input = incoming.isEmpty ? current : incoming
            } else if current.hasPrefix(incoming) {
                // Keep the longer already-filled arguments.
            } else {
                tools[index].input = current + incoming
            }
            return
        }
        tools.append(ToolActivity(id: nil, name: name, input: input, output: nil, status: .running))
    }

    private mutating func completeTool(name: String, output: String?, status: ToolActivity.Status) {
        if let index = tools.lastIndex(where: { $0.name == name && $0.status == .running }) {
            tools[index].output = output
            tools[index].status = status
        } else {
            tools.append(ToolActivity(id: nil, name: name, input: nil, output: output, status: status))
        }
    }

    private mutating func failRunningTools(_ message: String) {
        for index in tools.indices where tools[index].status == .running {
            tools[index].status = .failed
            if tools[index].output == nil { tools[index].output = message }
        }
    }

    private mutating func interruptRunningTools() {
        for index in tools.indices where tools[index].status == .running {
            tools[index].status = .failed
            if tools[index].output == nil { tools[index].output = "Interrupted" }
        }
    }

    static func sessionIDs(for event: StreamEvent) -> Set<String> {
        switch event {
        case .sessionTitle(let runtimeSessionId, let storedSessionId, _):
            return Set([runtimeSessionId, storedSessionId].compactMap(normalizedSessionID))
        default:
            return Set([event.sessionID].compactMap(normalizedSessionID))
        }
    }

    static func normalizedSessionID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum MessagingTurnHistory {
    /// The bot reply for the latest user turn, if history already has it.
    static func completedAssistant(in messages: [MessagingMessage]) -> (author: String, body: String)? {
        let window: ArraySlice<MessagingMessage>
        if let userIndex = messages.lastIndex(where: { $0.author == "user" }) {
            window = messages.suffix(from: userIndex + 1)
        } else {
            window = messages[messages.startIndex...]
        }
        guard let assistant = window.last(where: { $0.author != "user" }) else { return nil }
        let body = assistant.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (assistant.author, assistant.body)
    }
}

@MainActor
protocol MessagingStreamRouting: AnyObject {
    func handleUnboundStreamEvent(_ event: StreamEvent, join: StreamJoinKey)
    func handleStreamDisconnected(reason: MessagingTransportInterruptReason)
    func handleScenePhase(_ phase: ScenePhase, gatewaySessionValid: Bool)
}
