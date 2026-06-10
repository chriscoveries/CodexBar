import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexAccountMenuDisplaySnapshotTests {
    @MainActor
    private static func makeSettings(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = ["tokens": [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan),
        ]]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }

    @Test
    @MainActor
    func `menu display snapshot tolerates stale cache and revalidates off the menu path`() async throws {
        let suite = "CodexAccountMenuDisplaySnapshotTests-stale-cache"
        let settings = try Self.makeSettings(suite: suite)
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "before@example.com", plan: "pro")
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": ambientHome.path]
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: ambientHome)
        }

        let primed = settings.codexAccountReconciliationSnapshot
        #expect(primed.liveSystemAccount?.email == "before@example.com")

        // Simulate a cache that has outlived the freshness interval while the auth file changed.
        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "after@example.com", plan: "pro")
        let cached = try #require(settings.cachedCodexAccountReconciliationSnapshot)
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: cached.activeSource,
            loadedAt: Date(timeIntervalSinceNow: -3600),
            snapshot: cached.snapshot)

        // The menu path returns the stale cache without a synchronous reload.
        let menuSnapshot = settings.codexAccountReconciliationSnapshotForMenuDisplay
        #expect(menuSnapshot.liveSystemAccount?.email == "before@example.com")

        // The scheduled revalidation refreshes the cache off the menu path.
        let revalidation = try #require(settings.codexAccountSnapshotRevalidationTask)
        await revalidation.value
        #expect(settings.codexAccountSnapshotRevalidationTask == nil)
        #expect(
            settings.codexAccountReconciliationSnapshotForMenuDisplay.liveSystemAccount?.email ==
                "after@example.com")
    }

    @Test
    @MainActor
    func `menu display snapshot loads synchronously without a cache`() throws {
        let suite = "CodexAccountMenuDisplaySnapshotTests-cold-cache"
        let settings = try Self.makeSettings(suite: suite)
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "cold@example.com", plan: "pro")
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": ambientHome.path]
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: ambientHome)
        }

        #expect(settings.cachedCodexAccountReconciliationSnapshot == nil)
        let menuSnapshot = settings.codexAccountReconciliationSnapshotForMenuDisplay
        #expect(menuSnapshot.liveSystemAccount?.email == "cold@example.com")
        #expect(settings.codexAccountSnapshotRevalidationTask == nil)
        #expect(settings.cachedCodexAccountReconciliationSnapshot != nil)
    }
}
