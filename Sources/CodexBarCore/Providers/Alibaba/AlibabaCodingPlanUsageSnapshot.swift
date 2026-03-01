import Foundation

public struct AlibabaCodingPlanUsageSnapshot: Sendable {
    public let planName: String?
    public let fiveHourUsedQuota: Int?
    public let fiveHourTotalQuota: Int?
    public let fiveHourNextRefreshTime: Date?
    public let weeklyUsedQuota: Int?
    public let weeklyTotalQuota: Int?
    public let weeklyNextRefreshTime: Date?
    public let monthlyUsedQuota: Int?
    public let monthlyTotalQuota: Int?
    public let monthlyNextRefreshTime: Date?
    public let updatedAt: Date

    public init(
        planName: String?,
        fiveHourUsedQuota: Int?,
        fiveHourTotalQuota: Int?,
        fiveHourNextRefreshTime: Date?,
        weeklyUsedQuota: Int?,
        weeklyTotalQuota: Int?,
        weeklyNextRefreshTime: Date?,
        monthlyUsedQuota: Int?,
        monthlyTotalQuota: Int?,
        monthlyNextRefreshTime: Date?,
        updatedAt: Date)
    {
        self.planName = planName
        self.fiveHourUsedQuota = fiveHourUsedQuota
        self.fiveHourTotalQuota = fiveHourTotalQuota
        self.fiveHourNextRefreshTime = fiveHourNextRefreshTime
        self.weeklyUsedQuota = weeklyUsedQuota
        self.weeklyTotalQuota = weeklyTotalQuota
        self.weeklyNextRefreshTime = weeklyNextRefreshTime
        self.monthlyUsedQuota = monthlyUsedQuota
        self.monthlyTotalQuota = monthlyTotalQuota
        self.monthlyNextRefreshTime = monthlyNextRefreshTime
        self.updatedAt = updatedAt
    }
}

extension AlibabaCodingPlanUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let primaryPercent = Self.usedPercent(used: self.fiveHourUsedQuota, total: self.fiveHourTotalQuota)
        let secondaryPercent = Self.usedPercent(used: self.weeklyUsedQuota, total: self.weeklyTotalQuota)
        let tertiaryPercent = Self.usedPercent(used: self.monthlyUsedQuota, total: self.monthlyTotalQuota)

        let primary: RateWindow? = if let primaryPercent {
            RateWindow(
                usedPercent: primaryPercent,
                windowMinutes: 5 * 60,
                resetsAt: Self.normalizedResetDate(
                    self.fiveHourNextRefreshTime,
                    updatedAt: self.updatedAt,
                    minimumLeadSeconds: 5 * 60),
                resetDescription: Self.limitDescription(total: self.fiveHourTotalQuota, label: "5-hour"))
        } else {
            nil
        }

        let secondary: RateWindow? = if let secondaryPercent {
            RateWindow(
                usedPercent: secondaryPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: self.weeklyNextRefreshTime,
                resetDescription: Self.limitDescription(total: self.weeklyTotalQuota, label: "weekly"))
        } else {
            nil
        }

        let tertiary: RateWindow? = if let tertiaryPercent {
            RateWindow(
                usedPercent: tertiaryPercent,
                windowMinutes: 30 * 24 * 60,
                resetsAt: self.monthlyNextRefreshTime,
                resetDescription: Self.limitDescription(total: self.monthlyTotalQuota, label: "monthly"))
        } else {
            nil
        }

        let loginMethod = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = ProviderIdentitySnapshot(
            providerID: .alibaba,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func usedPercent(used: Int?, total: Int?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        let normalizedUsed = max(0, min(used, total))
        return Double(normalizedUsed) / Double(total) * 100
    }

    private static func limitDescription(total: Int?, label: String) -> String? {
        guard let total, total > 0 else { return nil }
        return "\(total) requests / \(label)"
    }

    private static func normalizedResetDate(
        _ date: Date?,
        updatedAt: Date,
        minimumLeadSeconds: TimeInterval) -> Date?
    {
        guard let date else { return nil }
        return date.timeIntervalSince(updatedAt) >= minimumLeadSeconds ? date : nil
    }
}
