import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct ClaudeAutoKeychainPromptPolicyTests {
    @Test
    func oauthKeychainPromptCooldownEnabled_autoMode_userInitiatedPolicy() {
        #if DEBUG
        #expect(ClaudeOAuthFetchStrategy._oauthKeychainPromptCooldownEnabledForTesting(
            sourceMode: .auto,
            trigger: .background,
            policy: .userInitiated) == true)
        #expect(ClaudeOAuthFetchStrategy._oauthKeychainPromptCooldownEnabledForTesting(
            sourceMode: .auto,
            trigger: .userInitiated,
            policy: .userInitiated) == false)
        #expect(ClaudeOAuthFetchStrategy._oauthKeychainPromptCooldownEnabledForTesting(
            sourceMode: .auto,
            trigger: .background,
            policy: .never) == true)
        #expect(ClaudeOAuthFetchStrategy._oauthKeychainPromptCooldownEnabledForTesting(
            sourceMode: .auto,
            trigger: .background,
            policy: .always) == false)
        #expect(ClaudeOAuthFetchStrategy._oauthKeychainPromptCooldownEnabledForTesting(
            sourceMode: .oauth,
            trigger: .background,
            policy: .userInitiated) == false)
        #else
        Issue.record("Test requires DEBUG helpers")
        #endif
    }

    @Test
    func oauthKeychainPromptAllowed_autoMode_userInitiatedPolicy_respectsTrigger() async throws {
        #if DEBUG && os(macOS)
        let strategy = ClaudeOAuthFetchStrategy()

        let claudeSettings = ProviderSettingsSnapshot.ClaudeProviderSettings(
            usageDataSource: .auto,
            webExtrasEnabled: false,
            cookieSource: .auto,
            manualCookieHeader: nil,
            autoKeychainPromptPolicy: .userInitiated)
        let settings = ProviderSettingsSnapshot.make(claude: claudeSettings)

        let env: [String: String] = [:]
        let fetcher = UsageFetcher(environment: env)
        let contextBackground = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            trigger: .background,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: fetcher,
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))
        let contextUserInitiated = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            trigger: .userInitiated,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: fetcher,
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))

        actor Recorder {
            private(set) var values: [Bool] = []

            func record(_ value: Bool) {
                self.values.append(value)
            }
        }
        let recorder = Recorder()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")

        try await KeychainCacheStore.withServiceOverrideForTesting(
            "ClaudeAutoKeychainPromptPolicyTests-\(UUID().uuidString)")
        {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                ClaudeOAuthCredentialsStore.setKeychainAccessOverrideForTesting(true)
                defer { ClaudeOAuthCredentialsStore.setKeychainAccessOverrideForTesting(nil) }

                let override: @Sendable ([String: String], Bool, Bool) async throws
                    -> ClaudeOAuthCredentials = { _, allowKeychainPrompt, _ in
                        await recorder.record(allowKeychainPrompt)
                        throw ClaudeOAuthCredentialsError.notFound
                    }

                ClaudeOAuthCredentialsStore.invalidateCache()
                do {
                    _ = try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(override) {
                        try await strategy.fetch(contextBackground)
                    }
                } catch {}
                let backgroundValues = await recorder.values
                #expect(backgroundValues.last == false)

                ClaudeOAuthCredentialsStore.invalidateCache()
                do {
                    _ = try await ClaudeUsageFetcher.$loadOAuthCredentialsOverride.withValue(override) {
                        try await strategy.fetch(contextUserInitiated)
                    }
                } catch {}
                let userInitiatedValues = await recorder.values
                #expect(userInitiatedValues.last == true)
            }
        }
        #else
        Issue.record("Test requires DEBUG + macOS")
        #endif
    }
}
