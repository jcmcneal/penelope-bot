import Foundation

/// Messaging identities never enter Hermes' session/runtime identity machinery.
struct MessagingProfile: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let displayName: String
}

struct MessagingCapability: Codable, Equatable {
    let serverID: String
    let principalID: String
    let apiVersion: Int
    let state: String
    let features: [String]
    let profiles: [MessagingProfile]

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id", principalID = "principal_id", apiVersion = "api_version"
        case state, features, profiles
    }
    var isReady: Bool {
        apiVersion == 1 && state == "ready" && features.contains("dm") && !profiles.isEmpty
            && !serverID.isEmpty && !principalID.isEmpty
    }
    var supportsGroups: Bool { isReady && features.contains("groups") && profiles.count > 1 }
    var scope: String { "\(serverID.utf8.count):\(serverID)\(principalID)" }
}

enum MessagingAvailability: Equatable {
    case checking, legacy, missing, disabled, needsConfiguration, needsUpdate, ready, unavailable, forbidden

    var explanation: String {
        switch self {
        case .checking: return "Checking messaging on this Hermes instance…"
        case .legacy: return "This Hermes version does not expose plugin discovery. Your existing sessions are still available."
        case .missing: return "Add bot-coms and its messaging adapter on your Hermes server to enable persistent messages."
        case .disabled: return "bot-coms is installed but isn't enabled for this Hermes instance."
        case .needsConfiguration: return "bot-coms is installed. Its messaging adapter and participating profiles still need setup."
        case .needsUpdate: return "The messaging API on this server needs a compatible version."
        case .ready: return "Messaging is ready. Tap a bot to open its ongoing DM. Sessions remain available separately."
        case .unavailable: return "Messaging couldn't be reached. Check your connection and try again."
        case .forbidden: return "Sign in with an account that has access to messaging."
        }
    }
}

struct MessagingConversation: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let profiles: [String]
    let defaultResponder: String
    let revision: Int
    let preview: String
    let updatedAt: Double
    let unread: Int
    let archived: Bool
    let pinned: Bool
    let muted: Bool
    enum CodingKeys: String, CodingKey {
        case id, kind, title, profiles, revision, preview, unread, archived, pinned, muted
        case defaultResponder = "default_responder", updatedAt = "updated_at"
    }
}

struct MessagingMessage: Codable, Identifiable, Equatable {
    let id: String
    let sequence: Int
    let author: String
    let body: String
    let createdAt: Double
    enum CodingKeys: String, CodingKey { case id, sequence, author, body; case createdAt = "created_at" }
}

/// Display-only rewrite of `@<profile-id>` / `@{<profile-id>}` tokens.
/// Stored/API bodies keep raw ids for routing.
enum MessagingMentionDisplay {
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"@\{([A-Za-z0-9_.-]+)\}|@([A-Za-z0-9_.-]+)"#
    )
    private static let internalDestinationBodyPattern = try! NSRegularExpression(
        pattern: #"^@(?:\{([0-9a-fA-F]{16,})\}|([0-9a-fA-F]{16,}))$"#
    )

    /// Routing echoes whose entire body is an internal `@<hex-id>` destination token.
    static func isInternalDestinationBody(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return internalDestinationBodyPattern.firstMatch(in: trimmed, range: range) != nil
    }

    static func rewriteBody(_ body: String, profiles: [MessagingProfile]) -> String {
        guard !body.isEmpty, !profiles.isEmpty else { return body }
        var byID: [String: String] = [:]
        for profile in profiles {
            byID[profile.id.lowercased()] = profile.displayName
        }
        let nsBody = body as NSString
        let matches = mentionPattern.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
        guard !matches.isEmpty else { return body }
        var result = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            if full.location > cursor {
                result += nsBody.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            let token: String
            if match.range(at: 1).location != NSNotFound {
                token = nsBody.substring(with: match.range(at: 1))
            } else if match.range(at: 2).location != NSNotFound {
                token = nsBody.substring(with: match.range(at: 2))
            } else {
                result += nsBody.substring(with: full)
                cursor = full.location + full.length
                continue
            }
            if let display = byID[token.lowercased()] {
                result += "@\(display)"
            } else {
                result += nsBody.substring(with: full)
            }
            cursor = full.location + full.length
        }
        if cursor < nsBody.length {
            result += nsBody.substring(with: NSRange(location: cursor, length: nsBody.length - cursor))
        }
        return result
    }
}

struct MessagingRun: Codable, Identifiable, Equatable {
    let id: String
    let profile: String
    let status: String
    let detail: String
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case id, profile, status, detail
        case sessionID = "session_id"
    }

    init(id: String, profile: String, status: String, detail: String, sessionID: String? = nil) {
        self.id = id
        self.profile = profile
        self.status = status
        self.detail = detail
        self.sessionID = sessionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        profile = try container.decode(String.self, forKey: .profile)
        status = try container.decode(String.self, forKey: .status)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        if let sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID),
           !sessionID.isEmpty {
            self.sessionID = sessionID
        } else {
            sessionID = nil
        }
    }
}

/// Collapses messaging runs into one live avatar presence per profile.
enum MessagingRunPresence {
    struct Item: Identifiable, Equatable {
        let profile: String
        let status: String
        let detail: String
        let avatarState: AgentAvatarState

