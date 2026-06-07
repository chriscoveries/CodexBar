import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `same account token refresh fingerprint change keeps codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-fingerprint-change")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 25)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `usage success applies when auth fingerprint appears after refresh starts`() {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-auth-fingerprint-appears")
        defer {
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: nil,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexAccountScopedRefreshGuard()

        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))

        #expect(store.shouldApplyCodexUsageResult(
            expectedGuard: expectedGuard,
            usage: self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
    }

    @Test
    func `same account token refresh fingerprint change discards codex usage failure`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-fingerprint-failure")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .failure(TestRefreshError(message: "old token failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same account token refresh fingerprint change keeps codex credits success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-credits-success")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        store._test_codexCreditsLoaderOverride = {
            settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
                email: "alpha@example.com",
                authFingerprint: "new-token-material",
                codexHomePath: "/Users/test/.codex",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-alpha"))
            return CreditsSnapshot(remaining: 42, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        await store.refreshCreditsIfNeeded()

        #expect(store.credits?.remaining == 42)
        #expect(store.lastCreditsSnapshotAccountKey == "alpha@example.com")
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
        #expect(store.lastCreditsError == nil)
    }

    @Test
    func `credits refresh key separates same account auth fingerprints`() {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-credits-key-auth-fingerprint")
        let store = self.makeUsageStore(settings: settings)
        let oldGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .providerAccount(id: "acct-alpha"),
            accountKey: "alpha@example.com",
            authFingerprint: "old-token-material")
        let newGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .providerAccount(id: "acct-alpha"),
            accountKey: "alpha@example.com",
            authFingerprint: "new-token-material")

        #expect(store.codexCreditsRefreshKey(expectedGuard: oldGuard) !=
            store.codexCreditsRefreshKey(expectedGuard: newGuard))
    }

    @Test
    func `same account token refresh fingerprint change keeps dashboard success`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-dashboard-success")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexOpenAIWebRefreshGuard()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
                email: "alpha@example.com",
                authFingerprint: "new-token-material",
                codexHomePath: "/Users/test/.codex",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-alpha"))
            return self.dashboard(email: "alpha@example.com", creditsRemaining: 64, usedPercent: 27)
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.openAIDashboard?.creditsRemaining == 64)
        #expect(store.openAIDashboard?.signedInEmail == "alpha@example.com")
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(store.openAIDashboardRequiresLogin == false)
    }

    @Test
    func `dashboard refresh key separates same account auth fingerprints`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-dashboard-key-auth-fingerprint")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let oldGuard = store.freshCodexOpenAIWebRefreshGuard()
        let oldRefreshTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: oldGuard)
        }
        await blocker.waitUntilStarted(count: 1)

        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let newGuard = store.freshCodexOpenAIWebRefreshGuard()
        let newRefreshTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: newGuard)
        }

        let didStartFreshRefresh = await blocker.waitUntilStartedWithin(count: 2)
        #expect(didStartFreshRefresh)
        guard didStartFreshRefresh else {
            await blocker.resumeNext(with: .failure(TestRefreshError(message: "stale dashboard failure")))
            await oldRefreshTask.value
            await newRefreshTask.value
            return
        }
        await blocker.resumeNext(with: .failure(TestRefreshError(message: "old dashboard failure")))
        await blocker.resumeNext(with: .success(self.dashboard(
            email: "alpha@example.com",
            creditsRemaining: 64,
            usedPercent: 27)))
        await oldRefreshTask.value
        await newRefreshTask.value

        #expect(store.openAIDashboard?.creditsRemaining == 64)
        #expect(store.lastOpenAIDashboardError == nil)
    }

    @Test
    func `same account token refresh fingerprint change discards dashboard failure`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-dashboard-failure")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexOpenAIWebRefreshGuard()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
                email: "alpha@example.com",
                authFingerprint: "new-token-material",
                codexHomePath: "/Users/test/.codex",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-alpha"))
            throw TestRefreshError(message: "old dashboard failure")
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(store.openAIDashboardRequiresLogin == false)
    }

    @Test
    func `same account token refresh fingerprint change discards dashboard policy failure`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-dashboard-policy-failure")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexOpenAIWebRefreshGuard()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        await store.applyOpenAIDashboard(
            self.dashboard(email: "other@example.com", creditsRemaining: 64, usedPercent: 27),
            targetEmail: "alpha@example.com",
            expectedGuard: expectedGuard)

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(store.openAIDashboardRequiresLogin == false)
    }

    @Test
    func `stacked visible refresh discards selected failure after managed token fingerprint rotates`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-token-failure")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-444444444444"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-333333333333"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-token-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-token-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-token@example.com",
            providerAccountID: "acct-managed-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-token",
            authFingerprint: "old-managed-token",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let updatedTarget = ManagedCodexAccount(
            id: targetID,
            email: "managed-token@example.com",
            providerAccountID: "acct-managed-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-token",
            authFingerprint: "new-managed-token",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 3,
            lastAuthenticatedAt: 3)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-token-sibling@example.com",
            providerAccountID: "acct-managed-token-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-token-sibling",
            authFingerprint: "sibling-managed-token",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-token-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try FileManagedCodexAccountStore(fileURL: storeURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [updatedTarget, siblingAccount]))
        await blocker.resume(with: .failure(TestRefreshError(message: "old managed token failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-token"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-token"
        })
    }

    @Test
    func `managed failure guard reads current auth file fingerprint`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-managed-auth-file-fingerprint")
        settings.refreshFrequency = .manual
        let accountID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-555555555555"))
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-auth-file-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed-auth@example.com",
            plan: "Pro",
            accountId: "acct-managed-auth")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        let managedAccount = ManagedCodexAccount(
            id: accountID,
            email: "managed-auth@example.com",
            providerAccountID: "acct-managed-auth",
            workspaceLabel: "Managed Auth",
            workspaceAccountID: "acct-managed-auth",
            authFingerprint: oldFingerprint,
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: accountID)

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexAccountScopedRefreshGuard()
        #expect(expectedGuard.authFingerprint == oldFingerprint)

        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed-auth@example.com",
            plan: "Team",
            accountId: "acct-managed-auth")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        #expect(newFingerprint != oldFingerprint)

        #expect(store.freshCodexAccountScopedRefreshGuard().authFingerprint == newFingerprint)
        #expect(!store.shouldApplyCodexScopedFailure(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyCodexScopedNonUsageFailure(expectedGuard: expectedGuard))
    }

    @Test
    func `stale auth fingerprint cache at refresh start keeps current codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-stale-start-cache-current-auth")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 33)))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 33)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-email-only-auth")
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same provider account live email change discards stale codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-provider-email-change")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "old@example.com",
            authFingerprint: "old-provider-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-shared"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "new@example.com",
            authFingerprint: "new-provider-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-shared"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "old@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same email email-only auth fingerprint switch discards stale codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-email-only-fingerprint-switch")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }
}
