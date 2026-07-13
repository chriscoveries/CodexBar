import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsTests {
    @Test
    func `builder differentiates subscriptions and sums only known totals`() throws {
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Codex",
                    subscriptionName: "Plus",
                    tokenSnapshot: Self.codexSnapshot,
                    usageSnapshot: Self.usage(usedPercent: 64)),
                ShareStatsProviderSource(
                    providerName: "Claude",
                    subscriptionName: "Max",
                    tokenSnapshot: Self.claudeSnapshot,
                    usageSnapshot: Self.usage(usedPercent: 38)),
                ShareStatsProviderSource(
                    providerName: "Cursor",
                    subscriptionName: "Pro",
                    tokenSnapshot: nil,
                    usageSnapshot: Self.usage(usedPercent: 82)),
                ShareStatsProviderSource(
                    providerName: "OpenCode",
                    subscriptionName: nil,
                    tokenSnapshot: nil,
                    usageSnapshot: nil),
            ],
            calendar: Self.calendar))

        #expect(payload.days == 30)
        #expect(payload.totalTokens == 5_500_000_000)
        #expect(payload.estimatedCostUSD == 4250)
        #expect(payload.providers.map(\.providerName) == ["Codex", "Claude", "Cursor", "OpenCode"])
        #expect(payload.providers.map(\.subscriptionName) == ["Plus", "Max", "Pro", nil])
        #expect(payload.providers[3].totalTokens == nil)
        #expect(payload.providers[0].dailyTokens.reduce(0, +) == 4_768_000_000)
        #expect(payload.tokenProviderCount == 2)
        #expect(payload.pricedProviderCount == 2)
        #expect(payload.topModels.map(\.modelName) == ["gpt-5.5", "claude-sonnet-5"])
    }

    @Test
    func `text formatter preserves provider differentiation and provenance`() throws {
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Codex",
                    subscriptionName: "Plus",
                    tokenSnapshot: Self.codexSnapshot,
                    usageSnapshot: nil),
                ShareStatsProviderSource(
                    providerName: "Cursor",
                    subscriptionName: "Pro",
                    tokenSnapshot: nil,
                    usageSnapshot: Self.usage(usedPercent: 82)),
            ],
            calendar: Self.calendar))
        let text = ShareStatsFormatting.text(payload)

        #expect(text.contains("Codex · Plus: 4.77B tokens"))
        #expect(text.contains("Cursor · Pro: connected"))
        #expect(text.contains("estimated across priced providers"))
        #expect(text.contains("gpt-5.5 (Codex)"))
        #expect(text.contains("Generated locally by CodexBar"))
        #expect(!text.contains("secret-project"))
    }

    @Test
    func `multiple Codex subscriptions stay distinct and all contribute to totals`() throws {
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Codex · #1",
                    subscriptionName: "Plus",
                    tokenSnapshot: Self.codexSnapshot,
                    usageSnapshot: Self.usage(usedPercent: 64)),
                ShareStatsProviderSource(
                    providerName: "Codex · #2",
                    subscriptionName: "Team",
                    tokenSnapshot: Self.claudeSnapshot,
                    usageSnapshot: Self.usage(usedPercent: 38)),
            ],
            calendar: Self.calendar))

        #expect(payload.providers.map(\.providerName) == ["Codex · #1", "Codex · #2"])
        #expect(payload.totalTokens == 5_500_000_000)
        #expect(payload.estimatedCostUSD == 4250)
        #expect(payload.pricedProviderCount == 2)
        #expect(payload.tokenProviderCount == 2)
    }

    @Test
    func `builder keeps model names when cost history has no model breakdown`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 42000,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [CostUsageDailyReport.Entry(
                date: "2026-07-07",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 42000,
                costUSD: nil,
                modelsUsed: ["gpt-5.5-codex", "gpt-5.5-codex"],
                modelBreakdowns: nil)],
            projects: [],
            updatedAt: Date(timeIntervalSince1970: 1_783_382_400))
        let payload = try #require(ShareStatsBuilder.make(
            providers: [ShareStatsProviderSource(
                providerName: "Codex",
                subscriptionName: "Plus",
                tokenSnapshot: snapshot,
                usageSnapshot: nil)],
            calendar: Self.calendar))

        #expect(payload.topModels == [ShareStatsModelPayload(
            providerName: "Codex",
            modelName: "gpt-5.5-codex",
            totalTokens: nil,
            estimatedCostUSD: nil)])
    }

    @MainActor
    @Test
    func `card uses standard social preview dimensions without invoking GPU rendering`() {
        #expect(ShareStatsCardView.size.width == 1200)
        #expect(ShareStatsCardView.size.height == 630)
    }

    private static let codexSnapshot = Self.snapshot(
        tokens: 4_768_000_000,
        cost: 3750,
        modelName: "gpt-5.5",
        projectName: "secret-project")
    private static let claudeSnapshot = Self.snapshot(
        tokens: 732_000_000,
        cost: 500,
        modelName: "claude-sonnet-5",
        projectName: "other-secret")

    private static func snapshot(
        tokens: Int,
        cost: Double,
        modelName: String,
        projectName: String) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            historyDays: 30,
            daily: [self.entry(day: "2026-07-07", tokens: tokens, cost: cost, modelName: modelName)],
            projects: [
                CostUsageProjectBreakdown(
                    name: projectName,
                    path: "/Users/example/\(projectName)",
                    totalTokens: 10,
                    totalCostUSD: 1,
                    daily: [],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_783_382_400))
    }

    private static func usage(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_783_382_400))
    }

    private static func entry(
        day: String,
        tokens: Int,
        cost: Double,
        modelName: String) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: [modelName],
            modelBreakdowns: [.init(modelName: modelName, costUSD: cost, totalTokens: tokens)])
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
