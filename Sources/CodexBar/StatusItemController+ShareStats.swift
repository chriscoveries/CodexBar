import AppKit
import CodexBarCore

extension StatusItemController {
    func installShareStatsObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handleShareStatsNotification),
            name: .codexbarShareStats,
            object: nil)
    }

    @objc func showShareStats(_ sender: NSMenuItem) {
        _ = sender
        self.presentShareStats()
    }

    @objc func handleShareStatsNotification() {
        self.presentShareStats()
    }

    private func presentShareStats() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sources = await self.shareStatsSources()
            guard let payload = ShareStatsBuilder.make(providers: sources) else {
                NSSound.beep()
                return
            }
            let controller = self.shareStatsWindow ?? ShareStatsWindowController(payload: payload)
            controller.update(payload: payload)
            self.shareStatsWindow = controller
            controller.present()
        }
    }

    private func shareStatsSources() async -> [ShareStatsProviderSource] {
        var sources: [ShareStatsProviderSource] = []
        for provider in self.store.enabledProviders() {
            if provider == .codex {
                let subscriptions = await self.store.codexSubscriptionCostSnapshots(force: false)
                if !subscriptions.isEmpty {
                    let accountUsage = Dictionary(uniqueKeysWithValues: self.store.codexAccountSnapshots
                        .compactMap { snapshot in
                            snapshot.snapshot.map { (snapshot.id, $0) }
                        })
                    sources.append(contentsOf: subscriptions.map { subscription in
                        let usageSnapshot = accountUsage[subscription.id]
                            ?? (subscriptions.count == 1 ? self.store.snapshot(for: .codex) : nil)
                        return ShareStatsProviderSource(
                            providerName: subscription.displayName,
                            subscriptionName: self.shareStatsSubscriptionName(
                                provider: .codex,
                                snapshot: usageSnapshot),
                            tokenSnapshot: subscription.tokenSnapshot,
                            usageSnapshot: usageSnapshot)
                    })
                    continue
                }
            }

            let usageSnapshot = self.store.snapshot(for: provider)
            sources.append(ShareStatsProviderSource(
                providerName: self.store.metadata(for: provider).displayName,
                subscriptionName: self.shareStatsSubscriptionName(
                    provider: provider,
                    snapshot: usageSnapshot),
                tokenSnapshot: self.store.tokenSnapshot(for: provider)
                    ?? self.store.tokenSnapshot(
                        fromProviderSnapshot: usageSnapshot,
                        provider: provider),
                usageSnapshot: usageSnapshot))
        }
        return sources
    }

    private func shareStatsSubscriptionName(
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> String?
    {
        guard let rawName = snapshot?.loginMethod(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawName.isEmpty
        else { return nil }

        let name = if provider == .codex {
            CodexPlanFormatting.displayName(rawName) ?? UsageFormatter.cleanPlanName(rawName)
        } else {
            UsageFormatter.cleanPlanName(rawName)
        }
        return name.isEmpty ? nil : name
    }
}
