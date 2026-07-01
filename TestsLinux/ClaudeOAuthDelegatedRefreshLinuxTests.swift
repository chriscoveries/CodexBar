import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshLinuxTests {
    private actor Counter {
        private var value = 0

        func increment() {
            self.value += 1
        }

        func current() -> Int {
            self.value
        }
    }

    @Test
    func cliOAuthDoesNotDelegateRefreshEvenForUserAction() async {
        let result = await self.runDelegatedRefresh(
            runtime: .cli,
            interaction: .userInitiated,
            promptMode: .always)

        #expect(result.attempts == 0)
        #expect(result.message.contains("CodexBar CLI does not launch Claude"))
    }

    @Test
    func appOAuthPreservesUserInitiatedDelegatedRefresh() async {
        let result = await self.runDelegatedRefresh(
            runtime: .app,
            interaction: .userInitiated,
            promptMode: .onlyOnUserAction)

        #expect(result.attempts == 1)
        #expect(result.message.contains("still unavailable after delegated Claude CLI refresh"))
    }

    @Test
    func appOAuthPreservesBackgroundPromptPolicy() async {
        let result = await self.runDelegatedRefresh(
            runtime: .app,
            interaction: .background,
            promptMode: .onlyOnUserAction)

        #expect(result.attempts == 0)
        #expect(result.message.contains("background repair is suppressed"))
    }

    private func runDelegatedRefresh(
        runtime: ProviderRuntime,
        interaction: ProviderInteraction,
        promptMode: ClaudeOAuthKeychainPromptMode) async -> (attempts: Int, message: String)
    {
        let counter = Counter()
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            runtime: runtime,
            dataSource: .oauth)
        let credentialsOverride: @Sendable (
            [String: String],
            Bool,
            Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
                throw ClaudeOAuthCredentialsError.refreshDelegatedToClaudeCLI
            }
        let delegatedOverride: @Sendable (
            Date,
            TimeInterval,
            [String: String]) async -> ClaudeOAuthDelegatedRefreshCoordinator.Outcome = { _, _, _ in
                await counter.increment()
                return .attemptedSucceeded
            }

        do {
            _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
                try await ProviderInteractionContext.$current.withValue(interaction) {
                    try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride
                        .withValue(credentialsOverride) {
                            try await ClaudeUsageFetcher.$delegatedRefreshAttemptOverride
                                .withValue(delegatedOverride) {
                                    try await fetcher.loadLatestUsage(model: "sonnet")
                                }
                        }
                }
            }
            Issue.record("Expected delegated-refresh path to fail with mocked stale credentials")
            return (await counter.current(), "")
        } catch let error as ClaudeUsageError {
            guard case let .oauthFailed(message) = error else {
                Issue.record("Expected ClaudeUsageError.oauthFailed, got \(error)")
                return (await counter.current(), "")
            }
            return (await counter.current(), message)
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
            return (await counter.current(), "")
        }
    }
}
