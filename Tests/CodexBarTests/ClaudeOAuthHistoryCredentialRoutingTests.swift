import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthHistoryCredentialRoutingTests {
    @Test
    func `history keychain reference only matches the credential that won routing`() throws {
        let keychainData = self.makeCredentialsData(accessToken: "keychain-token")
        let keychainCredentials = try ClaudeOAuthCredentials.parse(data: keychainData)
        let differentCredentials = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "different-token"))
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 1,
            createdAt: 1,
            persistentRefHash: "opaque-ref")

        let matchingCLIRecord = ClaudeOAuthCredentialRecord(
            credentials: keychainCredentials,
            owner: .claudeCLI,
            source: .memoryCache)
        let differentCLIRecord = ClaudeOAuthCredentialRecord(
            credentials: differentCredentials,
            owner: .claudeCLI,
            source: .credentialsFile)
        let matchingEnvironmentRecord = ClaudeOAuthCredentialRecord(
            credentials: keychainCredentials,
            owner: .environment,
            source: .environment)
        let matchingCodexBarRecord = ClaudeOAuthCredentialRecord(
            credentials: keychainCredentials,
            owner: .codexbar,
            source: .cacheKeychain)

        ProviderInteractionContext.$current.withValue(.userInitiated) {
            ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                    data: keychainData,
                    fingerprint: fingerprint)
                {
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: matchingCLIRecord) == "opaque-ref")
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: differentCLIRecord) == nil)
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: matchingEnvironmentRecord) == nil)
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: matchingCodexBarRecord) == nil)
                }
            }
        }
    }

    @Test
    func `newest duplicate reference cannot label a different winning credential`() throws {
        let winningCredentials = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "winning-token"))
        let newestCandidateCredentials = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "newest-candidate-token"))
        let winningRecord = ClaudeOAuthCredentialRecord(
            credentials: winningCredentials,
            owner: .claudeCLI,
            source: .memoryCache)
        let newestCandidateRecord = ClaudeOAuthCredentialRecord(
            credentials: newestCandidateCredentials,
            owner: .claudeCLI,
            source: .claudeKeychain)

        #expect(ClaudeOAuthCredentialsStore._matchingClaudeKeychainPersistentRefHashForTesting(
            record: winningRecord,
            candidateCredentials: newestCandidateCredentials,
            persistentRefHash: "newest-candidate-ref") == nil)
        #expect(ClaudeOAuthCredentialsStore._matchingClaudeKeychainPersistentRefHashForTesting(
            record: newestCandidateRecord,
            candidateCredentials: newestCandidateCredentials,
            persistentRefHash: "newest-candidate-ref") == "newest-candidate-ref")
    }

    private func makeCredentialsData(accessToken: String) -> Data {
        let expiresAt = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(expiresAt),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }
}
