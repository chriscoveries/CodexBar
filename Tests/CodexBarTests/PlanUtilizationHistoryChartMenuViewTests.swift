import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PlanUtilizationHistoryChartMenuViewTests {
    @Test
    func `merged entries preserve first occurrence order while removing duplicates`() {
        let first = PlanUtilizationHistoryEntry(
            capturedAt: Date(timeIntervalSince1970: 100),
            usedPercent: 10,
            resetsAt: Date(timeIntervalSince1970: 200))
        let second = PlanUtilizationHistoryEntry(
            capturedAt: Date(timeIntervalSince1970: 300),
            usedPercent: 20,
            resetsAt: nil)

        let merged = PlanUtilizationHistoryChartMenuView.mergedEntries([
            first,
            second,
            first,
            second,
        ])

        #expect(merged == [first, second])
    }

    @Test
    func `generic primary weekly window keeps weekly history visible`() {
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 42,
                    resetsAt: nil),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: [history],
            provider: .zai,
            snapshot: snapshot)

        #expect(model.visibleSeries == ["weekly:10080"])
        #expect(model.selectedSeries == "weekly:10080")
    }

    @Test
    func `generic unknown weekly extra window does not filter saved history`() {
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usedPercent: 42,
                    resetsAt: nil),
            ])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "weekly-reset-only",
                    title: "Weekly reset",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: 10080,
                        resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
                        resetDescription: nil),
                    usageKnown: false),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: [history],
            provider: .zed,
            snapshot: snapshot)

        #expect(model.visibleSeries == ["weekly:10080"])
        #expect(model.selectedSeries == "weekly:10080")
    }

    @Test
    func `zai primary weekly window feeds current pace model at snapshot capture time`() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let capturedAt = start.addingTimeInterval(2 * 60 * 60)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: start.addingTimeInterval(60 * 60),
                    usedPercent: 10,
                    resetsAt: reset),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: reset, resetDescription: nil),
            secondary: nil,
            updatedAt: capturedAt)

        let model = try #require(PlanUtilizationHistoryChartMenuView._paceModelSnapshotForTesting(
            histories: [history],
            provider: .zai,
            snapshot: snapshot,
            referenceDate: capturedAt.addingTimeInterval(60)))

        #expect(model.selectedSeries == "weekly:10080")
        #expect(model.resetsAt == reset)
        #expect(model.observedDates.last == capturedAt)
        #expect(model.rawUsedPercents.last == 25)
    }

    @Test
    func `opencode go tertiary monthly window feeds monthly pace model`() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let capturedAt = start.addingTimeInterval(2 * 60 * 60)
        let reset = start.addingTimeInterval(30 * 24 * 60 * 60)
        let history = PlanUtilizationSeriesHistory(
            name: .monthly,
            windowMinutes: 43200,
            entries: [
                PlanUtilizationHistoryEntry(capturedAt: start, usedPercent: 5, resetsAt: reset),
            ])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: RateWindow(
                usedPercent: 15,
                windowMinutes: 43200,
                resetsAt: reset,
                resetDescription: nil),
            updatedAt: capturedAt)

        let model = try #require(PlanUtilizationHistoryChartMenuView._paceModelSnapshotForTesting(
            histories: [history],
            provider: .opencodego,
            snapshot: snapshot,
            referenceDate: capturedAt))

        #expect(model.selectedSeries == "monthly:43200")
        #expect(model.rawUsedPercents.last == 15)
    }

    @Test
    func `weekly history rejects reset-only session fallback`() {
        let reset = Date(timeIntervalSince1970: 1_700_100_000)
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: reset.addingTimeInterval(-60 * 60),
                    usedPercent: 25,
                    resetsAt: reset),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 91,
                windowMinutes: nil,
                resetsAt: reset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: reset.addingTimeInterval(-30 * 60))

        let usedPercent = PlanUtilizationHistoryChartMenuView._currentWindowUsedPercentForTesting(
            history: history,
            provider: .zed,
            snapshot: snapshot)

        #expect(usedPercent == nil)
    }

    @Test
    func `weekly history falls back to reset agreeing window when same duration candidate disagrees`() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let capturedAt = start.addingTimeInterval(2 * 60 * 60)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let disagreeingReset = reset.addingTimeInterval(5 * 60)
        let history = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: [
                PlanUtilizationHistoryEntry(
                    capturedAt: start.addingTimeInterval(60 * 60),
                    usedPercent: 12,
                    resetsAt: reset),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 89,
                windowMinutes: 10080,
                resetsAt: disagreeingReset,
                resetDescription: nil),
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "weekly",
                    title: "Weekly",
                    window: RateWindow(
                        usedPercent: 33,
                        windowMinutes: nil,
                        resetsAt: reset,
                        resetDescription: nil),
                    usageKnown: true),
            ],
            updatedAt: capturedAt)

        let usedPercent = PlanUtilizationHistoryChartMenuView._currentWindowUsedPercentForTesting(
            history: history,
            provider: .zai,
            snapshot: snapshot)

        #expect(usedPercent == 33)

        let model = try #require(PlanUtilizationHistoryChartMenuView._paceModelSnapshotForTesting(
            histories: [history],
            provider: .zai,
            snapshot: snapshot,
            referenceDate: capturedAt.addingTimeInterval(60)))

        #expect(model.selectedSeries == "weekly:10080")
        #expect(model.resetsAt == reset)
        #expect(model.observedDates == [history.entries[0].capturedAt, capturedAt])
        #expect(model.rawUsedPercents == [12, 33])
    }
}
