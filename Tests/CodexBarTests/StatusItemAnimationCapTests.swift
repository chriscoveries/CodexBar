import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct StatusItemAnimationCapTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        .system
    }

    @Test
    func `loading animation does not restart after the continuous cap until state resets`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationCapTests"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let meta = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: meta, enabled: provider == .claude)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)
        controller.updateAnimationState()
        #expect(controller.animationDriver != nil)

        controller.animationStartedAt = .distantPast
        controller.animationDriver?.stop()
        controller.animationDriver = nil
        controller.updateAnimationState()
        #expect(controller.animationDriver == nil)
        #expect(controller.animationStartedAt == .distantPast)

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .claude)
        controller.updateAnimationState()
        #expect(controller.animationStartedAt != .distantPast)

        store._setSnapshotForTesting(nil, provider: .claude)
        controller.updateAnimationState()
        #expect(controller.animationDriver != nil)
        controller.animationDriver?.stop()
        controller.animationDriver = nil
    }

    @Test
    func `capped animation stays off after switching away from a still loading provider`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationCapTests-tab-switch"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        if let claudeMeta = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.updateAnimationState()
        #expect(controller.animationDriver != nil)
        controller.animationStartedAt = .distantPast
        controller.animationDriver?.stop()
        controller.animationDriver = nil

        settings.selectedMenuProvider = .codex
        controller.updateAnimationState()
        #expect(controller.animationDriver == nil)
        #expect(controller.animationStartedAt == .distantPast)
        #expect(controller.activeLoadingAnimationPhase() == nil)

        settings.selectedMenuProvider = .claude
        controller.updateAnimationState()
        #expect(controller.animationDriver == nil)
        #expect(controller.animationStartedAt == .distantPast)
    }
}
