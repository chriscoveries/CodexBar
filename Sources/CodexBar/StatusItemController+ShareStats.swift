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
                    let accountUsage = Dictionary(uniqueKeysWithValues: self.store.codexAccountSnapshots.compactMap {
                        snapshot in
                        snapshot.snapshot.map { (snapshot.id, $0) }
                    })
                    sources.append(contentsOf: subscriptions.map { subscription in
                        ShareStatsProviderSource(
                            providerName: subscription.displayName,
                            tokenSnapshot: subscription.tokenSnapshot,
                            usageSnapshot: accountUsage[subscription.id] ?? self.store.snapshot(for: .codex))
                    })
                    continue
                }
            }

            sources.append(ShareStatsProviderSource(
                providerName: self.store.metadata(for: provider).displayName,
                tokenSnapshot: self.store.tokenSnapshot(for: provider)
                    ?? self.store.tokenSnapshot(
                        fromProviderSnapshot: self.store.snapshot(for: provider),
                        provider: provider),
                usageSnapshot: self.store.snapshot(for: provider)))
        }
        return sources
    }
}
