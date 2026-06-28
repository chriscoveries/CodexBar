import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexCombinedMetricHighestUsageTests {
    @Test
    func `combined codex metric uses weekly lane when ranking highest usage`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-weekly-ranking")

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 91, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        let claudeSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(claudeSnapshot, provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 91)
    }

    @Test
    func `combined codex metric stays eligible when only one lane is exhausted`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-one-exhausted")

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 100)
    }

    @Test
    func `combined codex metric is excluded when both lanes are exhausted`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-both-exhausted")

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `combined claude metric stays eligible when only one lane is exhausted`() {
        let store = self.makeStore(
            suiteName: "CodexCombinedMetricHighestUsageTests-claude-one-exhausted",
            claudeCombined: true)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 50,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // Claude's session lane is exhausted but the weekly lane still has room, so the combined
        // metric must keep Claude eligible (mirroring Codex) instead of dropping it from ranking.
        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 100)
    }

    @Test
    func `combined claude metric is excluded when both lanes are exhausted`() {
        let store = self.makeStore(
            suiteName: "CodexCombinedMetricHighestUsageTests-claude-both-exhausted",
            claudeCombined: true)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 80,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // Both Claude lanes are exhausted, so the combined metric must drop Claude from ranking and
        // surface Codex instead.
        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    private func makeStore(suiteName: String, claudeCombined: Bool = false) -> UsageStore {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)
        if claudeCombined {
            settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)
        }

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        return UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
    }
}
