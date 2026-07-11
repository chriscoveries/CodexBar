import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct Sub2APIMenuCardModelTests {
    @Test
    func `subscription amounts share the percentage row`() throws {
        let now = Date(timeIntervalSince1970: 1_720_440_000)
        let json = """
        {
          "mode": "unrestricted",
          "subscription": {
            "daily_usage_usd": 12,
            "weekly_usage_usd": 70,
            "monthly_usage_usd": 280,
            "daily_limit_usd": 120,
            "weekly_limit_usd": 700,
            "monthly_limit_usd": 2800
          }
        }
        """
        let snapshot = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.sub2api])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .sub2api,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        let secondary = try #require(model.metrics.first { $0.id == "secondary" })
        let tertiary = try #require(model.metrics.first { $0.id == "tertiary" })

        #expect(primary.resetText == "$12.00 / $120.00")
        #expect(primary.detailText == nil)
        #expect(secondary.resetText == "$70.00 / $700.00")
        #expect(secondary.detailText == nil)
        #expect(tertiary.resetText == "$280.00 / $2,800.00")
        #expect(tertiary.detailText == nil)
    }

    @Test
    func `extra window amount renders as detail instead of reset`() throws {
        let now = Date(timeIntervalSince1970: 1_720_440_000)
        let json = """
        {
          "mode": "quota_limited",
          "rate_limits": [
            {
              "window": "7d",
              "limit": 200,
              "used": 40,
              "remaining": 160
            }
          ]
        }
        """
        let snapshot = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.sub2api])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .sub2api,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let weekly = try #require(model.metrics.first { $0.id == "7d" })
        #expect(weekly.resetText == nil)
        #expect(weekly.detailText == "$40.00 / $200.00")
    }
}
