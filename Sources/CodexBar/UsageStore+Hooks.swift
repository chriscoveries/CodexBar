import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Builds a `HookEvent` and dispatches it to any matching external hooks.
    ///
    /// Fire-and-forget: the actual process runs on a detached task so nothing
    /// blocks the menu-bar refresh. No-op unless the user enabled hooks.
    /// `usagePercent` is a 0...1 fraction.
    func emitHook(
        _ type: HookEventType,
        provider: UsageProvider,
        window: String? = nil,
        usagePercent: Double? = nil,
        resetAt: Date? = nil,
        status: String? = nil,
        accountDisplayName: String? = nil)
    {
        guard let hooks = self.settings.config.hooks, hooks.enabled else { return }

        let event = HookEvent(
            event: type,
            provider: provider.rawValue,
            account: accountDisplayName,
            window: window,
            usagePercent: usagePercent,
            resetAt: resetAt,
            status: status,
            timestamp: Date())

        let limiter = self.hookRateLimiter
        let environment = self.environmentBase
        Task.detached(priority: .utility) {
            await HookRunner.dispatch(
                event: event,
                config: hooks,
                rateLimiter: limiter,
                baseEnvironment: environment)
        }
    }

    func emitQuotaReachedHook(
        provider: UsageProvider,
        sessionWindow: (window: RateWindow, source: SessionQuotaWindowSource),
        snapshot: UsageSnapshot)
    {
        self.emitHook(
            .quotaReached,
            provider: provider,
            window: QuotaWarningWindow.session.displayName,
            usagePercent: sessionWindow.window.usedPercent / 100,
            resetAt: sessionWindow.window.resetsAt,
            accountDisplayName: self.hookAccountDisplayName(provider: provider, snapshot: snapshot))
    }

    /// Emits `provider_unavailable` / `provider_recovered` on genuine outage
    /// transitions. `.unknown` (transient/first fetch) and `.maintenance` never
    /// flip the tracked state, so a hiccuped status probe cannot fire a hook.
    func emitProviderStatusHooks(provider: UsageProvider, indicator: ProviderStatusIndicator) {
        let isOutage: Bool
        switch indicator {
        case .minor, .major, .critical:
            isOutage = true
        case .none:
            isOutage = false
        case .maintenance, .unknown:
            return
        }

        let wasOutage = self.providerStatusHadIssue[provider] ?? false
        if isOutage, !wasOutage {
            self.providerStatusHadIssue[provider] = true
            self.emitHook(.providerUnavailable, provider: provider, status: indicator.rawValue)
        } else if !isOutage, wasOutage {
            self.providerStatusHadIssue[provider] = false
            self.emitHook(.providerRecovered, provider: provider, status: indicator.rawValue)
        }
    }

    /// Account label for a hook payload, redacted when the user hides personal info.
    func hookAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }
}
