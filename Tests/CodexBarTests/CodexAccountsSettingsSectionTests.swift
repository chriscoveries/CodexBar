import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexAccountsSettingsSectionTests {
    @Test
    func `codex accounts section shows live badge only for live only multi account row`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-live-badge")
        let store = Self.makeUsageStore(settings: settings)
        let managedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managedStoreURL) }

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccount]))

        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())
        let liveAccount = try #require(state.visibleAccounts.first { $0.email == "live@example.com" })
        let managedVisibleAccount = try #require(state.visibleAccounts.first { $0.email == "managed@example.com" })

        #expect(state.showsLiveBadge(for: liveAccount))
        #expect(state.showsLiveBadge(for: managedVisibleAccount) == false)
    }

    @Test
    func `single account codex settings uses simple account view instead of picker`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-single-account")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "solo@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.visibleAccounts.count == 1)
        #expect(state.showsActivePicker == false)
        #expect(state.singleVisibleAccount?.email == "solo@example.com")
    }

    @Test
    func `codex accounts section disables managed mutations when store is unreadable`() throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-unreadable")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_unreadableManagedCodexAccountStore = true
        defer { settings._test_unreadableManagedCodexAccountStore = false }

        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())
        let liveAccount = try #require(state.visibleAccounts.first)

        #expect(state.hasUnreadableManagedAccountStore)
        #expect(state.canAddAccount == false)
        #expect(state.notice?.tone == .warning)
        #expect(state.canReauthenticate(liveAccount))
    }

    @Test
    func `adding managed codex account auto selects the merged live row`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-add-merged")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "same@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let coordinator = Self.makeManagedCoordinator(settings: settings, email: "same@example.com")
        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator)

        await pane._test_addManagedCodexAccount()

        #expect(settings.codexActiveSource == .liveSystem)
        let state = try #require(pane._test_codexAccountsSectionState())
        #expect(state.activeVisibleAccountID == "same@example.com")
    }

    @Test
    func `adding managed codex account selects the new managed account when email differs`() async throws {
        let settings = Self.makeSettingsStore(suite: "CodexAccountsSettingsSectionTests-add-managed")
        let store = Self.makeUsageStore(settings: settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        let coordinator = Self.makeManagedCoordinator(settings: settings, email: "managed@example.com")
        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator)

        await pane._test_addManagedCodexAccount()

        guard case .managedAccount = settings.codexActiveSource else {
            Issue.record("Expected the new managed account to become active")
            return
        }
        let state = try #require(pane._test_codexAccountsSectionState())
        #expect(state.activeVisibleAccountID == "managed@example.com")
    }

    private static func makeManagedCoordinator(
        settings: SettingsStore,
        email: String)
        -> ManagedCodexAccountCoordinator
    {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        settings._test_managedCodexAccountStoreURL = storeURL
        let service = ManagedCodexAccountService(
            store: store,
            homeFactory: TestManagedCodexHomeFactoryForSettingsSectionTests(root: root),
            loginRunner: StubManagedCodexLoginRunnerForSettingsSectionTests.success,
            identityReader: StubManagedCodexIdentityReaderForSettingsSectionTests(emails: [email]))
        return ManagedCodexAccountCoordinator(service: service)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }
}

private struct TestManagedCodexHomeFactoryForSettingsSectionTests: ManagedCodexHomeProducing, Sendable {
    let root: URL
    private let nextID = UUID().uuidString

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(self.nextID, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexLoginRunnerForSettingsSectionTests: ManagedCodexLoginRunning, Sendable {
    let result: CodexLoginRunner.Result

    func run(homePath _: String, timeout _: TimeInterval) async -> CodexLoginRunner.Result {
        self.result
    }

    static let success = StubManagedCodexLoginRunnerForSettingsSectionTests(
        result: CodexLoginRunner.Result(outcome: .success, output: "ok"))
}

private final class StubManagedCodexIdentityReaderForSettingsSectionTests: ManagedCodexIdentityReading,
@unchecked Sendable {
    private var emails: [String]

    init(emails: [String]) {
        self.emails = emails
    }

    func loadAccountInfo(homePath _: String) throws -> AccountInfo {
        let email = self.emails.isEmpty ? nil : self.emails.removeFirst()
        return AccountInfo(email: email, plan: "Pro")
    }
}
