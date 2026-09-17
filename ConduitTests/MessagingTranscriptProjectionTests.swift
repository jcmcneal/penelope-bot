import XCTest
@testable import Conduit

@MainActor
final class MessagingTranscriptProjectionTests: XCTestCase {
    private let profiles = [MessagingProfile(id: "bot", name: "assistant", displayName: "Assistant")]

    private func message(_ id: String, sequence: Int = 1, body: String = "Hello @bot", author: String = "user") -> MessagingMessage {
        MessagingMessage(id: id, sequence: sequence, author: author, body: body, createdAt: 0)
    }

    func testUnchangedRefreshKeepsPreparedRows() {
        var projection = MessagingTranscriptProjection()
        let messages = [message("first")]
        XCTAssertTrue(projection.update(messages: messages, profiles: profiles))
        let prepared = projection.entriesByID["first"]

        XCTAssertFalse(projection.update(messages: messages, profiles: profiles))
        XCTAssertTrue(projection.entriesByID["first"] === prepared)
        XCTAssertEqual(projection.messages.first?.content, "Hello @Assistant")
        XCTAssertEqual(projection.messages.first?.timestamp, "1970-01-01T00:00:00Z")
        XCTAssertEqual(projection.messages.first?.role, .user)
        XCTAssertNil(projection.messages.first?.author)
    }

    func testAppendAndPrependReuseExistingRowsAndPreserveOrder() {
        var projection = MessagingTranscriptProjection()
        let middle = message("middle", sequence: 2)
        projection.update(messages: [middle], profiles: profiles)
        let prepared = projection.entriesByID["middle"]

        projection.update(messages: [message("older"), middle, message("newer", sequence: 3)], profiles: profiles)

        XCTAssertEqual(projection.messages.map(\.id), ["older", "middle", "newer"])
        XCTAssertTrue(projection.entriesByID["middle"] === prepared)
        XCTAssertEqual(projection.entriesByID.count, 3)
    }

    func testEditedMessageReplacesOnlyChangedRow() {
        var projection = MessagingTranscriptProjection()
        let unchanged = message("unchanged")
        projection.update(messages: [unchanged, message("reply", sequence: 2, author: "bot")], profiles: profiles)
        let retained = projection.entriesByID["unchanged"]
        let previousReply = projection.entriesByID["reply"]

        projection.update(messages: [unchanged, message("reply", sequence: 2, body: "Updated reply", author: "bot")], profiles: profiles)

        XCTAssertTrue(projection.entriesByID["unchanged"] === retained)
        XCTAssertFalse(projection.entriesByID["reply"] === previousReply)
        XCTAssertEqual(projection.messages.last?.content, "Updated reply")
        XCTAssertEqual(projection.messages.last?.role, .assistant)
        XCTAssertEqual(projection.messages.last?.author, "bot")
    }

    func testProfileRenameRefreshesMentionTextWithoutChangingStoredBody() {
        var projection = MessagingTranscriptProjection()
        let original = message("first")
        projection.update(messages: [original], profiles: profiles)
        let renamed = [MessagingProfile(id: "bot", name: "assistant", displayName: "New name")]

        XCTAssertTrue(projection.update(messages: [original], profiles: renamed))
        XCTAssertEqual(projection.messages.first?.content, "Hello @New name")
        XCTAssertEqual(projection.entriesByID["first"]?.source.body, "Hello @bot")
    }

    func testInternalDestinationRoutingBodyIsHiddenFromTranscript() {
        var projection = MessagingTranscriptProjection()
        let routingEcho = message(
            "routing",
            sequence: 2,
            body: "@a454f9edec9d5de0b6560bb155803bf2",
            author: "user"
        )
        projection.update(messages: [message("first"), routingEcho, message("reply", sequence: 3, author: "bot")], profiles: profiles)

        XCTAssertNil(projection.entriesByID["routing"])
        XCTAssertEqual(projection.messages.map(\.id), ["first", "reply"])
    }

    func testNormalMentionTextIsNotTreatedAsInternalDestination() {
        XCTAssertFalse(MessagingMentionDisplay.isInternalDestinationBody("Hello @bot"))
        XCTAssertFalse(MessagingMentionDisplay.isInternalDestinationBody("@swe-id"))
    }

    func testRemovedMessagesAreEvictedIncludingEmptyRefresh() {
        var projection = MessagingTranscriptProjection()
        let retained = message("second", sequence: 2)
        projection.update(messages: [message("first"), retained], profiles: profiles)
        projection.update(messages: [retained], profiles: profiles)

        XCTAssertNil(projection.entriesByID["first"])
        XCTAssertEqual(projection.messages.map(\.id), ["second"])

        projection.update(messages: [], profiles: profiles)
        XCTAssertTrue(projection.messages.isEmpty)
        XCTAssertTrue(projection.entriesByID.isEmpty)
    }
}
