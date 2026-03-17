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
            hour: 5,
            minute: 0)))
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
        #expect(model.usedPercents.count == 1)
        #expect(abs(model.usedPercents[0] - (40.0 * 5.0 / 24.0)) < 0.000_1)
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
            hour: 10,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 13,
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
        #expect(abs(model.usedPercents[0] - 17.5) < 0.000_1)
    }

    @MainActor
    @Test
    func weeklyModelNormalizesFiveHourHistoryAgainstFullWeekDuration() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 9,
            hour: 5,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 9,
            hour: 10,
            minute: 0)))
        let samples = [
            makeDerivedChartPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                primary: 20,
                primaryWindowMinutes: 300,
                primaryResetsAt: firstBoundary),
            makeDerivedChartPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                primary: 40,
                primaryWindowMinutes: 300,
                primaryResetsAt: secondBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        let expected = (20.0 * 5.0 + 40.0 * 5.0) / (7.0 * 24.0)
        #expect(model.pointCount == 1)
        #expect(model.selectedSource == "primary:300")
        #expect(model.usedPercents.count == 1)
        #expect(abs(model.usedPercents[0] - expected) < 0.000_1)
    }

    @MainActor
    @Test
    func monthlyModelNormalizesWeeklyHistoryAgainstFullMonthDuration() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 0,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 0,
            minute: 0)))
        let samples = [
            makeDerivedChartPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                primary: 75,
                primaryWindowMinutes: 10080,
                primaryResetsAt: firstBoundary),
            makeDerivedChartPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                primary: 75,
                primaryWindowMinutes: 10080,
                primaryResetsAt: secondBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "monthly",
                samples: samples,
                provider: .codex))

        let expected = 75.0 * 14.0 / 31.0
        #expect(model.pointCount == 1)
        #expect(model.selectedSource == "primary:10080")
        #expect(model.usedPercents.count == 1)
        #expect(abs(model.usedPercents[0] - expected) < 0.000_1)
    }

    @MainActor
    @Test
    func dailyModelNormalizesFiveHourHistoryAgainstFullDayDuration() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 5,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 10,
            minute: 0)))
        let samples = [
            makeDerivedChartPlanSample(
                at: firstBoundary.addingTimeInterval(-60 * 60),
                primary: 20,
                primaryWindowMinutes: 300,
                primaryResetsAt: firstBoundary),
            makeDerivedChartPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                primary: 10,
                primaryWindowMinutes: 300,
                primaryResetsAt: firstBoundary),
            makeDerivedChartPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                primary: 40,
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
        #expect(abs(model.usedPercents[0] - 12.5) < 0.000_1)
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
