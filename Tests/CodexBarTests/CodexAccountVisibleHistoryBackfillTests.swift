import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `repairs collapsed codex windows from matching provider account history`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-333333333333"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "target@example.com",
            providerAccountID: "acct-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "sibling@example.com",
            providerAccountID: "acct-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-sibling",
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
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 1 : 22,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        let targetHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "acct-target")))
        let sessionReset = now.addingTimeInterval(4 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            targetHistoryKey: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 1, resetsAt: sessionReset),
                ]),
                planSeries(name: .weekly, windowMinutes: 10080, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 13, resetsAt: weeklyReset),
                ]),
            ],
        ])

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 1)
        #expect(targetSnapshot.primary?.windowMinutes == 300)
        #expect(targetSnapshot.primary?.resetsAt == sessionReset)
        #expect(targetSnapshot.secondary?.usedPercent == 13)
        #expect(targetSnapshot.secondary?.windowMinutes == 10080)
        #expect(targetSnapshot.secondary?.resetsAt == weeklyReset)

        let siblingSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-sibling"
        }?.snapshot)
        #expect(siblingSnapshot.primary?.windowMinutes == 0)
        #expect(siblingSnapshot.primary?.resetsAt == nil)
        #expect(siblingSnapshot.secondary == nil)

        let persistedTarget = try #require(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-target"
        }?.snapshot)
        #expect(persistedTarget.primary?.resetsAt == sessionReset)
        #expect(persistedTarget.secondary?.resetsAt == weeklyReset)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == sessionReset)
        #expect(store.snapshots[.codex]?.secondary?.resetsAt == weeklyReset)
        #expect(store.planUtilizationHistory[.codex]?.accounts[targetHistoryKey]?.count == 2)
    }

    @Test
    func `materializes single visible codex account email history into provider account history`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-single-account-materialize")
        let store = self.makeUsageStore(settings: settings)
        let visibleAccount = CodexVisibleAccount(
            id: "materialize@example.com",
            email: "materialize@example.com",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-materialize",
            storedAccountID: nil,
            selectionSource: .managedAccount(id: UUID()),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let providerHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "acct-materialize")))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "materialize@example.com")
        let legacyEmailHistoryKey = UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(
            normalizedEmail: "materialize@example.com")
        let session = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_000_000), usedPercent: 1),
        ])
        let weekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_086_400), usedPercent: 13),
        ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [session],
            legacyEmailHistoryKey: [weekly],
        ])

        let histories = store.codexPlanUtilizationHistories(forVisibleAccount: visibleAccount)

        #expect(histories == [session, weekly])
        #expect(store.planUtilizationHistory[.codex]?.accounts[providerHistoryKey] == [session, weekly])
        #expect(store.planUtilizationHistory[.codex]?.accounts[emailHistoryKey] == nil)
        #expect(store.planUtilizationHistory[.codex]?.accounts[legacyEmailHistoryKey] == nil)
    }

    @Test
    func `ignores active reset cache from another visible codex workspace`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-stale-active-cache")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-444444444444"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-555555555555"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-cache-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-cache-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "shared@example.com",
            providerAccountID: "acct-cache-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-cache-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "shared@example.com",
            providerAccountID: "acct-cache-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-cache-sibling",
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
        let now = Date()
        let staleReset = now.addingTimeInterval(2 * 60 * 60)
        store.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: .managedAccount(id: siblingID),
            identity: .providerAccount(id: "acct-cache-sibling"),
            accountKey: "shared@example.com")
        store.lastKnownResetSnapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 44,
                windowMinutes: 300,
                resetsAt: staleReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 55,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "shared@example.com",
                accountOrganization: nil,
                loginMethod: "Sibling Team"))
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-cache-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 0)
        #expect(targetSnapshot.primary?.resetsAt == nil)
        #expect(targetSnapshot.secondary == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.secondary == nil)
        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.resetsAt == nil)
        #expect(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-cache-target"
        }?.snapshot?.primary?.resetsAt == nil)
    }

    @Test
    func `uses active reset cache when scoped guard matches codex workspace with plan label`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-current-active-cache")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-666666666666"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-777777777777"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-current-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-current-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "current@example.com",
            providerAccountID: "acct-current-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-current-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "current@example.com",
            providerAccountID: "acct-current-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-current-sibling",
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

        let now = Date()
        let staleSessionReset = now.addingTimeInterval(3 * 60 * 60)
        let staleWeeklyReset = now.addingTimeInterval(3 * 24 * 60 * 60)
        let priorSnapshots = settings.codexVisibleAccountProjection.visibleAccounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: account.workspaceAccountID == "acct-current-target"
                    ? UsageSnapshot(
                        primary: RateWindow(
                            usedPercent: 2,
                            windowMinutes: 300,
                            resetsAt: staleSessionReset,
                            resetDescription: nil),
                        secondary: RateWindow(
                            usedPercent: 3,
                            windowMinutes: 10080,
                            resetsAt: staleWeeklyReset,
                            resetDescription: nil),
                        updatedAt: now.addingTimeInterval(-60))
                    : nil,
                error: nil,
                sourceLabel: "cached")
        }
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let sessionReset = now.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        store.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: .managedAccount(id: targetID),
            identity: .providerAccount(id: "acct-current-target"),
            accountKey: "current@example.com")
        store.lastKnownResetSnapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 44,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 55,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "current@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-current-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 300)
        #expect(targetSnapshot.primary?.resetsAt == sessionReset)
        #expect(targetSnapshot.secondary?.usedPercent == 55)
        #expect(targetSnapshot.secondary?.windowMinutes == 10080)
        #expect(targetSnapshot.secondary?.resetsAt == weeklyReset)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == sessionReset)
        #expect(store.snapshots[.codex]?.secondary?.resetsAt == weeklyReset)
        #expect(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-current-target"
        }?.snapshot?.secondary?.resetsAt == weeklyReset)
    }

    @Test
    func `ignores prior snapshot from same email different codex workspace`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-prior-workspace")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-888888888888"))
        let oldID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999999"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-AAAAAAAAAAAA"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-prior-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-prior-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "prior@example.com",
            providerAccountID: "acct-prior-new",
            workspaceLabel: "New Team",
            workspaceAccountID: "acct-prior-new",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "other-prior@example.com",
            providerAccountID: "acct-prior-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-prior-sibling",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let oldVisibleAccount = CodexVisibleAccount(
            id: "prior@example.com",
            email: "prior@example.com",
            workspaceLabel: "Old Team",
            workspaceAccountID: "acct-prior-old",
            storedAccountID: oldID,
            selectionSource: .managedAccount(id: oldID),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let now = Date()
        let staleReset = now.addingTimeInterval(2 * 60 * 60)
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [
            CodexAccountUsageSnapshot(
                account: oldVisibleAccount,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 72,
                        windowMinutes: 300,
                        resetsAt: staleReset,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: now,
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: "prior@example.com",
                        accountOrganization: nil,
                        loginMethod: "Old Team")),
                error: nil,
                sourceLabel: "cached"),
        ])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-prior-new"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 0)
        #expect(targetSnapshot.primary?.resetsAt == nil)
        #expect(targetSnapshot.secondary == nil)
    }

    @Test
    func `ignores ambiguous email history for same email codex workspaces`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-ambiguous-email-history")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-111111111111"))
        let siblingID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-222222222222"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-history-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-history-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "history-shared@example.com",
            providerAccountID: "acct-history-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-history-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "history-shared@example.com",
            providerAccountID: "acct-history-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-history-sibling",
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
        let now = Date()
        let normalizedEmail = try #require(CodexIdentityResolver.normalizeEmail("history-shared@example.com"))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 2, resetsAt: now.addingTimeInterval(3600)),
                ]),
                planSeries(name: .weekly, windowMinutes: 10080, entries: [
                    planEntry(
                        at: now.addingTimeInterval(-60),
                        usedPercent: 33,
                        resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
                ]),
            ],
        ])
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-history-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 0)
        #expect(targetSnapshot.primary?.resetsAt == nil)
        #expect(targetSnapshot.secondary == nil)
        #expect(store.planUtilizationHistory[.codex]?.histories(for: emailHistoryKey).isEmpty == false)
    }
}
