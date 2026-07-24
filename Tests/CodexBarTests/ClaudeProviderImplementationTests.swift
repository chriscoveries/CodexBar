import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeProviderImplementationTests {
    @Test
    func `prepaid balance respects optional usage setting`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage",
                balance: 100,
                updatedAt: now),
            updatedAt: now)

        var hiddenEntries: [ProviderMenuEntry] = []
        try ClaudeProviderImplementation().appendUsageMenuEntries(
            context: Self.context(snapshot: snapshot, showOptionalUsage: false),
            entries: &hiddenEntries)
        #expect(hiddenEntries.isEmpty)

        var visibleEntries: [ProviderMenuEntry] = []
        try ClaudeProviderImplementation().appendUsageMenuEntries(
            context: Self.context(snapshot: snapshot, showOptionalUsage: true),
            entries: &visibleEntries)

        guard case let .text(title, style) = try #require(visibleEntries.first) else {
            Issue.record("Expected Claude prepaid balance menu text")
            return
        }
        #expect(title == "Extra usage balance: $100.00")
        #expect(style == .primary)
        #expect(visibleEntries.count == 1)
    }

    private static func context(
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool) throws -> ProviderMenuUsageContext
    {
        let suite = "ClaudeProviderImplementationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
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
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.showOptionalCreditsAndExtraUsage = showOptionalUsage
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        return ProviderMenuUsageContext(
            provider: .claude,
            store: store,
            settings: settings,
            metadata: ClaudeProviderDescriptor.descriptor.metadata,
            snapshot: snapshot)
    }
}
