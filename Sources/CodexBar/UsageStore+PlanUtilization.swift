import CodexBarCore
import Foundation

extension UsageStore {
    private nonisolated static let codexCreditsMonthlyCapTokens: Double = 1000
    private nonisolated static let persistenceCoordinator = PlanUtilizationHistoryPersistenceCoordinator()
    private nonisolated static let planUtilizationMinSampleIntervalSeconds: TimeInterval = 60 * 60

    func planUtilizationHistory(for provider: UsageProvider) -> [PlanUtilizationHistorySample] {
        self.planUtilizationHistory[provider] ?? []
    }

    func recordPlanUtilizationHistorySample(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot? = nil,
        now: Date = Date())
        async
    {
        guard provider == .codex || provider == .claude else { return }

        var snapshotToPersist: [UsageProvider: [PlanUtilizationHistorySample]]?
        await MainActor.run {
            var history = self.planUtilizationHistory[provider] ?? []
            let resolvedCredits = provider == .codex ? credits : nil
            let sample = PlanUtilizationHistorySample(
                capturedAt: now,
                dailyUsedPercent: Self.clampedPercent(snapshot.primary?.usedPercent),
                weeklyUsedPercent: Self.clampedPercent(snapshot.secondary?.usedPercent),
                monthlyUsedPercent: Self.planHistoryMonthlyUsedPercent(
                    provider: provider,
                    snapshot: snapshot,
                    credits: resolvedCredits))

            if let last = history.last,
               now.timeIntervalSince(last.capturedAt) < Self.planUtilizationMinSampleIntervalSeconds,
               Self.nearlyEqual(last.dailyUsedPercent, sample.dailyUsedPercent),
               Self.nearlyEqual(last.weeklyUsedPercent, sample.weeklyUsedPercent)
            {
                if Self.nearlyEqual(last.monthlyUsedPercent, sample.monthlyUsedPercent) {
                    return
                }

                if provider == .codex {
                    if last.monthlyUsedPercent != nil, sample.monthlyUsedPercent == nil {
                        return
                    }
                    if last.monthlyUsedPercent == nil, sample.monthlyUsedPercent != nil {
                        history[history.index(before: history.endIndex)] = sample
                        self.planUtilizationHistory[provider] = history
                        snapshotToPersist = self.planUtilizationHistory
                        return
                    }
                }
            }

            history.append(sample)

            // Keep at least ~13 months of hourly points per provider.
            let maxSamples = 24 * 400
            if history.count > maxSamples {
                history.removeFirst(history.count - maxSamples)
            }

            self.planUtilizationHistory[provider] = history
            snapshotToPersist = self.planUtilizationHistory
        }

        guard let snapshotToPersist else { return }
        await Self.persistenceCoordinator.enqueue(snapshotToPersist)
    }

    nonisolated static func planHistoryMonthlyUsedPercent(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot?) -> Double?
    {
        if provider == .codex,
           let providerCostPercent = self.monthlyUsedPercent(from: snapshot.providerCost)
        {
            return providerCostPercent
        }
        guard provider == .codex else { return nil }
        guard self.codexSupportsCreditBasedMonthly(snapshot: snapshot) else { return nil }
        return self.codexMonthlyUsedPercent(from: credits)
    }

    private nonisolated static func monthlyUsedPercent(from providerCost: ProviderCostSnapshot?) -> Double? {
        guard let providerCost, providerCost.limit > 0 else { return nil }
        let usedPercent = (providerCost.used / providerCost.limit) * 100
        return self.clampedPercent(usedPercent)
    }

    private nonisolated static func codexMonthlyUsedPercent(from credits: CreditsSnapshot?) -> Double? {
        guard let remaining = credits?.remaining, remaining.isFinite else { return nil }
        let cap = self.codexCreditsMonthlyCapTokens
        guard cap > 0 else { return nil }
        let used = max(0, min(cap, cap - remaining))
        let usedPercent = (used / cap) * 100
        return self.clampedPercent(usedPercent)
    }

    private nonisolated static func codexSupportsCreditBasedMonthly(snapshot: UsageSnapshot) -> Bool {
        let rawPlan = snapshot.loginMethod(for: .codex)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !rawPlan.isEmpty else { return false }
        return rawPlan == "guest" || rawPlan == "free" || rawPlan == "free_workspace"
    }

    private nonisolated static func clampedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(0, min(100, value))
    }

    private nonisolated static func nearlyEqual(_ lhs: Double?, _ rhs: Double?, tolerance: Double = 0.1) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (l?, r?):
            abs(l - r) <= tolerance
        default:
            false
        }
    }
}

private actor PlanUtilizationHistoryPersistenceCoordinator {
    private var pendingSnapshot: [UsageProvider: [PlanUtilizationHistorySample]]?
    private var isPersisting: Bool = false

    func enqueue(_ snapshot: [UsageProvider: [PlanUtilizationHistorySample]]) {
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
            await Self.saveAsync(nextSnapshot)
        }

        self.isPersisting = false
    }

    private nonisolated static func saveAsync(_ snapshot: [UsageProvider: [PlanUtilizationHistorySample]]) async {
        await Task.detached(priority: .utility) {
            PlanUtilizationHistoryStore.save(snapshot)
        }.value
    }
}
