import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Clears ephemeral in-memory runtime/UI state for a provider that is disabled or unavailable.
    /// Does not touch settings, token-account configuration, plan-utilization history, or disk-backed
    /// Codex account snapshot cache.
    func clearProviderState(_ provider: UsageProvider) {
        self.refreshingProviders.remove(provider)
        self.snapshots.removeValue(forKey: provider)
        self.lastKnownResetSnapshots.removeValue(forKey: provider)
        self.errors[provider] = nil
        if provider == .gemini {
            self.clearGeminiConsumerTierDeprecationObservation()
        }
        self.knownLimitsAvailabilityByProvider.removeValue(forKey: provider)
        self.lastSourceLabels.removeValue(forKey: provider)
        self.lastFetchAttempts.removeValue(forKey: provider)
        self.accountSnapshots.removeValue(forKey: provider)
        if provider == .codex {
            self.codexAccountSnapshots = []
            self.lastCodexUsagePublicationGuard = nil
        }
        if provider == .kilo {
            self.kiloScopeSnapshots = []
        }
        if provider == .claude {
            self.clearClaudeSwapAccountState()
        }
        self.tokenSnapshots.removeValue(forKey: provider)
        self.tokenErrors[provider] = nil
        self.providerStorageFootprints.removeValue(forKey: provider)
        self.failureGates[provider]?.reset()
        self.tokenFailureGates[provider]?.reset()
        self.statuses.removeValue(forKey: provider)
        self.statusComponents.removeValue(forKey: provider)
        self.clearSessionQuotaTransitionState(provider: provider)
        self.predictivePaceWarningNotifiedKeys = Set(
            self.predictivePaceWarningNotifiedKeys.filter { $0.provider != provider })
        self.quotaWarningState = self.quotaWarningState.filter { $0.key.provider != provider }
        self.lastTokenFetchAt.removeValue(forKey: provider)
    }

    func clearDisabledProviderState(enabledProviders: Set<UsageProvider>) {
        for provider in UsageProvider.allCases where !enabledProviders.contains(provider) {
            self.clearProviderState(provider)
        }
    }

    func clearUnavailableProviderState(
        displayEnabledProviders: Set<UsageProvider>,
        availableProviders: Set<UsageProvider>)
    {
        for provider in displayEnabledProviders where !availableProviders.contains(provider) {
            self.clearProviderState(provider)
        }
    }
}
