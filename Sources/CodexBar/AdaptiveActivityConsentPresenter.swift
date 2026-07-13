import AppKit

@MainActor
enum AdaptiveActivityConsentPresenter {
    private static var isPresenting = false

    @discardableResult
    static func presentIfNeeded(settings: SettingsStore) -> Bool {
        guard !SettingsStore.isRunningTests,
              !self.isPresenting,
              settings.shouldRequestAdaptiveActivityScanConsent
        else { return false }

        self.isPresenting = true
        defer { self.isPresenting = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("adaptive_activity_consent_title")
        alert.informativeText = L("adaptive_activity_consent_message")
        alert.addButton(withTitle: L("adaptive_activity_consent_allow"))
        let declineButton = alert.addButton(withTitle: L("adaptive_activity_consent_decline"))
        declineButton.keyEquivalent = "\u{1B}"

        NSApp.activate(ignoringOtherApps: true)
        settings.adaptiveActivityScanConsent = alert.runModal() == .alertFirstButtonReturn ? .allowed : .declined
        return true
    }
}
