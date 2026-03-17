import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    private nonisolated static let planUtilizationMinSampleIntervalSeconds: TimeInterval = 60 * 60
    private nonisolated static let planUtilizationMaxSamples: Int = 24 * 730

    func planUtilizationHistory(for provider: UsageProvider) -> [PlanUtilizationHistorySample] {
        let accountKey = self.planUtilizationAccountKey(for: provider)
        if provider == .claude, accountKey == nil { return [] }
        return self.planUtilizationHistory[provider]?.samples(for: accountKey) ?? []
    }

    func recordPlanUtilizationHistorySample(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        account: ProviderTokenAccount? = nil,
        now: Date = Date())
        async
    {
        guard provider == .codex || provider == .claude else { return }

        var snapshotToPersist: [UsageProvider: PlanUtilizationHistoryBuckets]?
        await MainActor.run {
            // History mutation stays serialized on MainActor so overlapping refresh tasks cannot race each other
            // into duplicate writes for the same provider/account bucket.
            var providerBuckets = self.planUtilizationHistory[provider] ?? PlanUtilizationHistoryBuckets()
            let preferredAccount = account ?? self.settings.selectedTokenAccount(for: provider)
            let accountKey = Self.planUtilizationAccountKey(provider: provider, account: preferredAccount)
                ?? Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: snapshot)
            if provider == .claude, accountKey == nil {
                return
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
