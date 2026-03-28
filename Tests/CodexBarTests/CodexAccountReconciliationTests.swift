import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexAccountReconciliationTests {
    @Test
    @MainActor
    func `settings store exposes codex reconciliation accessors using managed and live overrides`() throws {
        let suite = "CodexAccountReconciliationTests-settings-store"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managed
        settings._test_liveSystemCodexAccount = live
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(snapshot.storedAccounts.map(\.id) == [managed.id])
        #expect(snapshot.storedAccounts.map(\.email) == [managed.email])
        #expect(snapshot.activeStoredAccount?.id == managed.id)
        #expect(snapshot.activeStoredAccount?.email == managed.email)
        #expect(snapshot.liveSystemAccount == live)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(snapshot.hasUnreadableAddedAccountStore == false)
        #expect(Set(projection.visibleAccounts.map(\.email)) == ["managed@example.com", "system@example.com"])
        #expect(settings.codexVisibleAccounts == projection.visibleAccounts)
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
    }

    @Test
    @MainActor
    func `settings store managed override does not leak ambient live system account`() throws {
        let suite = "CodexAccountReconciliationTests-managed-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let managed = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        settings._test_activeManagedCodexAccount = managed
        defer {
            settings._test_activeManagedCodexAccount = nil
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(snapshot.liveSystemAccount == nil)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(projection.visibleAccounts.map(\.email) == ["managed@example.com"])
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == nil)
    }

    @Test
    @MainActor
    func `settings store reconciliation environment override drives live observation with synthetic store`() throws {
        let suite = "CodexAccountReconciliationTests-environment-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "ambient@example.com", plan: "pro")
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": ambientHome.path]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: ambientHome)
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(snapshot.storedAccounts.isEmpty)
        #expect(snapshot.activeStoredAccount == nil)
        #expect(snapshot.liveSystemAccount?.email == "ambient@example.com")
        #expect(snapshot.liveSystemAccount?.codexHomePath == ambientHome.path)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(projection.visibleAccounts.map(\.email) == ["ambient@example.com"])
        #expect(projection.activeVisibleAccountID == "ambient@example.com")
        #expect(projection.liveVisibleAccountID == "ambient@example.com")
        #expect(projection.switchableAccountIDs.isEmpty)
    }

    @Test
    @MainActor
    func `settings store home path override also keeps reconciliation hermetic`() throws {
        let suite = "CodexAccountReconciliationTests-home-path-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_activeManagedCodexRemoteHomePath = "/tmp/managed-route-home"
        defer {
            settings._test_activeManagedCodexRemoteHomePath = nil
        }

        let snapshot = settings.codexAccountReconciliationSnapshot
        let projection = settings.codexVisibleAccountProjection

        #expect(snapshot.storedAccounts.isEmpty)
        #expect(snapshot.activeStoredAccount == nil)
        #expect(snapshot.liveSystemAccount == nil)
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(projection.visibleAccounts.isEmpty)
        #expect(projection.activeVisibleAccountID == nil)
        #expect(projection.liveVisibleAccountID == nil)
    }

    @Test
    func `fresh install projects live-only account as visible active and live`() {
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [], activeAccountID: nil)
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        #expect(projection.liveVisibleAccountID == "live@example.com")
        #expect(projection.switchableAccountIDs.isEmpty)
    }

    @Test
    func `matching live system account does not duplicate stored identity`() {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "user@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [stored], activeAccountID: stored.id)
        let live = ObservedSystemCodexAccount(
            email: "USER@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.count == 1)
        #expect(projection.activeVisibleAccountID == "user@example.com")
        #expect(projection.liveVisibleAccountID == "user@example.com")
        #expect(projection.switchableAccountIDs == ["user@example.com"])
    }

    @Test
    func `matching live system account becomes active when readable store has no active pointer`() {
        let matched = ManagedCodexAccount(
            id: UUID(),
            email: "match@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let other = ManagedCodexAccount(
            id: UUID(),
            email: "other@example.com",
            managedHomePath: "/tmp/managed-b",
            createdAt: 4,
            updatedAt: 5,
            lastAuthenticatedAt: 6)
        let accounts = ManagedCodexAccountSet(
            version: 1,
            accounts: [matched, other],
            activeAccountID: nil)
        let live = ObservedSystemCodexAccount(
            email: "MATCH@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == [
            "match@example.com",
            "other@example.com",
        ])
        #expect(projection.activeVisibleAccountID == "match@example.com")
        #expect(projection.liveVisibleAccountID == "match@example.com")
        #expect(Set(projection.switchableAccountIDs) == [
            "match@example.com",
            "other@example.com",
        ])
    }

    @Test
    func `live system account that differs from active stored account remains visible`() {
        let active = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [active], activeAccountID: active.id)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == ["managed@example.com", "system@example.com"])
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
        #expect(projection.switchableAccountIDs == ["managed@example.com"])
    }

    @Test
    func `inactive stored account still appears as visible and switchable`() {
        let active = ManagedCodexAccount(
            id: UUID(),
            email: "active@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let inactive = ManagedCodexAccount(
            id: UUID(),
            email: "inactive@example.com",
            managedHomePath: "/tmp/managed-b",
            createdAt: 4,
            updatedAt: 5,
            lastAuthenticatedAt: 6)
        let accounts = ManagedCodexAccountSet(
            version: 1,
            accounts: [active, inactive],
            activeAccountID: active.id)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == [
            "active@example.com",
            "inactive@example.com",
            "system@example.com",
        ])
        #expect(projection.activeVisibleAccountID == "active@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
        #expect(Set(projection.switchableAccountIDs) == [
            "active@example.com",
            "inactive@example.com",
        ])
    }

    @Test
    func `unreadable account store still exposes live system account and degraded flag`() {
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { throw FileManagedCodexAccountStoreError.unsupportedVersion(999) },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com"])
        #expect(projection.activeVisibleAccountID == nil)
        #expect(projection.liveVisibleAccountID == "live@example.com")
        #expect(projection.hasUnreadableAddedAccountStore)
        #expect(projection.switchableAccountIDs.isEmpty)
    }

    @Test
    func `whitespace only live email is ignored`() {
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [], activeAccountID: nil)
        let live = ObservedSystemCodexAccount(
            email: "   \n\t  ",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.isEmpty)
        #expect(projection.activeVisibleAccountID == nil)
        #expect(projection.liveVisibleAccountID == nil)
        #expect(projection.switchableAccountIDs.isEmpty)
    }
}

private struct StubSystemObserver: CodexSystemAccountObserving {
    let account: ObservedSystemCodexAccount?

    func loadSystemAccount(environment _: [String: String]) throws -> ObservedSystemCodexAccount? {
        self.account
    }
}

extension CodexAccountReconciliationTests {
    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
