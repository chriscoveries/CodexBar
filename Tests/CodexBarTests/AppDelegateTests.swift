import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct AppDelegateTests {
    @Test
    func `builds status controller after launch`() {
        let appDelegate = AppDelegate()
        var factoryCalls = 0
        var ttyShutdowns = 0
        let dummyStatusController = DummyStatusController()
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "AppDelegateTests"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let account = fetcher.loadAccountInfo()
        let promotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)
        appDelegate.terminateActiveProcessesForAppShutdown = {
            ttyShutdowns += 1
        }

        // Install a test factory that records invocations without touching NSStatusBar.
        StatusItemController.factory = { _, _, _, _, _, receivedManagedCoordinator, receivedPromotionCoordinator in
            factoryCalls += 1
            #expect(receivedManagedCoordinator === managedCodexAccountCoordinator)
            #expect(receivedPromotionCoordinator === promotionCoordinator)
            return dummyStatusController
        }
        defer { StatusItemController.factory = StatusItemController.defaultFactory }

        // configure should not eagerly construct the status controller
        appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: account,
            selection: PreferencesSelection(),
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: promotionCoordinator))
        #expect(factoryCalls == 0)

        // construction happens once after launch
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 1)

        // idempotent on subsequent calls
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 1)

        // production termination should ask the status controller to detach AppKit status/menu state
        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(dummyStatusController.shutdowns == 1)
        #expect(ttyShutdowns == 1)
    }

    @Test
    func `confetti preview uses the saved provider palette`() throws {
        let suite = "AppDelegateTests-confetti-preview"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "debugDisableKeychainAccess")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            performInitialProviderDetection: false)
        #expect(settings.setConfettiPaletteHexValues(["#E94F37", "#22C55E", "#2563EB"], for: .codex))

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()
        let promotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)
        let appDelegate = AppDelegate()
        var playedPalette: [String]?
        appDelegate.playConfettiForTesting = { _, colors in
            playedPalette = colors.map(\.hexString)
        }

        StatusItemController.factory = { _, _, _, _, _, _, _ in DummyStatusController() }
        defer { StatusItemController.factory = StatusItemController.defaultFactory }
        appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            selection: PreferencesSelection(),
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: promotionCoordinator))
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        NotificationCenter.default.post(
            name: .codexbarConfettiPreviewRequested,
            object: ConfettiPreviewEvent(provider: .codex))

        #expect(playedPalette == ["#E94F37", "#22C55E", "#2563EB"])
        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
}

@MainActor
private final class DummyStatusController: StatusItemControlling {
    private(set) var shutdowns = 0

    func openMenuFromShortcut() {}
    func runLoginFlowFromSettings(provider _: UsageProvider) async {}
    func prepareForAppShutdown() {
        self.shutdowns += 1
    }
}
