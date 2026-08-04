import Foundation

public struct PoeUsageSnapshot: Sendable {
    public let currentPointBalance: Double?
    public let history: PoeUsageHistorySnapshot?
    public let updatedAt: Date

    public init(
        currentPointBalance: Double? = nil,
        history: PoeUsageHistorySnapshot? = nil,
        updatedAt: Date = Date())
    {
        self.currentPointBalance = currentPointBalance
        self.history = history
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .poe,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.balanceLabel)

        var rows: [ProviderDetailSection.Row] = []
        if let balance = self.currentPointBalance {
            rows.append(.makeRow(label: "Current balance", value: "\(Self.compactNumber(balance)) points"))
        }
        if let history = self.history {
            let seven = history.last7Days
            let thirty = history.last30Days
            rows.append(.makeRow(
                label: "Last 7 days",
                value: "\(Self.compactNumber(seven.points)) points",
                secondaryValue: "\(seven.requests) requests"))
            rows.append(.makeRow(
                label: "Last 30 days",
                value: "\(Self.compactNumber(thirty.points)) points",
                secondaryValue: "\(thirty.requests) requests"))
            if let top = history.topModels.first {
                rows.append(.makeRow(
                    label: "Top model",
                    value: top.name,
                    secondaryValue: "\(Self.compactNumber(top.points)) points"))
            }
            if let top = history.topUsageTypes.first {
                rows.append(.makeRow(
                    label: "Top usage type",
                    value: top.name,
                    secondaryValue: "\(Self.compactNumber(top.points)) points"))
            }
        }
        let chart = self.history.flatMap { history in
            history.daily.isEmpty ? nil : ProviderDetailSection.makeChart(
                title: "Daily points",
                unit: "points",
                points: history.daily.map { ($0.day, $0.points) })
        }

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            details: [.makeSection(title: "Points", rows: rows, chart: chart)],
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private var balanceLabel: String? {
        guard let balance = self.currentPointBalance, balance.isFinite else { return nil }
        return "Balance: \(Self.compactNumber(balance)) points"
    }

    static func compactNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
