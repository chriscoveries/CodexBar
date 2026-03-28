import CodexBarCore
import Foundation

extension UsageStore {
    var codexSnapshot: UsageSnapshot? {
        self.snapshots[.codex]
    }

    var claudeSnapshot: UsageSnapshot? {
        self.snapshots[.claude]
    }

    var lastCodexError: String? {
        self.errors[.codex]
    }

    var lastClaudeError: String? {
        self.errors[.claude]
    }

    func error(for provider: UsageProvider) -> String? {
        self.errors[provider]
    }

    func status(for provider: UsageProvider) -> ProviderStatus? {
        guard self.statusChecksEnabled else { return nil }
        return self.statuses[provider]
    }

    func statusIndicator(for provider: UsageProvider) -> ProviderStatusIndicator {
        self.status(for: provider)?.indicator ?? .none
    }

    func accountInfo(for provider: UsageProvider) -> AccountInfo {
        guard provider == .codex else {
            return self.codexFetcher.loadAccountInfo()
        }
        let env = ProviderRegistry.makeEnvironment(
            base: ProcessInfo.processInfo.environment,
            provider: .codex,
            settings: self.settings,
            tokenOverride: nil)
        let fetcher = ProviderRegistry.makeFetcher(base: self.codexFetcher, provider: .codex, env: env)
        return fetcher.loadAccountInfo()
    }
}
