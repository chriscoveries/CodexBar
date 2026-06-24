import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CursorMenuCardModelTests {
    @Test
    func `provider cost distinguishes true zero from positive usage below one percent`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        func percentLine(used: Double) -> String? {
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: used,
                    limit: 100,
                    currencyCode: "USD",
                    updatedAt: now),
                updatedAt: now)
            return UsageMenuCardView.Model.make(.init(
                provider: .cursor,
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
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))
                .providerCost?.percentLine
        }

        #expect(percentLine(used: 0) == "0% used")
        #expect(percentLine(used: 0.49) == "<1% used")
    }

    @Test
    func `provider cost preserves localized percent placement`() {
        #expect(UsageMenuCardView.Model.localizedUsedPercentLine(0, format: "used %.0f%%") == "used 0%")
        #expect(UsageMenuCardView.Model.localizedUsedPercentLine(0.49, format: "used %.0f%%") == "used <1%")
        #expect(UsageMenuCardView.Model.localizedUsedPercentLine(50, format: "%%%.0f used") == "%50 used")
        #expect(UsageMenuCardView.Model.localizedUsedPercentLine(0.49, format: "%%%.0f used") == "%<1 used")
    }

    @Test
    func `team pool shows personal spend and changes height fingerprint`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        func makeModel(personalUsed: Double?) -> UsageMenuCardView.Model {
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 13111.25,
                    limit: 20000,
                    currencyCode: "USD",
                    period: "Monthly",
                    personalUsed: personalUsed,
                    updatedAt: now),
                updatedAt: now,
                identity: nil)
            return UsageMenuCardView.Model.make(.init(
                provider: .cursor,
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
        }

        let personal = makeModel(personalUsed: 44.71)
        let absent = makeModel(personalUsed: nil)
        let zero = makeModel(personalUsed: 0)

        #expect(personal.providerCost?.personalSpendLine == "Your spend: $44.71")
        #expect(absent.providerCost?.personalSpendLine == nil)
        #expect(zero.providerCost?.personalSpendLine == nil)
        #expect(personal.heightFingerprint(section: "card") != absent.heightFingerprint(section: "card"))
        #expect(!personal.hasCompatibleTrackedLayout(with: absent))
        #expect(!absent.hasCompatibleTrackedLayout(with: personal))
    }

    @Test
    func `cursor billing cycle metrics show deficit and run out details`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let cycleMinutes = 30 * 24 * 60
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
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

        #expect(model.metrics.map(\.title) == ["Total", "Auto", "API"])
        for metric in model.metrics {
            #expect(metric.percentLabel == "10% left")
            #expect(metric.detailLeftText == "10% in deficit")
            #expect(metric.detailRightText == "Runs out in 2d 16h")
            #expect(metric.pacePercent == 20)
            #expect(metric.paceOnTop == false)
        }
    }

    @Test
    func `legacy request plan shows single requests bar with count`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let cycleMinutes = 30 * 24 * 60
        // A legacy snapshot, as produced by CursorStatusSnapshot.toUsageSnapshot(): only the request
        // window survives, Auto/API are dropped, and the request count rides along.
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 69.4,
                windowMinutes: cycleMinutes,
                resetsAt: reset,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            cursorRequests: CursorRequestUsage(used: 347, limit: 500),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
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

        #expect(model.metrics.map(\.title) == ["Requests"])
        #expect(model.metrics.first?.detailText == "Request quota: 347 / 500")
    }
}
