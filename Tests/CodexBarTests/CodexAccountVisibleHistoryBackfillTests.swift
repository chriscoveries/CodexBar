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

        let targetProviderHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "acct-target")))
        let targetEmailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "target@example.com")
        let targetLegacyEmailHistoryKey = UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(
            normalizedEmail: "target@example.com")
        let sessionReset = now.addingTimeInterval(4 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            targetEmailHistoryKey: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 1, resetsAt: sessionReset),
                ]),
            ],
            targetLegacyEmailHistoryKey: [
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
        #expect(store.planUtilizationHistory[.codex]?.accounts[targetProviderHistoryKey]?.count == 2)
        #expect(store.planUtilizationHistory[.codex]?.accounts[targetLegacyEmailHistoryKey] == nil)
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

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let now = Date()
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
}
