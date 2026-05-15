import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeResilienceTests {
    @Test
    func `suppresses single flake when prior data exists`() {
        var gate = ConsecutiveFailureGate()
        let firstFailure = gate.shouldSurfaceError(onFailureWithPriorData: true)
        let secondFailure = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(firstFailure == false)
        #expect(secondFailure == true)
    }

    @Test
    func `surfaces failure without prior data`() {
        var gate = ConsecutiveFailureGate()
        let shouldSurface = gate.shouldSurfaceError(onFailureWithPriorData: false)
        #expect(shouldSurface)
    }

    @Test
    func `resets after success`() {
        var gate = ConsecutiveFailureGate()
        _ = gate.shouldSurfaceError(onFailureWithPriorData: true)
        gate.recordSuccess()
        let shouldSurface = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(shouldSurface == false)
    }

    @MainActor
    @Test
    func `timeout keeps prior Claude snapshot and surfaces repeated failure`() async throws {
        let settings = Self.makeSettingsStore(suite: "ClaudeResilienceTests-timeout-cache")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeUsageDataSource = .cli

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: provider == .claude)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let prior = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "claude@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        store._setSnapshotForTesting(prior, provider: .claude)

        let baseSpec = try #require(store.providerSpecs[.claude])
        let descriptor = ProviderDescriptor(
            id: .claude,
            metadata: baseSpec.descriptor.metadata,
            branding: baseSpec.descriptor.branding,
            tokenCost: baseSpec.descriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.cli],
                pipeline: ProviderFetchPipeline { _ in [TimeoutFetchStrategy()] }),
            cli: baseSpec.descriptor.cli)
        store.providerSpecs[.claude] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)

        await store.refreshProvider(.claude)

        #expect(store.snapshot(for: .claude)?.updatedAt == prior.updatedAt)
        #expect(store.error(for: .claude) == nil)

        await store.refreshProvider(.claude)

        #expect(store.snapshot(for: .claude)?.updatedAt == prior.updatedAt)
        #expect(store.error(for: .claude) != nil)
    }

    @MainActor
    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
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
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        return settings
    }
}

private struct TimeoutFetchStrategy: ProviderFetchStrategy {
    let id = "test.timeout"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw ClaudeStatusProbeError.timedOut
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
