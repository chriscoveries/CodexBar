import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationDerivedChartTests {
    @MainActor
    @Test
    func dailyModelDerivesFromResetBoundariesInsteadOfSyntheticEpochBuckets() throws {
        let calendar = Calendar(identifier: .gregorian)
        let boundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 1,
            minute: 30)))
        let samples = [
            makeDerivedChartPlanSample(
                at: boundary.addingTimeInterval(-80 * 60),
                primary: 20,
                primaryWindowMinutes: 300,
                primaryResetsAt: boundary),
            makeDerivedChartPlanSample(
                at: boundary.addingTimeInterval(-10 * 60),
                primary: 40,
                primaryWindowMinutes: 300,
                primaryResetsAt: boundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "daily",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 1)
        #expect(model.selectedSource == "primary:300")
        #expect(model.usedPercents == [40])
    }

    @MainActor
    @Test
    func dailyModelWeightsEarlyResetPeriodsByActualDuration() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 2,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 5,
            minute: 0)))
        let samples = [
            makeDerivedChartPlanSample(
                at: firstBoundary.addingTimeInterval(-90 * 60),
                primary: 30,
                primaryWindowMinutes: 300,
                primaryResetsAt: firstBoundary),
            makeDerivedChartPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                primary: 90,
                primaryWindowMinutes: 300,
                primaryResetsAt: secondBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "daily",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 1)
        #expect(model.selectedSource == "primary:300")
        #expect(model.usedPercents.count == 1)
        #expect(abs(model.usedPercents[0] - 52.5) < 0.000_1)
    }
}

private func makeDerivedChartPlanSample(
    at capturedAt: Date,
    primary: Double?,
    primaryWindowMinutes: Int? = nil,
    primaryResetsAt: Date? = nil) -> PlanUtilizationHistorySample
{
    PlanUtilizationHistorySample(
        capturedAt: capturedAt,
        primaryUsedPercent: primary,
        primaryWindowMinutes: primaryWindowMinutes,
        primaryResetsAt: primaryResetsAt,
        secondaryUsedPercent: nil,
        secondaryWindowMinutes: nil,
        secondaryResetsAt: nil)
}
