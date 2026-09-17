import Foundation

/// Prepared once per transcript change, rather than once per visible row or composer update.
@MainActor
struct MessagingTranscriptProjection {
    final class Entry {
        let source: MessagingMessage
        let chat: ChatMessage

        init(source: MessagingMessage, chat: ChatMessage) {
            self.source = source
            self.chat = chat
        }
    }

    private(set) var entriesByID: [String: Entry] = [:]
    private(set) var messages: [ChatMessage] = []
    private var sourceMessages: [MessagingMessage] = []
    private var profiles: [MessagingProfile] = []
    private static let timestampFormatter = ISO8601DateFormatter()

    static func timestampString(for epoch: Double) -> String {
        timestampFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Retains prepared messages across appends and edits, and drops entries removed by refresh.
    /// Profile changes also invalidate mention display names embedded in message content.
    @discardableResult
    mutating func update(messages incoming: [MessagingMessage], profiles incomingProfiles: [MessagingProfile]) -> Bool {
        let profilesChanged = profiles != incomingProfiles
        guard sourceMessages != incoming || profilesChanged else { return false }

        var nextEntries: [String: Entry] = [:]
        nextEntries.reserveCapacity(incoming.count)
        var nextMessages: [ChatMessage] = []
        nextMessages.reserveCapacity(incoming.count)
        for source in incoming {
            if MessagingMentionDisplay.isInternalDestinationBody(source.body) {
                continue
            }
            let entry: Entry
            if !profilesChanged, let existing = entriesByID[source.id], existing.source == source {
                entry = existing
            } else {
                entry = Entry(
                    source: source,
                    chat: ChatMessage(
                        id: source.id,
                        role: source.author == "user" ? .user : .assistant,
                        content: MessagingMentionDisplay.rewriteBody(source.body, profiles: incomingProfiles),
                        timestamp: Self.timestampFormatter.string(from: Date(timeIntervalSince1970: source.createdAt)),
                        author: source.author == "user" ? nil : source.author
                    )
                )
            }
            nextEntries[source.id] = entry
            nextMessages.append(entry.chat)
        }
        sourceMessages = incoming
        profiles = incomingProfiles
        entriesByID = nextEntries
        messages = nextMessages
        return true
    }
}
