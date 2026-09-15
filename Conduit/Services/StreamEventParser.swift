import Foundation

/// Join keys stamped on bot-coms plugin turns so an unbound `/api/ws`
/// firehose can bind tokens to the right overlay without guessing.
struct StreamJoinKey: Equatable, Sendable {
    var conversationID: String? = nil
    var runID: String? = nil
    var profileID: String? = nil

    static let none = StreamJoinKey()

    var isEmpty: Bool {
        conversationID == nil && runID == nil && profileID == nil
    }

    static func parse(params: AnyCodable) -> StreamJoinKey {
        let obj = params.objectValue
        let payload = obj?["payload"]?.objectValue
        return StreamJoinKey(
            conversationID: nonempty(obj?["conversation_id"]?.stringValue)
                ?? nonempty(payload?["conversation_id"]?.stringValue),
            runID: nonempty(obj?["run_id"]?.stringValue)
                ?? nonempty(payload?["run_id"]?.stringValue),
            profileID: nonempty(obj?["profile_id"]?.stringValue)
                ?? nonempty(payload?["profile_id"]?.stringValue)
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Pure-function stream event parser extracted from HermesClient so the
/// gateway-to-app boundary can be unit-tested without a live WebSocket.
enum StreamEventParser {
    static func parse(params: AnyCodable) -> StreamEvent? {
        guard let obj = params.objectValue else { return nil }
        let type = obj["type"]?.stringValue ?? ""
        let sessionId = obj["session_id"]?.stringValue ?? ""
        let payload = obj["payload"]?.objectValue

        switch type {
        case "message.start":
            return .messageStart(sessionId: sessionId)

        case "message.delta":
            let text = payload?["text"]?.stringValue ?? obj["text"]?.stringValue ?? ""
            if text.isEmpty { return nil }
            return .messageDelta(sessionId: sessionId, text: text)

        case "reasoning.delta", "message.reasoning", "message.reasoning.delta":
            let text: String
            if let reasoning = payload?["reasoning"]?.stringValue {
                text = reasoning
            } else if let reasoningContent = payload?["reasoning_content"]?.stringValue {
                text = reasoningContent
            } else if let payloadText = payload?["text"]?.stringValue {
                text = payloadText
            } else if let content = payload?["content"]?.stringValue {
                text = content
            } else if let reasoning = obj["reasoning"]?.stringValue {
                text = reasoning
            } else {
                text = obj["text"]?.stringValue ?? ""
            }
            if text.isEmpty { return nil }
            return .reasoningDelta(sessionId: sessionId, text: text)

        case "message.complete":
            let messageId = payload?["message_id"]?.stringValue
                ?? payload?["id"]?.stringValue
                ?? payload?["message"]?.objectValue?["id"]?.stringValue
                ?? obj["message_id"]?.stringValue
                ?? obj["id"]?.stringValue
            let content = payload?["content"]?.stringValue
                ?? payload?["text"]?.stringValue
                ?? payload?["rendered"]?.stringValue
            let reasoning = payload?["reasoning"]?.stringValue
            return .messageComplete(sessionId: sessionId, messageId: messageId, content: content, reasoning: reasoning)

        case "error":
            return .messageError(sessionId: sessionId, message: payload?["message"]?.stringValue ?? "Hermes reported an error.")

        case "message.interrupted", "session.interrupted":
            return .messageInterrupted(sessionId: sessionId)

        case "session.busy":
            let busy = payload?["busy"]?.boolValue ?? false
            return .sessionBusy(sessionId: sessionId, busy: busy)

        case "session.info":
            return .sessionInfo(sessionId: sessionId, snapshot: SessionRuntimeSnapshot(object: payload ?? [:]))

        case "session.title":
            let storedSessionId = payload?["session_id"]?.stringValue ?? ""
            let title = payload?["title"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !storedSessionId.isEmpty, !title.isEmpty else { return nil }
            return .sessionTitle(
                runtimeSessionId: sessionId,
                storedSessionId: storedSessionId,
                title: title
            )

        case "tool.start", "tool_call":
            return .toolStart(
                sessionId: sessionId,
                toolName: payload?["name"]?.stringValue ?? "",
                toolInput: firstDescriptiveString(in: payload, keys: ["args_text", "context", "input", "arguments", "args"])
            )

        case "tool.delta", "tool.args", "tool.input.delta", "tool_call.delta":
            let replace = payload?["arguments"] != nil
                || payload?["args"] != nil
                || payload?["input"] != nil
            let input = firstDescriptiveString(
                in: payload,
                keys: ["delta", "text", "args_text", "arguments", "args", "input"]
            ) ?? ""
            if input.isEmpty { return nil }
            return .toolDelta(
                sessionId: sessionId,
                toolName: payload?["name"]?.stringValue ?? "",
                toolInput: input,
                replace: replace
            )

        case "tool.complete", "tool_result":
            return .toolComplete(
                sessionId: sessionId,
                toolName: payload?["name"]?.stringValue ?? "",
                toolOutput: firstDescriptiveString(in: payload, keys: ["output", "result"])
            )

        case "tool.error", "tool.failed":
            let message = payload?["message"]?.stringValue
                ?? firstDescriptiveString(in: payload, keys: ["error", "output"])
                ?? "Tool failed."
            return .toolFailed(
                sessionId: sessionId,
                toolName: payload?["name"]?.stringValue ?? "",
                message: message
            )

        case "review.summary":
            guard let payload, let review = MessageNormalizer.reviewActivity(from: payload, eventSessionId: sessionId) else { return nil }
            return .reviewSummary(sessionId: sessionId, activity: review)

        case "clarify", "clarify.request":
            guard let payload,
                  let clarify = MessageNormalizer.clarifyActivity(from: payload) else { return nil }
            return .clarify(sessionId: sessionId, activity: clarify)

        case "clarify.expire":
            let requestId = (payload?["request_id"]?.stringValue
                ?? payload?["requestId"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestId.isEmpty else { return nil }
            return .clarifyExpire(sessionId: sessionId, requestId: requestId)

        case "approval.request":
            guard let payload,
                  let approval = MessageNormalizer.approvalActivity(from: payload, sessionId: sessionId) else { return nil }
            return .approval(sessionId: sessionId, activity: approval)

        case "context.update", "session.context":
            let percent = payload?["context_percent"]?.doubleValue ?? 0
            let used = payload?["context_used"]?.intValue ?? 0
            let max = payload?["context_max"]?.intValue ?? 0
            return .contextUpdate(sessionId: sessionId, percent: percent, used: used, max: max)

        case "cwd.update", "workspace.update":
            let cwd = payload?["cwd"]?.stringValue ?? ""
            return .cwdUpdate(sessionId: sessionId, cwd: cwd)

        case "model.update":
            let model = payload?["model"]?.stringValue ?? ""
            let provider = payload?["provider"]?.stringValue ?? ""
            return .modelUpdate(sessionId: sessionId, model: model, provider: provider)

        case let eventType where eventType.hasPrefix("subagent."):
            guard let payload else { return nil }
            let activity = Self.delegateAgentActivity(from: payload, eventType: eventType)
            return .delegateAgent(sessionId: sessionId, activity: activity)

        case "messaging.run.start":
            return .messagingRunStart(sessionId: sessionId)

        default:
            return .unparsed(payload: obj.mapValues { $0.anyValue })
        }
    }

    private static func firstDescriptiveString(
        in payload: [String: AnyCodable]?,
        keys: [String]
    ) -> String? {
        guard let payload else { return nil }
        for key in keys {
            if let value = payload[key]?.descriptiveStringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func delegateAgentActivity(from payload: [String: AnyCodable], eventType: String) -> DelegateAgentActivity {
        let id = payload["id"]?.stringValue ?? payload["agent_id"]?.stringValue ?? UUID().uuidString
        let statusValue = payload["status"]?.stringValue ?? {
            if eventType.contains("fail") { return "failed" }
            if eventType.contains("interrupt") { return "interrupted" }
            if eventType.contains("complete") || eventType.contains("finish") { return "completed" }
            if eventType.contains("spawn") { return "queued" }
            return "running"
        }()
        let status = DelegateAgentActivity.Status(rawValue: statusValue.lowercased()) ?? .running
        let text = payload["text"]?.stringValue ?? payload["message"]?.stringValue ?? payload["summary"]?.stringValue ?? ""
        let kind: DelegateAgentActivity.StreamLine.Kind = eventType.contains("tool") ? .tool : eventType.contains("thinking") ? .thinking : eventType.contains("progress") ? .progress : .summary
        let lines = text.isEmpty ? [] : [DelegateAgentActivity.StreamLine(kind: kind, text: text, isError: status == .failed)]
        return DelegateAgentActivity(
            id: id,
            goal: payload["goal"]?.stringValue ?? payload["task"]?.stringValue ?? "Delegate agent",
            model: payload["model"]?.stringValue,
            status: status,
            taskCount: payload["task_count"]?.intValue ?? 1,
            taskIndex: payload["task_index"]?.intValue ?? 0,
            currentTool: payload["tool"]?.stringValue ?? payload["current_tool"]?.stringValue,
            summary: payload["summary"]?.stringValue,
            stream: lines
        )
    }
}
