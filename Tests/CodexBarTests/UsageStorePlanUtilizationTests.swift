import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationTests {
    @Test
    func codexUsesProviderCostWhenAvailable() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date())
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(try abs(#require(percent) - 25) < 0.001)
    }

    @Test
    func claudeIgnoresProviderCostForMonthlyHistory() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 40,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .claude,
            snapshot: snapshot,
            credits: nil)

        #expect(percent == nil)
    }

    @Test
    func codexFallsBackToCredits() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let credits = CreditsSnapshot(remaining: 640, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(try abs(#require(percent) - 36) < 0.001)
    }

    @Test
    func codexFreePlanWithoutFreshCreditsReturnsNil() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: nil)

        #expect(percent == nil)
    }

    @Test
    func codexPaidPlanDoesNotUseCreditsFallback() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "plus")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(percent == nil)
    }

    @Test
    func claudeWithoutProviderCostReturnsNil() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date())
        let credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .claude,
            snapshot: snapshot,
            credits: credits)

        #expect(percent == nil)
    }

    @Test
    @MainActor
    func codexWithinWindowPromotesMonthlyFromNilWithoutAppending() async {
        let store = self.makeUsageStore(suite: "UsageStorePlanUtilizationTests-promoteMonthly")
        store.planUtilizationHistory[.codex] = []

        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let now = Date()

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            now: now)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            credits: CreditsSnapshot(remaining: 640, events: [], updatedAt: now),
            now: now.addingTimeInterval(300))

        let history = store.planUtilizationHistory(for: .codex)
        #expect(history.count == 1)
        let monthly = history.last?.monthlyUsedPercent
        #expect(monthly != nil)
        #expect(abs((monthly ?? 0) - 36) < 0.001)
    }

    @Test
    @MainActor
    func codexWithinWindowIgnoresNilMonthlyAfterKnownValue() async {
        let store = self.makeUsageStore(suite: "UsageStorePlanUtilizationTests-ignoreNilMonthly")
        store.planUtilizationHistory[.codex] = []

        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let now = Date()

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            credits: CreditsSnapshot(remaining: 640, events: [], updatedAt: now),
            now: now)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            credits: nil,
            now: now.addingTimeInterval(300))

        let history = store.planUtilizationHistory(for: .codex)
        #expect(history.count == 1)
        let monthly = history.last?.monthlyUsedPercent
        #expect(monthly != nil)
        #expect(abs((monthly ?? 0) - 36) < 0.001)
    }

    @MainActor
    private func makeUsageStore(suite: String) -> UsageStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }
}