        var id: String { profile }

        var accessibilityPhrase: String {
            status.replacingOccurrences(of: "_", with: " ")
        }

        var showsDetail: Bool {
            avatarState == .blocked && !detail.isEmpty
        }
    }

    /// Maps a run status to an avatar pose, or `nil` when the run should not appear.
    static func avatarState(for status: String) -> AgentAvatarState? {
        switch status.lowercased() {
        case "completed": return nil
        case "queued": return .waiting
        case "running": return .working
        case "failed", "interrupted", "cancelled", "canceled", "error": return .blocked
        default: return .thinking
        }
    }

    /// One item per profile. Prefer running over queued over failure.
    static func collapsed(_ runs: [MessagingRun]) -> [Item] {
        var best: [String: (run: MessagingRun, state: AgentAvatarState, rank: Int)] = [:]
        for run in runs {
            guard let state = avatarState(for: run.status) else { continue }
            let rank = priority(run.status)
            if let existing = best[run.profile], existing.rank >= rank { continue }
            best[run.profile] = (run, state, rank)
        }
        return best.values
            .map { Item(profile: $0.run.profile, status: $0.run.status, detail: $0.run.detail, avatarState: $0.state) }
            .sorted { $0.profile.localizedCaseInsensitiveCompare($1.profile) == .orderedAscending }
    }

    private static func priority(_ status: String) -> Int {
        switch status.lowercased() {
        case "running": return 3
        case "queued": return 2
        case "failed", "interrupted", "cancelled", "canceled", "error": return 1
        default: return 1
        }
    }
}

struct MessagingHistory: Codable {
    let conversation: MessagingConversation
    let messages: [MessagingMessage]
    let runs: [MessagingRun]
    let before: Int?
}

struct MessagingSendReceipt: Codable {
    let conversation: MessagingConversation
    let message: MessagingMessage
    /// Active runs admitted with the send ack — used to bind the live overlay
    /// before the first history poll or WS `messaging.run.start`.
    let runs: [MessagingRun]

    init(conversation: MessagingConversation, message: MessagingMessage, runs: [MessagingRun] = []) {
        self.conversation = conversation
        self.message = message
        self.runs = runs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try container.decode(MessagingConversation.self, forKey: .conversation)
        message = try container.decode(MessagingMessage.self, forKey: .message)
        runs = try container.decodeIfPresent([MessagingRun].self, forKey: .runs) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, message, runs
    }
}

struct MessagingDestination: Identifiable, Equatable {
    let conversationID: String?
    let profileID: String?
    var id: String { conversationID.map { "conversation:\($0)" } ?? "dm:\(profileID ?? "")" }
}

/// Mixed bot / group row for the Bots pin shelf.
enum MessagingShelfItem: Identifiable, Equatable {
    case bot(MessagingProfile)
    case group(MessagingConversation)

    static let groupPinPrefix = "group:"

    static func groupPinKey(_ conversationID: String) -> String {
        groupPinPrefix + conversationID
    }

    static func groupID(fromPinKey key: String) -> String? {
        guard key.hasPrefix(groupPinPrefix) else { return nil }
        let id = String(key.dropFirst(groupPinPrefix.count))
        return id.isEmpty ? nil : id
    }

    var id: String {
        switch self {
        case .bot(let profile): return profile.id
        case .group(let conversation): return Self.groupPinKey(conversation.id)
        }
    }

    var title: String {
        switch self {
        case .bot(let profile): return profile.displayName
        case .group(let conversation): return conversation.title
        }
    }
}

struct MessagingShelfPresentation: Equatable {
    let item: MessagingShelfItem
    let preview: String
    let time: String
    let members: [MessagingProfile]
}

enum GroupStackOverflow {
    static let visibleLimit = 2

    static func badge(memberCount: Int, visibleLimit: Int = visibleLimit) -> String? {
        let extra = memberCount - visibleLimit
        return extra > 0 ? "+\(extra)" : nil
    }
}

enum MessagingThreadChrome {
    static func memberSubtitle(members: [MessagingProfile], includeYou: Bool = true) -> String {
        var names = members.map(\.displayName)
        if includeYou { names.append("You") }
        return names.joined(separator: " · ")
    }
}

enum RelativeTimestamp {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func format(_ epoch: Double?) -> String {
        guard let epoch, epoch > 0 else { return "" }
        let seconds = epoch > 10_000_000_000 ? epoch / 1_000 : epoch
        let date = Date(timeIntervalSince1970: seconds)
        guard date.timeIntervalSince1970 > 0 else { return "" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum PendingDeliveryState: Equatable, Codable {
    case inFlight
    case failed
    case uncertain
}

struct PendingMessagingSend: Codable, Equatable {
    let id: String
    let text: String
    let recipients: [String]
}

enum MessagingError: LocalizedError {
    case invalidResponse, unavailable, staleContext, unknownOutcome
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Hermes returned an invalid messaging response."
        case .unavailable: return "Messaging is not available. Your draft has been kept."
        case .staleContext: return "The connection or conversation changed."
        case .unknownOutcome: return "Delivery hasn't been confirmed. Check delivery before sending again."
        }
    }
}
