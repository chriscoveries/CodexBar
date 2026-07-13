import CodexBarCore
import Foundation

struct ShareStatsProviderSource: Sendable {
    let providerName: String
    let tokenSnapshot: CostUsageTokenSnapshot?
    let usageSnapshot: UsageSnapshot?
}

struct ShareStatsProviderPayload: Sendable, Equatable, Identifiable {
    let providerName: String
    let totalTokens: Int?
    let estimatedCostUSD: Double?
    let activeDays: Int?
    let planUsedPercent: Double?

    var id: String {
        self.providerName
    }
}

struct ShareStatsPayload: Sendable, Equatable {
    let days: Int
    let periodEnd: Date
    let providers: [ShareStatsProviderPayload]
    let totalTokens: Int?
    let estimatedCostUSD: Double?
    let dailyTokens: [Int]

    var pricedProviderCount: Int {
        self.providers.count { $0.estimatedCostUSD != nil }
    }

    var tokenProviderCount: Int {
        self.providers.count { $0.totalTokens != nil }
    }

    var hasShareableData: Bool {
        !self.providers.isEmpty && self.providers.contains { provider in
            provider.totalTokens != nil || provider.estimatedCostUSD != nil || provider.planUsedPercent != nil
        }
    }
}

enum ShareStatsBuilder {
    static func make(
        providers sources: [ShareStatsProviderSource],
        days requestedDays: Int = 30,
        calendar: Calendar = .current) -> ShareStatsPayload?
    {
        let days = max(1, requestedDays)
        let periodEnd = sources.compactMap { source in
            source.tokenSnapshot?.updatedAt ?? source.usageSnapshot?.updatedAt
        }.max() ?? Date()
        var combinedDailyTokens = Array(repeating: 0, count: days)
        let providers = sources.map { source -> ShareStatsProviderPayload in
            let summary = source.tokenSnapshot?.summary(forLastDays: days, calendar: calendar)
            let dailyTokens = source.tokenSnapshot.map {
                self.dailyTokens(snapshot: $0, days: days, periodEnd: periodEnd, calendar: calendar)
            }
            if let dailyTokens {
                for index in combinedDailyTokens.indices {
                    combinedDailyTokens[index] += dailyTokens[index]
                }
            }
            let activeDays = dailyTokens.map { $0.count(where: { $0 > 0 }) }
            return ShareStatsProviderPayload(
                providerName: source.providerName,
                totalTokens: summary?.totalTokens,
                estimatedCostUSD: summary?.totalCostUSD,
                activeDays: activeDays,
                planUsedPercent: self.mostConstrainedUsage(source.usageSnapshot))
        }
        let tokenValues = providers.compactMap(\.totalTokens)
        let costValues = providers.compactMap(\.estimatedCostUSD).filter(\.isFinite)
        let payload = ShareStatsPayload(
            days: days,
            periodEnd: periodEnd,
            providers: providers,
            totalTokens: tokenValues.isEmpty ? nil : tokenValues.reduce(0, +),
            estimatedCostUSD: costValues.isEmpty ? nil : costValues.reduce(0, +),
            dailyTokens: combinedDailyTokens)
        return payload.hasShareableData ? payload : nil
    }

    private static func dailyTokens(
        snapshot: CostUsageTokenSnapshot,
        days: Int,
        periodEnd: Date,
        calendar: Calendar) -> [Int]
    {
        let end = calendar.startOfDay(for: periodEnd)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return (0..<days).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return 0 }
            let entry = CostUsageTokenSnapshot.entry(
                in: snapshot.daily,
                forLocalDayContaining: date,
                calendar: calendar)
            return max(0, entry?.totalTokens ?? 0)
        }
    }

    private static func mostConstrainedUsage(_ snapshot: UsageSnapshot?) -> Double? {
        let windows = [snapshot?.primary, snapshot?.secondary, snapshot?.tertiary]
            .compactMap(\.self)
            .filter { !$0.isSyntheticPlaceholder && $0.usedPercent.isFinite }
        return windows.map(\.usedPercent).max().map { min(max($0, 0), 100) }
    }
}

enum ShareStatsFormatting {
    static func compactCount(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        let divisor: Double
        let suffix: String
        switch magnitude {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1000...:
            divisor = 1000
            suffix = "K"
        default:
            return value.formatted(.number.grouping(.automatic))
        }
        let scaled = Double(value) / divisor
        let digits = magnitude >= divisor * 100 ? 0 : magnitude >= divisor * 10 ? 1 : 2
        return scaled.formatted(.number.precision(.fractionLength(0...digits))) + suffix
    }

    static func currencyUSD(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func dataThrough(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter.string(from: date)
    }

    static func text(_ payload: ShareStatsPayload) -> String {
        var lines = ["My AI subscriptions · last \(payload.days) days"]
        var totals: [String] = []
        if let tokens = payload.totalTokens {
            totals.append("\(self.compactCount(tokens)) tracked tokens")
        }
        if let cost = payload.estimatedCostUSD, cost.isFinite {
            totals.append("~\(self.currencyUSD(cost)) estimated across priced providers")
        }
        if !totals.isEmpty {
            lines.append(totals.joined(separator: " · "))
        }
        lines.append(contentsOf: payload.providers.map { provider in
            var metrics: [String] = []
            if let tokens = provider.totalTokens {
                metrics.append("\(self.compactCount(tokens)) tokens")
            }
            if let cost = provider.estimatedCostUSD, cost.isFinite {
                metrics.append("~\(self.currencyUSD(cost)) est")
            }
            if metrics.isEmpty, let percent = provider.planUsedPercent {
                metrics.append("\(Int(percent.rounded()))% plan used")
            }
            return "\(provider.providerName): \(metrics.isEmpty ? "connected" : metrics.joined(separator: " · "))"
        })
        lines.append("Generated locally by CodexBar · Data through \(self.dataThrough(payload.periodEnd))")
        return lines.joined(separator: "\n")
    }
}
