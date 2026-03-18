import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    private nonisolated static let claudeBootstrapAnonymousAccountKey = "__claude_bootstrap_anonymous__"
    private nonisolated static let planUtilizationMinSampleIntervalSeconds: TimeInterval = 60 * 60
    private nonisolated static let planUtilizationMaxSamples: Int = 24 * 730

    func planUtilizationHistory(for provider: UsageProvider) -> [PlanUtilizationHistorySample] {
        if self.shouldDeferClaudePlanUtilizationHistory(provider: provider) {
            return []
        }

        guard provider == .claude else {
            let accountKey = self.planUtilizationAccountKey(for: provider)
            return self.planUtilizationHistory[provider]?.samples(for: accountKey) ?? []
        }

        var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
        let originalProviderBuckets = providerBuckets
        let accountKey = self.resolveClaudePlanUtilizationAccountKey(
            snapshot: self.snapshots[provider],
            preferredAccount: nil,
            providerBuckets: &providerBuckets)
        self.planUtilizationHistory[provider] = providerBuckets
        if providerBuckets != originalProviderBuckets {
            let snapshotToPersist = self.planUtilizationHistory
            Task {
                await self.planUtilizationPersistenceCoordinator.enqueue(snapshotToPersist)
            }
        }
        return providerBuckets.samples(for: accountKey)
    }

    func recordPlanUtilizationHistorySample(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        account: ProviderTokenAccount? = nil,
        now: Date = Date())
        async
    {
        guard provider == .codex || provider == .claude else { return }
        guard !self.shouldDeferClaudePlanUtilizationHistory(provider: provider) else { return }

        var snapshotToPersist: [UsageProvider: PlanUtilizationHistoryBuckets]?
        await MainActor.run {
            // History mutation stays serialized on MainActor so overlapping refresh tasks cannot race each other
            // into duplicate writes for the same provider/account bucket.
            var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
            let preferredAccount = account ?? self.settings.selectedTokenAccount(for: provider)
            let accountKey =
                if provider == .claude {
                    self.resolveClaudePlanUtilizationAccountKey(
                        snapshot: snapshot,
                        preferredAccount: preferredAccount,
                        providerBuckets: &providerBuckets)
                } else {
                    Self.planUtilizationAccountKey(provider: provider, account: preferredAccount)
                        ?? Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
                }
            let history = providerBuckets.samples(for: accountKey)
            let sample = PlanUtilizationHistorySample(
                capturedAt: now,
                primaryUsedPercent: Self.clampedPercent(snapshot.primary?.usedPercent),
                primaryWindowMinutes: snapshot.primary?.windowMinutes,
                primaryResetsAt: snapshot.primary?.resetsAt,
                secondaryUsedPercent: Self.clampedPercent(snapshot.secondary?.usedPercent),
                secondaryWindowMinutes: snapshot.secondary?.windowMinutes,
                secondaryResetsAt: snapshot.secondary?.resetsAt)

            guard let updatedHistory = Self.updatedPlanUtilizationHistory(
                provider: provider,
                existingHistory: history,
                sample: sample)
            else {
                return
            }

            providerBuckets.setSamples(updatedHistory, for: accountKey)
            self.planUtilizationHistory[provider] = providerBuckets
            snapshotToPersist = self.planUtilizationHistory
        }

        guard let snapshotToPersist else { return }
        await self.planUtilizationPersistenceCoordinator.enqueue(snapshotToPersist)
    }

    private nonisolated static func updatedPlanUtilizationHistory(
        provider: UsageProvider,
        existingHistory: [PlanUtilizationHistorySample],
        sample: PlanUtilizationHistorySample) -> [PlanUtilizationHistorySample]?
    {
        var history = existingHistory
        let sampleHourBucket = self.planUtilizationHourBucket(for: sample.capturedAt)

        if let matchingIndex = history.lastIndex(where: {
            self.planUtilizationHourBucket(for: $0.capturedAt) == sampleHourBucket
        }) {
            let merged = self.mergedPlanUtilizationHistorySample(
                existing: history[matchingIndex],
                incoming: sample)
            if merged == history[matchingIndex] {
                return nil
            }
            history[matchingIndex] = merged
            return history
        }

        if let insertionIndex = history.firstIndex(where: { $0.capturedAt > sample.capturedAt }) {
            history.insert(sample, at: insertionIndex)
        } else {
            history.append(sample)
        }

        if history.count > self.planUtilizationMaxSamples {
            history.removeFirst(history.count - self.planUtilizationMaxSamples)
        }
        return history
    }

    #if DEBUG
    nonisolated static func _updatedPlanUtilizationHistoryForTesting(
        provider: UsageProvider,
        existingHistory: [PlanUtilizationHistorySample],
        sample: PlanUtilizationHistorySample) -> [PlanUtilizationHistorySample]?
    {
        self.updatedPlanUtilizationHistory(
            provider: provider,
            existingHistory: existingHistory,
            sample: sample)
    }

    nonisolated static var _planUtilizationMaxSamplesForTesting: Int {
        self.planUtilizationMaxSamples
    }

    #endif

    private nonisolated static func clampedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(0, min(100, value))
    }

    private nonisolated static func planUtilizationHourBucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / self.planUtilizationMinSampleIntervalSeconds))
    }

    private nonisolated static func mergedPlanUtilizationHistorySample(
        existing: PlanUtilizationHistorySample,
        incoming: PlanUtilizationHistorySample) -> PlanUtilizationHistorySample
    {
        let preferIncoming = incoming.capturedAt >= existing.capturedAt
        let capturedAt = preferIncoming ? incoming.capturedAt : existing.capturedAt

        return PlanUtilizationHistorySample(
            capturedAt: capturedAt,
            primaryUsedPercent: self.mergedPlanUtilizationValue(
                existing: existing.primaryUsedPercent,
                incoming: incoming.primaryUsedPercent,
                preferIncoming: preferIncoming),
            primaryWindowMinutes: self.mergedPlanUtilizationValue(
                existing: existing.primaryWindowMinutes,
                incoming: incoming.primaryWindowMinutes,
                preferIncoming: preferIncoming),
            primaryResetsAt: self.mergedPlanUtilizationValue(
                existing: existing.primaryResetsAt,
                incoming: incoming.primaryResetsAt,
                preferIncoming: preferIncoming),
            secondaryUsedPercent: self.mergedPlanUtilizationValue(
                existing: existing.secondaryUsedPercent,
                incoming: incoming.secondaryUsedPercent,
                preferIncoming: preferIncoming),
            secondaryWindowMinutes: self.mergedPlanUtilizationValue(
                existing: existing.secondaryWindowMinutes,
                incoming: incoming.secondaryWindowMinutes,
                preferIncoming: preferIncoming),
            secondaryResetsAt: self.mergedPlanUtilizationValue(
                existing: existing.secondaryResetsAt,
                incoming: incoming.secondaryResetsAt,
                preferIncoming: preferIncoming))
    }

    private nonisolated static func mergedPlanUtilizationValue<T>(
        existing: T?,
        incoming: T?,
        preferIncoming: Bool) -> T?
    {
        if preferIncoming {
            incoming ?? existing
        } else {
            existing ?? incoming
        }
    }

    private func planUtilizationAccountKey(for provider: UsageProvider) -> String? {
        self.planUtilizationAccountKey(for: provider, snapshot: nil, preferredAccount: nil)
    }

    private func planUtilizationAccountKey(
        for provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        preferredAccount: ProviderTokenAccount? = nil) -> String?
    {
        let account = preferredAccount ?? self.settings.selectedTokenAccount(for: provider)
        let accountKey = Self.planUtilizationAccountKey(provider: provider, account: account)
        if let accountKey {
            return accountKey
        }
        let resolvedSnapshot = snapshot ?? self.snapshots[provider]
        return resolvedSnapshot.flatMap { Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: $0) }
    }

    private nonisolated static func planUtilizationAccountKey(
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> String?
    {
        guard let account else { return nil }
        return self.sha256Hex("\(provider.rawValue):token-account:\(account.id.uuidString.lowercased())")
    }

    private nonisolated static func planUtilizationIdentityAccountKey(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> String?
    {
        guard let identity = snapshot.identity(for: provider) else { return nil }

        let normalizedEmail = identity.accountEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedEmail, !normalizedEmail.isEmpty {
            return self.sha256Hex("\(provider.rawValue):email:\(normalizedEmail)")
        }

        if provider == .claude {
            return nil
        }

        let normalizedOrganization = identity.accountOrganization?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedOrganization, !normalizedOrganization.isEmpty {
            return self.sha256Hex("\(provider.rawValue):organization:\(normalizedOrganization)")
        }

        return nil
    }

    private nonisolated static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func shouldDeferClaudePlanUtilizationHistory(provider: UsageProvider) -> Bool {
        provider == .claude && self.shouldShowPlanUtilizationRefreshingState(for: .claude)
    }

    func shouldShowPlanUtilizationRefreshingState(for provider: UsageProvider) -> Bool {
        guard self.refreshingProviders.contains(provider) else { return false }

        if provider != .claude {
            return true
        }

        return self.snapshots[.claude] == nil && self.error(for: .claude) == nil
    }

    private func resolveClaudePlanUtilizationAccountKey(
        snapshot: UsageSnapshot?,
        preferredAccount: ProviderTokenAccount?,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String?
    {
        let resolvedAccount = preferredAccount ?? self.settings.selectedTokenAccount(for: .claude)
        if let tokenAccountKey = Self.planUtilizationAccountKey(provider: .claude, account: resolvedAccount) {
            providerBuckets.preferredAccountKey = tokenAccountKey
            self.adoptClaudeBootstrapHistoryIfNeeded(into: tokenAccountKey, providerBuckets: &providerBuckets)
            return tokenAccountKey
        }

        if let snapshot,
           let identityAccountKey = Self.planUtilizationIdentityAccountKey(provider: .claude, snapshot: snapshot)
        {
            providerBuckets.preferredAccountKey = identityAccountKey
            self.adoptClaudeBootstrapHistoryIfNeeded(into: identityAccountKey, providerBuckets: &providerBuckets)
            return identityAccountKey
        }

        if let stickyAccountKey = self.stickyClaudePlanUtilizationAccountKey(providerBuckets: providerBuckets) {
            return stickyAccountKey
        }

        let hasKnownAccounts = self.hasKnownClaudePlanUtilizationAccounts(providerBuckets: providerBuckets)
        if hasKnownAccounts {
            return nil
        }

        return Self.claudeBootstrapAnonymousAccountKey
    }

    private func adoptClaudeBootstrapHistoryIfNeeded(
        into accountKey: String,
        providerBuckets: inout PlanUtilizationHistoryBuckets)
    {
        guard accountKey != Self.claudeBootstrapAnonymousAccountKey else { return }
        let anonymousHistory = providerBuckets.accounts[Self.claudeBootstrapAnonymousAccountKey] ?? []
        guard !anonymousHistory.isEmpty else { return }

        let existingHistory = providerBuckets.accounts[accountKey] ?? []
        let mergedHistory = Self.mergedPlanUtilizationHistories(provider: .claude, histories: [
            existingHistory,
            anonymousHistory,
        ])
        providerBuckets.setSamples(mergedHistory, for: accountKey)
        providerBuckets.setSamples([], for: Self.claudeBootstrapAnonymousAccountKey)
    }

    private func stickyClaudePlanUtilizationAccountKey(
        providerBuckets: PlanUtilizationHistoryBuckets) -> String?
    {
        let knownAccountKeys = self.knownClaudePlanUtilizationAccountKeys(providerBuckets: providerBuckets)
        guard !knownAccountKeys.isEmpty else { return nil }

        if let preferredAccountKey = providerBuckets.preferredAccountKey,
           knownAccountKeys.contains(preferredAccountKey)
        {
            return preferredAccountKey
        }

        if knownAccountKeys.count == 1 {
            return knownAccountKeys[0]
        }

        return knownAccountKeys.max { lhs, rhs in
            let lhsDate = providerBuckets.accounts[lhs]?.last?.capturedAt ?? .distantPast
            let rhsDate = providerBuckets.accounts[rhs]?.last?.capturedAt ?? .distantPast
            if lhsDate == rhsDate {
                return lhs > rhs
            }
            return lhsDate < rhsDate
        }
    }

    private func hasKnownClaudePlanUtilizationAccounts(providerBuckets: PlanUtilizationHistoryBuckets) -> Bool {
        !self.knownClaudePlanUtilizationAccountKeys(providerBuckets: providerBuckets).isEmpty
    }

    private func knownClaudePlanUtilizationAccountKeys(providerBuckets: PlanUtilizationHistoryBuckets) -> [String] {
        providerBuckets.accounts.keys
            .filter { $0 != Self.claudeBootstrapAnonymousAccountKey }
            .sorted()
    }

    private nonisolated static func mergedPlanUtilizationHistories(
        provider: UsageProvider,
        histories: [[PlanUtilizationHistorySample]]) -> [PlanUtilizationHistorySample]
    {
        let orderedSamples = histories
            .flatMap(\.self)
            .sorted { lhs, rhs in
                if lhs.capturedAt == rhs.capturedAt {
                    return (lhs.primaryUsedPercent ?? -1) < (rhs.primaryUsedPercent ?? -1)
                }
                return lhs.capturedAt < rhs.capturedAt
            }

        var mergedHistory: [PlanUtilizationHistorySample] = []
        for sample in orderedSamples {
            if let updated = self.updatedPlanUtilizationHistory(
                provider: provider,
                existingHistory: mergedHistory,
                sample: sample)
            {
                mergedHistory = updated
            }
        }
        return mergedHistory
    }

    #if DEBUG
    nonisolated static func _planUtilizationAccountKeyForTesting(
        provider: UsageProvider,
        snapshot: UsageSnapshot) -> String?
    {
        self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
    }

    nonisolated static func _planUtilizationTokenAccountKeyForTesting(
        provider: UsageProvider,
        account: ProviderTokenAccount) -> String?
    {
        self.planUtilizationAccountKey(provider: provider, account: account)
    }

    nonisolated static var _claudeBootstrapAnonymousAccountKeyForTesting: String {
        self.claudeBootstrapAnonymousAccountKey
    }
    #endif
}

actor PlanUtilizationHistoryPersistenceCoordinator {
    private let store: PlanUtilizationHistoryStore
    private var pendingSnapshot: [UsageProvider: PlanUtilizationHistoryBuckets]?
    private var isPersisting: Bool = false

    init(store: PlanUtilizationHistoryStore) {
        self.store = store
    }

    func enqueue(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) {
        self.pendingSnapshot = snapshot
        guard !self.isPersisting else { return }
        self.isPersisting = true

        Task(priority: .utility) {
            await self.persistLoop()
        }
    }

    private func persistLoop() async {
        while let nextSnapshot = self.pendingSnapshot {
            self.pendingSnapshot = nil
            await self.saveAsync(nextSnapshot)
        }

        self.isPersisting = false
    }

    private func saveAsync(_ snapshot: [UsageProvider: PlanUtilizationHistoryBuckets]) async {
        let store = self.store
        await Task.detached(priority: .utility) {
            store.save(snapshot)
        }.value
    }
}
