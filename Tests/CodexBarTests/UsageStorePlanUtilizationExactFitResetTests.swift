import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationExactFitResetTests {
    @MainActor
    @Test
    func weeklyExactFitUsesResetDateAsBarDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 5,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 5,
            minute: 0)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 22,
            hour: 5,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                secondary: 48,
                secondaryResetsAt: secondBoundary),
            makeExactFitResetPlanSample(
                at: thirdBoundary.addingTimeInterval(-30 * 60),
                secondary: 20,
                secondaryResetsAt: thirdBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 3)
        #expect(model.selectedSource == "secondary:10080")
        #expect(model.usedPercents == [62, 48, 20])
        #expect(model.pointDates == ["2026-03-08 05:00", "2026-03-15 05:00", "2026-03-22 05:00"])
    }

    @MainActor
    @Test
    func weeklyExactFitCoalescesSameDayResetShiftIntoSingleBar() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 5,
            minute: 0)))
        let originalSecondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 5,
            minute: 0)))
        let shiftedSecondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 7,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: originalSecondBoundary.addingTimeInterval(-30 * 60),
                secondary: 48,
                secondaryResetsAt: originalSecondBoundary),
            makeExactFitResetPlanSample(
                at: shiftedSecondBoundary.addingTimeInterval(-10 * 60),
                secondary: 12,
                secondaryResetsAt: shiftedSecondBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 2)
        #expect(model.usedPercents == [62, 12])
        #expect(model.pointDates == ["2026-03-08 05:00", "2026-03-15 07:00"])
    }

    @MainActor
    @Test
    func weeklyExactFitCreatesNewBarWhenEarlyResetMovesToDifferentDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 5,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 5,
            minute: 0)))
        let earlyResetBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 16,
            hour: 2,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                secondary: 48,
                secondaryResetsAt: secondBoundary),
            makeExactFitResetPlanSample(
                at: earlyResetBoundary.addingTimeInterval(-10 * 60),
                secondary: 12,
                secondaryResetsAt: earlyResetBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 3)
        #expect(model.usedPercents == [62, 48, 12])
        #expect(model.pointDates == ["2026-03-08 05:00", "2026-03-15 05:00", "2026-03-16 02:00"])
    }

    @MainActor
    @Test
    func weeklyExactFitShowsZeroBarsForMissingResetPeriods() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 5,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 5,
            minute: 0)))
        let fourthBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 29,
            hour: 5,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                secondary: 48,
                secondaryResetsAt: secondBoundary),
            makeExactFitResetPlanSample(
                at: fourthBoundary.addingTimeInterval(-30 * 60),
                secondary: 20,
                secondaryResetsAt: fourthBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 4)
        #expect(model.usedPercents == [62, 48, 0, 20])
        #expect(model.pointDates == [
            "2026-03-08 05:00",
            "2026-03-15 05:00",
            "2026-03-22 05:00",
            "2026-03-29 05:00",
        ])
    }

    @MainActor
    @Test
    func weeklyExactFitInfersMissingResetFromObservedCadence() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 5,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 22,
            hour: 5,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 48,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: secondBoundary.addingTimeInterval(-(3 * 24 * 60 * 60)),
                secondary: 52,
                secondaryResetsAt: nil),
            makeExactFitResetPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: secondBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 2)
        #expect(model.usedPercents == [48, 62])
        #expect(model.pointDates == ["2026-03-15 05:00", "2026-03-22 05:00"])
    }

    @MainActor
    @Test
    func weeklyExactFitKeepsShiftedAnchorWhenLaterSampleMissesReset() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 5,
            minute: 0)))
        let shiftedBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 7,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: shiftedBoundary.addingTimeInterval(-10 * 60),
                secondary: 48,
                secondaryResetsAt: shiftedBoundary),
            makeExactFitResetPlanSample(
                at: shiftedBoundary.addingTimeInterval(-5 * 60),
                secondary: 12,
                secondaryResetsAt: nil),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 2)
        #expect(model.usedPercents == [62, 12])
        #expect(model.pointDates == ["2026-03-08 05:00", "2026-03-15 07:00"])
    }

    @MainActor
    @Test
    func weeklyExactFitPrefersRealNextResetOverTemporaryShiftCadence() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 5,
            minute: 0)))
        let shiftedBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 16,
            hour: 2,
            minute: 0)))
        let restoredBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 22,
            hour: 5,
            minute: 0)))
        let missingResetSampleDate = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 19,
            hour: 12,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: shiftedBoundary.addingTimeInterval(-10 * 60),
                secondary: 48,
                secondaryResetsAt: shiftedBoundary),
            makeExactFitResetPlanSample(
                at: missingResetSampleDate,
                secondary: 54,
                secondaryResetsAt: nil),
            makeExactFitResetPlanSample(
                at: restoredBoundary.addingTimeInterval(-10 * 60),
                secondary: 20,
                secondaryResetsAt: restoredBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 4)
        #expect(model.usedPercents == [62, 0, 48, 20])
        #expect(model.pointDates == ["2026-03-08 05:00", "2026-03-15 05:00", "2026-03-16 02:00", "2026-03-22 05:00"])
    }

    @MainActor
    @Test
    func weeklyExactFitShowsTrailingZeroBarForCurrentExpectedReset() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 8,
            hour: 5,
            minute: 0)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 15,
            hour: 5,
            minute: 0)))
        let referenceDate = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 20,
            hour: 12,
            minute: 0)))
        let samples = [
            makeExactFitResetPlanSample(
                at: firstBoundary.addingTimeInterval(-30 * 60),
                secondary: 62,
                secondaryResetsAt: firstBoundary),
            makeExactFitResetPlanSample(
                at: secondBoundary.addingTimeInterval(-30 * 60),
                secondary: 48,
                secondaryResetsAt: secondBoundary),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex,
                referenceDate: referenceDate))

        #expect(model.pointCount == 3)
        #expect(model.usedPercents == [62, 48, 0])
        #expect(model.pointDates == ["2026-03-08 05:00", "2026-03-15 05:00", "2026-03-22 05:00"])
    }
}

private func makeExactFitResetPlanSample(
    at capturedAt: Date,
    secondary: Double,
    secondaryResetsAt: Date?) -> PlanUtilizationHistorySample
{
    PlanUtilizationHistorySample(
        capturedAt: capturedAt,
        primaryUsedPercent: nil,
        primaryWindowMinutes: nil,
        primaryResetsAt: nil,
        secondaryUsedPercent: secondary,
        secondaryWindowMinutes: 10080,
        secondaryResetsAt: secondaryResetsAt)
}
