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
        let sources = self.store.enabledProviders().map { provider in
            ShareStatsProviderSource(
                providerName: self.store.metadata(for: provider).displayName,
                tokenSnapshot: self.store.tokenSnapshot(for: provider)
                    ?? self.store.tokenSnapshot(
                        fromProviderSnapshot: self.store.snapshot(for: provider),
                        provider: provider),
                usageSnapshot: self.store.snapshot(for: provider))
        }
        guard let payload = ShareStatsBuilder.make(providers: sources)
        else {
            NSSound.beep()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let controller = self.shareStatsWindow ?? ShareStatsWindowController(payload: payload)
            controller.update(payload: payload)
            self.shareStatsWindow = controller
            controller.present()
        }
    }
}
