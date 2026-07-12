import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreDisabledProviderCleanupTests {
    @Test
    func `disabled provider cleanup clears derived reset scope and warning state`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-derived")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let staleSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: Date(), resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let retainedSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: Date(), resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(staleSnapshot, provider: .kilo)
        store.lastKnownResetSnapshots[.kilo] = staleSnapshot
        store.lastKnownResetSnapshots[.codex] = retainedSnapshot
        store.kiloScopeSnapshots = [
            KiloScopeSnapshot(
                id: KiloUsageScope.personal.scopeIdentifier,
                scope: .personal,
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "personal"),
            KiloScopeSnapshot(
                id: "org-stale",
                scope: .organization(id: "org-stale", name: "Stale Org"),
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "org"),
        ]
        store.providerStorageFootprints[.kilo] = ProviderStorageFootprint(
            provider: .kilo,
            totalBytes: 42,
            paths: ["/tmp/kilo"],
            missingPaths: [],
            unreadablePaths: [],
            components: [],
            updatedAt: Date())
        store.quotaWarningState[UsageStore.QuotaWarningStateKey(provider: .kilo, window: .session)] =
            UsageStore.QuotaWarningState(lastRemaining: 20, firedThresholds: [50], source: .primary)
        store.quotaWarningState[UsageStore.QuotaWarningStateKey(provider: .codex, window: .session)] =
            UsageStore.QuotaWarningState(lastRemaining: 80, firedThresholds: [20], source: .primary)
        store.predictivePaceWarningNotifiedKeys = [
            PredictivePaceWarningStateKey(
                provider: .kilo,
                accountDiscriminator: "kilo",
                window: .session,
                resetWindow: PredictivePaceWarningResetWindow(windowMinutes: 300, resetsAt: Date())),
            PredictivePaceWarningStateKey(
                provider: .codex,
                accountDiscriminator: "codex",
                window: .session,
                resetWindow: PredictivePaceWarningResetWindow(windowMinutes: 300, resetsAt: Date())),
        ]
        store.lastTokenFetchAt[.kilo] = Date()

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.snapshot(for: .kilo) == nil)
        #expect(store.lastKnownResetSnapshots[.kilo] == nil)
        #expect(store.kiloScopeSnapshots.isEmpty)
        #expect(store.providerStorageFootprints[.kilo] == nil)
        #expect(store.quotaWarningState[UsageStore.QuotaWarningStateKey(provider: .kilo, window: .session)] == nil)
        #expect(store.predictivePaceWarningNotifiedKeys.allSatisfy { $0.provider != .kilo })
        #expect(store.lastTokenFetchAt[.kilo] == nil)

        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.usedPercent == 12)
        #expect(store.quotaWarningState[UsageStore.QuotaWarningStateKey(provider: .codex, window: .session)] != nil)
        #expect(store.predictivePaceWarningNotifiedKeys.contains { $0.provider == .codex })
    }

    @Test
    func `disabled Codex cleanup clears account snapshots and publication guard`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-codex")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let account = CodexVisibleAccount(
            id: "stale@example.com",
            email: "stale@example.com",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 33, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store.lastKnownResetSnapshots[.codex] = snapshot
        store.codexAccountSnapshots = [
            CodexAccountUsageSnapshot(account: account, snapshot: snapshot, error: nil, sourceLabel: "stale"),
        ]
        store.lastCodexUsagePublicationGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .emailOnly(normalizedEmail: "stale@example.com"),
            accountKey: "stale@example.com",
            authFingerprint: "stale-fingerprint")
        store.lastCodexAccountScopedRefreshGuard = store.lastCodexUsagePublicationGuard

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.snapshot(for: .codex) == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(store.codexAccountSnapshots.isEmpty)
        #expect(store.lastCodexUsagePublicationGuard == nil)
        #expect(store.lastCodexAccountScopedRefreshGuard != nil)
    }

    @Test
    func `disabled Claude cleanup clears swap runtime without touching settings`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-claude-swap")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeSwapEnabled = true
        settings.claudeSwapExecutablePath = "/tmp/cswap-fixture"

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        store.claudeSwapAccountSnapshots = [
            ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "1"),
                provider: .claude,
                displayLabel: "account@example.com",
                isActive: false,
                snapshot: nil,
                error: "Token expired",
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel),
        ]
        store.claudeSwapLastRefreshAt = Date()
        store.claudeSwapLastError = "stale"

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.claudeSwapAccountSnapshots.isEmpty)
        #expect(store.claudeSwapLastRefreshAt == nil)
        #expect(store.claudeSwapLastError == nil)
        #expect(settings.claudeSwapEnabled)
        #expect(settings.claudeSwapExecutablePath == "/tmp/cswap-fixture")
    }

    @Test
    func `unavailable provider cleanup clears derived reset and scope state`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreDisabledProviderCleanupTests-unavailable")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .kilo, metadata: #require(metadata[.kilo]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let staleSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 55, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(staleSnapshot, provider: .kilo)
        store.lastKnownResetSnapshots[.kilo] = staleSnapshot
        store.kiloScopeSnapshots = [
            KiloScopeSnapshot(
                id: KiloUsageScope.personal.scopeIdentifier,
                scope: .personal,
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "personal"),
            KiloScopeSnapshot(
                id: "org-stale",
                scope: .organization(id: "org-stale", name: "Stale Org"),
                snapshot: staleSnapshot,
                errorMessage: nil,
                sourceLabel: "org"),
        ]

        store.clearUnavailableProviderState(
            displayEnabledProviders: [.kilo],
            availableProviders: [])

        #expect(store.snapshot(for: .kilo) == nil)
        #expect(store.lastKnownResetSnapshots[.kilo] == nil)
        #expect(store.kiloScopeSnapshots.isEmpty)
    }

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

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
    }
}
