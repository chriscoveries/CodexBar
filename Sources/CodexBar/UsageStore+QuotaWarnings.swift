import CodexBarCore
import Foundation

extension UsageStore {
    enum SessionQuotaWindowSource: String {
        case primary
        case copilotSecondaryFallback
        case zaiTertiary
        case antigravityQuotaSummary
        case antigravityLegacy
    }

    struct QuotaWarningStateKey: Hashable {
        let provider: UsageProvider
        let window: QuotaWarningWindow
        /// Distinguishes independent extra rate windows that share a provider/window lane
        /// (e.g. multiple `claude-weekly-scoped-*` windows) so their fired-threshold state
        /// does not clobber each other or the primary session/weekly lanes. `nil` for the
        /// primary session and weekly lanes.
        let windowID: String?

        init(provider: UsageProvider, window: QuotaWarningWindow, windowID: String? = nil) {
            self.provider = provider
            self.window = window
            self.windowID = windowID
        }
    }

    struct QuotaWarningState {
        var lastRemaining: Double?
        var firedThresholds: Set<Int> = []
        var source: SessionQuotaWindowSource?
    }

    /// Per-refresh constants shared across the quota-warning lanes: which window
    /// source is active, the redacted account label, and whether notifications and
    /// hooks are each enabled for this provider.
    struct QuotaWarningTransitionContext {
        let source: SessionQuotaWindowSource?
        let accountDisplayName: String?
        let notificationsEnabled: Bool
        let hooksActive: Bool
    }
}

