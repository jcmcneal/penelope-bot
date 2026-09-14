import Foundation

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

        var isActive: Bool {
            switch self {
            case .starting, .streaming, .usingTool, .completing: return true
            case .interrupted, .failed: return false
            }
        }
    }

    var destinationID: String
    var profileID: String?
    var sessionIDs: Set<String> = []
    var text = ""
    var reasoning = ""
    var tools: [ToolActivity] = []
    var phase: Phase = .starting
    var errorMessage: String?
    /// True once a durable assistant message covers `text`, so the streaming
    /// bubble can hide without dropping live tool cards.
    var settledTextInHistory = false

    var acceptsNewSession: Bool { sessionIDs.isEmpty && phase.isActive }

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

    /// Returns false when the event belongs to a different bound session.
    @discardableResult
    mutating func apply(_ event: StreamEvent) -> Bool {
        let sessionID = Self.sessionID(for: event)
        if !sessionID.isEmpty {
            if sessionIDs.isEmpty {
                sessionIDs.insert(sessionID)
            } else if !sessionIDs.contains(sessionID) {
                return false
            }
        }

        switch event {
        case .messageStart:
            phase = .streaming
            settledTextInHistory = false
        case .messageDelta(_, let delta):
            text += delta
            phase = .streaming
            settledTextInHistory = false
        case .reasoningDelta(_, let delta):
            reasoning += delta
            if phase == .starting { phase = .streaming }
        case .messageComplete(_, _, let content, let reasoning):
            if let content, content.count >= text.count {
                text = content
            }
            if let reasoning, !reasoning.isEmpty {
                self.reasoning = reasoning
            }
            phase = tools.contains(where: { $0.status == .running }) ? .usingTool : .completing
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
        case .sessionInfo, .sessionTitle, .reviewSummary, .clarify, .clarifyExpire,
                .approval, .contextUpdate, .cwdUpdate, .modelUpdate, .agentCount,
                .delegateAgent, .unparsed:
            break
        }
        return true
    }

    mutating func absorbHistory(_ messages: [MessagingMessage]) {
        let assistants = messages.filter { $0.author != "user" }
        guard let latest = assistants.last else { return }
        bindProfile(latest.author)
        let body = latest.body
        guard !body.isEmpty else { return }
        if body == text || body.hasPrefix(text) || (!text.isEmpty && text.hasPrefix(body)) {
            text = body
            settledTextInHistory = true
            if !tools.contains(where: { $0.status == .running }) {
                phase = .completing
            }
        }
    }

    mutating func markDropped() {
        guard phase.isActive else { return }
        interruptRunningTools()
        if text.isEmpty && tools.isEmpty {
            errorMessage = errorMessage ?? "The reply stream dropped. Waiting for the saved message…"
        }
        phase = .interrupted
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

    static func sessionID(for event: StreamEvent) -> String {
        event.sessionID
    }
}

@MainActor
protocol MessagingStreamRouting: AnyObject {
    func handleUnboundStreamEvent(_ event: StreamEvent)
    func handleStreamDisconnected()
}
