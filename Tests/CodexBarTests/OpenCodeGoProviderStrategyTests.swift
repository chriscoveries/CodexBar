import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeGoProviderStrategyTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(sourceMode: ProviderSourceMode = .auto) -> ProviderFetchContext {
        let env: [String: String] = [:]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    @Test
    func `auto source prefers local history before web fallback`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(self.makeContext())

        #expect(strategies.map(\.id) == ["opencodego.local", "opencodego.web"])
    }

    @Test
    func `web source does not include local fallback`() async {
        let descriptor = OpenCodeGoProviderDescriptor.makeDescriptor()
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(self.makeContext(sourceMode: .web))

        #expect(strategies.map(\.id) == ["opencodego.web"])
    }

    @Test
    func `local strategy falls through to web when local history is unavailable`() {
        let strategy = OpenCodeGoLocalUsageFetchStrategy()
        let context = self.makeContext()

        #expect(strategy.shouldFallback(on: OpenCodeGoLocalUsageError.notDetected, context: context))
        #expect(strategy.shouldFallback(
            on: OpenCodeGoLocalUsageError.historyUnavailable("database not found"),
            context: context))
        #expect(strategy.shouldFallback(
            on: OpenCodeGoLocalUsageError.sqliteFailed("database is locked"),
            context: context))
        #expect(!strategy.shouldFallback(on: OpenCodeGoUsageError.networkError("timeout"), context: context))
    }

    @Test
    func `web strategy falls through only for auth setup failures in auto mode`() {
        let strategy = OpenCodeGoUsageFetchStrategy()
        let autoContext = self.makeContext()
        let webContext = self.makeContext(sourceMode: .web)

        #expect(strategy.shouldFallback(on: OpenCodeGoSettingsError.missingCookie, context: autoContext))
        #expect(strategy.shouldFallback(on: OpenCodeGoSettingsError.invalidCookie, context: autoContext))
        #expect(strategy.shouldFallback(on: OpenCodeGoUsageError.invalidCredentials, context: autoContext))
        #expect(!strategy.shouldFallback(on: OpenCodeGoUsageError.networkError("timeout"), context: autoContext))
        #expect(!strategy.shouldFallback(on: OpenCodeGoSettingsError.missingCookie, context: webContext))
    }
}
