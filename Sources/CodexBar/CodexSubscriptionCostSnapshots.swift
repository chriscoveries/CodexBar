import CodexBarCore
import CryptoKit
import Foundation

struct CodexSubscriptionCostSnapshot: Identifiable, Sendable {
    let id: String
    let displayName: String
    let tokenSnapshot: CostUsageTokenSnapshot?
}

extension UsageStore {
    func codexSubscriptionCostPlaceholders() -> [CodexSubscriptionCostSnapshot] {
        let projection = self.settings.codexVisibleAccountProjection
        return projection.visibleAccounts.enumerated().map { index, account in
            CodexSubscriptionCostSnapshot(
                id: account.id,
                displayName: self.codexSubscriptionDisplayName(index: index, count: projection.visibleAccounts.count),
                tokenSnapshot: account.id == projection.activeVisibleAccountID
                    ? self.tokenSnapshot(for: .codex)
                    : nil)
        }
    }

    /// Returns one identity-free row per visible Codex subscription.
    ///
    /// The active account reuses the normal provider snapshot (which also includes local Pi
    /// sessions). Sibling account homes are scanned independently with Pi disabled so shared local
    /// tool history is counted once instead of once per account.
    func codexSubscriptionCostSnapshots(force: Bool) async -> [CodexSubscriptionCostSnapshot] {
        let projection = self.settings.codexVisibleAccountProjection
        let accounts = projection.visibleAccounts
        guard !accounts.isEmpty else { return [] }

        if accounts.count == 1 { return self.codexSubscriptionCostPlaceholders() }

        var results: [CodexSubscriptionCostSnapshot] = []
        results.reserveCapacity(accounts.count)
        for (index, account) in accounts.enumerated() {
            let isActive = account.id == projection.activeVisibleAccountID
            let snapshot: CostUsageTokenSnapshot? = if isActive,
                                                       let current = self.tokenSnapshot(for: .codex)
            {
                current
            } else {
                await self.loadCodexSubscriptionCostSnapshot(
                    account: account,
                    force: force,
                    includePiSessions: isActive)
            }
            results.append(CodexSubscriptionCostSnapshot(
                id: account.id,
                displayName: self.codexSubscriptionDisplayName(index: index, count: accounts.count),
                tokenSnapshot: snapshot))
        }
        return results
    }

    private func loadCodexSubscriptionCostSnapshot(
        account: CodexVisibleAccount,
        force: Bool,
        includePiSessions: Bool) async -> CostUsageTokenSnapshot?
    {
        let homePath = self.codexHomePath(for: account)
        let cacheRoot = Self.costUsageCacheDirectory()
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(Self.costUsageAccountCacheKey(account.id), isDirectory: true)
        let fetcher = CostUsageFetcher(cacheRoot: cacheRoot)
        let now = Date()
        let historyDays = self.settings.costUsageHistoryDays
        let timeoutSeconds = self.tokenFetchTimeout
        let environment = self.environmentBase

        return try? await withThrowingTaskGroup(of: CostUsageTokenSnapshot.self) { group in
            group.addTask(priority: .utility) {
                try await fetcher.loadTokenSnapshot(
                    provider: .codex,
                    environment: environment,
                    now: now,
                    forceRefresh: force,
                    codexHomePath: homePath,
                    historyDays: historyDays,
                    includePiSessions: includePiSessions)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CostUsageError.timedOut(seconds: Int(timeoutSeconds))
            }
            defer { group.cancelAll() }
            guard let snapshot = try await group.next(), !snapshot.daily.isEmpty else {
                return nil
            }
            return snapshot
        }
    }

    private func codexHomePath(for account: CodexVisibleAccount) -> String? {
        switch account.selectionSource {
        case .liveSystem:
            self.settings.liveSystemCodexHomePath(forActiveSource: .liveSystem)
        case let .managedAccount(id):
            self.settings.managedCodexRemoteHomePath(forActiveSource: .managedAccount(id: id))
        case let .profileHome(path):
            self.settings.profileCodexHomePath(forActiveSource: .profileHome(path: path))
        }
    }

    private func codexSubscriptionDisplayName(index: Int, count: Int) -> String {
        let providerName = self.metadata(for: .codex).displayName
        return count == 1 ? providerName : "\(providerName) · #\(index + 1)"
    }

    private nonisolated static func costUsageAccountCacheKey(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
