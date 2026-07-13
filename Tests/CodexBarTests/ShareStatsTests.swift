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

    @Test
    func `OpenRouter month spend stays visible and separate from trailing period total`() throws {
        let openRouterUsage = OpenRouterUsageSnapshot(
            totalCredits: 100,
            totalUsage: 40,
            balance: 60,
            usedPercent: 40,
            keyDataFetched: true,
            keyLimit: nil,
            keyUsage: nil,
            keyUsageDaily: 1.25,
            keyUsageWeekly: 7.50,
            keyUsageMonthly: 18.75,
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 1_783_382_400))
            .toUsageSnapshot()
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Codex",
                    subscriptionName: "Plus",
                    tokenSnapshot: Self.codexSnapshot,
                    usageSnapshot: nil),
                ShareStatsProviderSource(
                    providerName: "OpenRouter",
                    subscriptionName: nil,
                    tokenSnapshot: nil,
                    usageSnapshot: openRouterUsage,
                    reportedSpend: ShareStatsReportedSpend.from(
                        provider: .openrouter,
                        snapshot: openRouterUsage)),
            ],
            calendar: Self.calendar))

        #expect(payload.estimatedCostUSD == 3750)
        #expect(payload.monthToDateSpendUSD == 18.75)
        #expect(payload.providers[1].estimatedCostUSD == 18.75)
        #expect(payload.providers[1].spendWindow == .monthToDate)
        #expect(ShareStatsFormatting.text(payload).contains("OpenRouter: ~$18.75 MTD"))
    }

    @Test
    func `builder uses one shared calendar window across stale provider snapshots`() throws {
        let current = Self.snapshot(
            tokens: 100,
            cost: 1,
            modelName: "current-model",
            projectName: "current")
        let stale = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 900,
            last30DaysCostUSD: 9,
            historyDays: 30,
            daily: [Self.entry(
                day: "2026-06-01",
                tokens: 900,
                cost: 9,
                modelName: "stale-model")],
            updatedAt: Date(timeIntervalSince1970: 1_780_272_000))
        let payload = try #require(ShareStatsBuilder.make(
            providers: [
                ShareStatsProviderSource(
                    providerName: "Current",
                    subscriptionName: nil,
                    tokenSnapshot: current,
                    usageSnapshot: nil),
                ShareStatsProviderSource(
                    providerName: "Stale",
                    subscriptionName: nil,
                    tokenSnapshot: stale,
                    usageSnapshot: nil),
            ],
            days: 30,
            calendar: Self.calendar))

        #expect(payload.totalTokens == 100)
        #expect(payload.estimatedCostUSD == 1)
        #expect(payload.providers[1].totalTokens == nil)
        #expect(payload.topModels.map(\.modelName) == ["current-model"])
    }

    @Test
    func `subscription labels allow plan tiers but reject overloaded identity details`() {
        #expect(ShareStatsSubscriptionName.sanitized(provider: .codex, rawName: "pro") == "Pro 20x")
        #expect(ShareStatsSubscriptionName.sanitized(provider: .cursor, rawName: "Cursor Pro") == "Cursor Pro")
        #expect(ShareStatsSubscriptionName.sanitized(
            provider: .deepgram,
            rawName: "Project: secret-project") == nil)
        #expect(ShareStatsSubscriptionName.sanitized(
            provider: .azureopenai,
            rawName: "Deployment: private-deployment") == nil)
        #expect(ShareStatsSubscriptionName.sanitized(
            provider: .openrouter,
            rawName: "Balance: $49.58") == nil)
        #expect(ShareStatsSubscriptionName.sanitized(
            provider: .kilo,
            rawName: "Pro · Auto top-up: visa") == nil)
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