@MainActor
extension UsageStore {
    func handleQuotaWarningTransitions(provider: UsageProvider, snapshot: UsageSnapshot) {
        let notificationsEnabled = self.settings.quotaWarningNotificationsEnabled
        // Hooks have their own enable switch, so a configured quota_low hook must
        // fire even when the user turned quota warning notifications off.
        let hooksActive = self.hasQuotaHookRule(event: .quotaLow, provider: provider)
        guard notificationsEnabled || hooksActive else { return }
        if provider == .commandcode, snapshot.commandCodeSubscriptionEnrichmentUnavailable { return }

        let accountDisplayName = self.quotaWarningAccountDisplayName(provider: provider, snapshot: snapshot)
        let source: SessionQuotaWindowSource? = if provider == .antigravity {
            Self.hasAntigravityQuotaSummaryWindows(snapshot: snapshot)
                ? .antigravityQuotaSummary
                : .antigravityLegacy
        } else {
            nil
        }
        let primaryWindow: RateWindow?
        let secondaryWindow: RateWindow?
        if provider == .antigravity {
            primaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 5 * 60)
            secondaryWindow = Self.antigravityWindow(snapshot: snapshot, windowMinutes: 7 * 24 * 60)
        } else {
            primaryWindow = provider == .mimo || provider == .qoder ? nil : snapshot.primary
            secondaryWindow = provider == .mimo || provider == .qoder ? nil : snapshot.secondary
        }
        let context = QuotaWarningTransitionContext(
            source: source,
            accountDisplayName: accountDisplayName,
            notificationsEnabled: notificationsEnabled,
            hooksActive: hooksActive)
        self.handleQuotaWarningTransition(
            provider: provider,
            window: .session,
            rateWindow: primaryWindow,
            context: context)
        self.handleQuotaWarningTransition(
            provider: provider,
            window: .weekly,
            rateWindow: secondaryWindow,
            context: context)
        self.handleClaudeExtraWindowQuotaWarnings(
            provider: provider,
            snapshot: snapshot,
            context: context)
    }

    /// Emit weekly-lane quota warnings for Claude's extra rate windows — model-scoped weekly
    /// carve-outs (`claude-weekly-scoped-*`, e.g. Fable) and Daily Routines — which surface in the
    /// menu but were otherwise silent. Antigravity's summary windows are already covered by the
    /// primary and weekly lanes above, so they are excluded here.
    private func handleClaudeExtraWindowQuotaWarnings(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        context: QuotaWarningTransitionContext)
    {
        guard provider == .claude else { return }
        let weeklyNotify = context.notificationsEnabled
            && self.settings.quotaWarningEnabled(provider: provider, window: .weekly)
        guard weeklyNotify || context.hooksActive else {
            let extraWindowKeys = self.quotaWarningState.keys.filter {
                $0.provider == provider && $0.windowID != nil
            }
            for key in extraWindowKeys {
                self.quotaWarningState.removeValue(forKey: key)
            }
            return
        }

        let windows = (snapshot.extraRateWindows ?? []).filter(Self.isClaudeNotifiableExtraWindow)
        for named in windows {
            self.handleQuotaWarningTransition(
                provider: provider,
                window: .weekly,
                rateWindow: named.window,
                context: context,
                windowID: named.id,
                windowDisplayLabel: named.title)
        }
        // A missing extras payload is not authoritative, but when another notifiable window remains,
        // reconcile tracked IDs so a later incarnation of a disappeared window can warn again.
        guard !windows.isEmpty else { return }
        let activeIDs = Set(windows.map(\.id))
        let staleKeys = self.quotaWarningState.keys.filter { key in
            guard key.provider == provider, let windowID = key.windowID else { return false }
            return !activeIDs.contains(windowID)
        }
        for key in staleKeys {
            self.quotaWarningState.removeValue(forKey: key)
        }
    }

    private static func isClaudeNotifiableExtraWindow(_ named: NamedRateWindow) -> Bool {
        guard named.usageKnown else { return false }
        return named.id.hasPrefix("claude-weekly-scoped-") || named.id == "claude-routines"
    }

    private func handleQuotaWarningTransition(
        provider: UsageProvider,
        window: QuotaWarningWindow,
        rateWindow: RateWindow?,
        context: QuotaWarningTransitionContext,
        windowID: String? = nil,
        windowDisplayLabel: String? = nil)
    {
        let source = context.source
        let accountDisplayName = context.accountDisplayName
        let key = QuotaWarningStateKey(provider: provider, window: window, windowID: windowID)
        let notify = context.notificationsEnabled
            && self.settings.quotaWarningEnabled(provider: provider, window: window)
        guard notify || context.hooksActive else {
            self.quotaWarningState.removeValue(forKey: key)
            return
        }
        guard let rateWindow else {
            self.quotaWarningState.removeValue(forKey: key)
            return
        }

        let thresholds = self.settings.resolvedQuotaWarningThresholds(provider: provider, window: window)
        let currentRemaining = rateWindow.remainingPercent
        let previousState = self.quotaWarningState[key]
        if let previousState, previousState.source != source {
            self.quotaWarningState[key] = QuotaWarningState(
                lastRemaining: currentRemaining,
                source: source)
            return
        }
        var state = previousState ?? QuotaWarningState(source: source)
        let cleared = QuotaWarningNotificationLogic.thresholdsToClear(
            currentRemaining: currentRemaining,
            alreadyFired: state.firedThresholds)
        state.firedThresholds.subtract(cleared)

        if let threshold = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: state.lastRemaining,
            currentRemaining: currentRemaining,
            thresholds: thresholds,
            alreadyFired: state.firedThresholds)
        {
            state.firedThresholds.formUnion(QuotaWarningNotificationLogic.firedThresholdsAfterWarning(
                threshold: threshold,
                thresholds: thresholds))
            if notify {
                self.postQuotaWarning(
                    QuotaWarningEvent(
                        window: window,
                        threshold: threshold,
                        currentRemaining: currentRemaining,
                        accountDisplayName: accountDisplayName,
                        windowID: windowID,
                        windowDisplayLabel: windowDisplayLabel),
                    provider: provider)
            }
            self.emitHook(
                .quotaLow,
                provider: provider,
                window: windowDisplayLabel ?? window.displayName,
                usagePercent: rateWindow.usedPercent / 100,
                resetAt: rateWindow.resetsAt,
                accountDisplayName: accountDisplayName)
        }

        state.lastRemaining = currentRemaining
        self.quotaWarningState[key] = state
    }

    private func quotaWarningAccountDisplayName(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard !self.settings.hidePersonalInfo else { return nil }
        let account = snapshot.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account, !account.isEmpty else { return nil }
        return account
    }
}
