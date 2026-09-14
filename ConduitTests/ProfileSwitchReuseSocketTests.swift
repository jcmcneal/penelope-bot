import XCTest
@testable import Conduit

@MainActor
final class ProfileSwitchReuseSocketTests: XCTestCase {
    func testConnectedSwitchDoesNotMintANewTicket() async throws {
        let suite = "ProfileSwitchReuseSocketTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        var mintCount = 0
        let operations = ChatResumeLifecycleOperations(
            connectClient: { _ in XCTFail("Must reuse the live socket") },
            loadCatalog: { _, _ in
                [
                    SessionSummary(
                        id: "swe-session",
                        alternateIds: [],
                        title: "SWE chat",
                        model: "Hermes",
                        updatedLabel: "now",
                        profile: "swe",
                        source: .chat,
                        isActive: false,
                        isArchived: false,
                        lineageRootId: nil
                    )
                ]
            },
            mintTicket: { _ in
                mintCount += 1
                return "should-not-mint"
            },
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in .payload(["messages": []]) },
            refreshContext: { _, _ in },
            verifyTransportHealth: { _ in },
            probeActiveSessions: { _ in [] },
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )

        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        let client = HermesClient(connection: connection, profile: "default")
        client.setConnectedForTesting(true)
        appState.connection = connection
        appState.client = client
        appState.isConnected = true
        appState.showLogin = false

        await appState.switchProfile(to: "swe")

        XCTAssertEqual(appState.activeProfile, "swe")
        XCTAssertEqual(mintCount, 0)
        XCTAssertTrue(appState.client === client)
        XCTAssertEqual(client.profile, "swe")
        XCTAssertFalse(appState.isProfileSwitching)
    }
}
