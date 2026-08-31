import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct PlanUtilizationPaceChartModelTests {
    @Test
    func `empty history without current reset does not build`() {
        let history = Self.history(windowMinutes: 60, entries: [])

        #expect(Self.model(history: history, current: nil) == nil)
    }

    @Test
    func `synthetic current window does not build`() {
        let reset = Self.date(3600)
        let history = Self.history(windowMinutes: 60, entries: [
            Self.entry(at: 1800, used: 20, reset: reset),
        ])

        let model = Self.model(
            history: history,
            current: RateWindow(
                usedPercent: 25,
                windowMinutes: 60,
                resetsAt: reset,
                resetDescription: nil,
                isSyntheticPlaceholder: true))

        #expect(model == nil)
    }

    @Test
    func `invalid window duration does not build`() {
        let reset = Self.date(3600)
        let history = Self.history(windowMinutes: 0, entries: [
            Self.entry(at: 1800, used: 20, reset: reset),
        ])

        #expect(Self.model(history: history, current: nil) == nil)
    }

    @Test
    func `pace endpoints derive start from reset and duration`() throws {
        let reset = Self.date(7 * 24 * 60 * 60)
        let history = Self.history(windowMinutes: 7 * 24 * 60, entries: [
            Self.entry(at: reset.timeIntervalSince1970 - 60 * 60, used: 50, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: reset.addingTimeInterval(-60)))

        #expect(model.windowStart == Self.date(0))
        #expect(model.resetsAt == reset)
        #expect(model.paceEndpoints == [
            .init(date: Self.date(0), remainingPercent: 100),
            .init(date: reset, remainingPercent: 0),
        ])
        #expect(model.resetMarker == reset)
    }

    @Test
    func `current duration wins over history duration for daily weekly and monthly domains`() throws {
        let reset = Self.date(31 * 24 * 60 * 60)
        let samples = [Self.entry(at: reset.timeIntervalSince1970 - 60, used: 10, reset: reset)]

        let daily = try #require(Self.model(
            history: Self.history(windowMinutes: 999, entries: samples),
            current: Self.window(used: 10, minutes: 24 * 60, reset: reset),
            now: reset.addingTimeInterval(-60)))
        let weekly = try #require(Self.model(
            history: Self.history(windowMinutes: 999, entries: samples),
            current: Self.window(used: 10, minutes: 7 * 24 * 60, reset: reset),
            now: reset.addingTimeInterval(-60)))
        let monthly = try #require(Self.model(
            history: Self.history(windowMinutes: 999, entries: samples),
            current: Self.window(used: 10, minutes: 30 * 24 * 60, reset: reset),
            now: reset.addingTimeInterval(-60)))

        #expect(daily.windowDuration == 24 * 60 * 60)
        #expect(weekly.windowDuration == 7 * 24 * 60 * 60)
        #expect(monthly.windowDuration == 30 * 24 * 60 * 60)
    }

    @Test
    func `live point appends inside domain and deduplicates same timestamp`() throws {
        let reset = Self.date(7200)
        let now = Self.date(3600)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 1800, used: 10, reset: reset),
            Self.entry(at: 3600, used: 20, reset: reset),
        ])

        let model = try #require(Self.model(
            history: history,
            current: Self.window(used: 30, minutes: 120, reset: reset),
            now: now))

        #expect(model.observedPoints.map(\.date) == [Self.date(1800), now])
        #expect(model.observedPoints.last?.rawUsedPercent == 30)
        #expect(model.observedPoints.last?.source == .live)
    }

    @Test
    func `raw remaining preserves overage while display clamps`() throws {
        let reset = Self.date(7200)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 3600, used: 125, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(3600)))
        let point = try #require(model.observedPoints.first)

        #expect(point.rawRemainingPercent == -25)
        #expect(point.displayRemainingPercent == 0)
    }

    @Test
    func `already exhausted latest point does not project`() throws {
        let reset = Self.date(7200)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 1800, used: 90, reset: reset),
            Self.entry(at: 3600, used: 125, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(3600)))

        #expect(model.projection == nil)
    }

    @Test
    func `non finite history and live usage are discarded`() throws {
        let reset = Self.date(7200)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 1800, used: .nan, reset: reset),
            Self.entry(at: 2700, used: 20, reset: reset),
            Self.entry(at: 3600, used: .infinity, reset: reset),
        ])

        let model = try #require(Self.model(
            history: history,
            current: Self.window(used: -.infinity, minutes: 120, reset: reset),
            now: Self.date(3600)))

        #expect(model.observedPoints.map(\.rawUsedPercent) == [20])
        #expect(model.projection == nil)
    }

    @Test
    func `missing buckets split observed worm and expose gap metadata`() throws {
        let reset = Self.date(6 * 60 * 60)
        let history = Self.history(windowMinutes: 360, entries: [
            Self.entry(at: 60 * 60, used: 10, reset: reset),
            Self.entry(at: 2 * 60 * 60, used: 20, reset: reset),
            Self.entry(at: 4 * 60 * 60, used: 30, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(4 * 60 * 60)))

        #expect(model.observedSegments.map(\.count) == [2, 1])
        #expect(model.gaps == [
            .init(start: Self.date(2 * 60 * 60), end: Self.date(4 * 60 * 60), duration: 2 * 60 * 60),
        ])
    }

    @Test
    func `one point does not forecast`() throws {
        let reset = Self.date(7200)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 3600, used: 10, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(3600)))

        #expect(model.projection == nil)
    }

    @Test
    func `constant burn projects run out before reset`() throws {
        let reset = Self.date(10 * 60 * 60)
        let history = Self.history(windowMinutes: 600, entries: [
            Self.entry(at: 0, used: 0, reset: reset),
            Self.entry(at: 60 * 60, used: 20, reset: reset),
            Self.entry(at: 2 * 60 * 60, used: 40, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(2 * 60 * 60)))
        let projection = try #require(model.projection)

        Self.expectClose(projection.runOutAt?.timeIntervalSince1970, 5 * 60 * 60)
        #expect(projection.end.rawRemainingPercent == 0)
        #expect(projection.end.date <= reset)
    }

    @Test
    func `whole window rate includes usage accrued before retained history begins`() throws {
        let reset = Self.date(7 * 24 * 60 * 60)
        let history = Self.history(windowMinutes: 7 * 24 * 60, entries: [
            Self.entry(at: 4 * 24 * 60 * 60, used: 80, reset: reset),
            Self.entry(at: 4 * 24 * 60 * 60 + 60 * 60, used: 81, reset: reset),
        ])

        let model = try #require(Self.model(
            history: history,
            current: nil,
            now: Self.date(4 * 24 * 60 * 60 + 60 * 60)))
        let projection = try #require(model.projection)

        #expect(projection.runOutAt != nil)
        #expect(projection.end.date < reset)
    }

    @Test
    func `zero cumulative burn survives flat to reset`() throws {
        let reset = Self.date(10 * 60 * 60)
        let history = Self.history(windowMinutes: 600, entries: [
            Self.entry(at: 60 * 60, used: 0, reset: reset),
            Self.entry(at: 2 * 60 * 60, used: 0, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(2 * 60 * 60)))
        let projection = try #require(model.projection)

        #expect(projection.runOutAt == nil)
        #expect(projection.end.date == reset)
        #expect(projection.end.rawRemainingPercent == 100)
    }

    @Test
    func `forecast is low confidence before four recent intervals`() throws {
        let reset = Self.date(10 * 60 * 60)
        let history = Self.history(windowMinutes: 600, entries: [
            Self.entry(at: 60 * 60, used: 10, reset: reset),
            Self.entry(at: 2 * 60 * 60, used: 20, reset: reset),
            Self.entry(at: 3 * 60 * 60, used: 30, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(3 * 60 * 60)))
        let projection = try #require(model.projection)

        #expect(projection.evidence == 0.5)
        #expect(projection.isLowConfidence)
    }

    @Test
    func `spike resistant forecast caps isolated interval outlier`() throws {
        let reset = Self.date(30 * 60 * 60)
        let history = Self.history(windowMinutes: 30 * 60, entries: [
            Self.entry(at: 20 * 60 * 60, used: 10, reset: reset),
            Self.entry(at: 21 * 60 * 60, used: 11, reset: reset),
            Self.entry(at: 22 * 60 * 60, used: 12, reset: reset),
            Self.entry(at: 23 * 60 * 60, used: 13, reset: reset),
            Self.entry(at: 24 * 60 * 60, used: 80, reset: reset),
            Self.entry(at: 25 * 60 * 60, used: 81, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(25 * 60 * 60)))
        let projection = try #require(model.projection)
        let uncappedLatestSpikeRate = 67.0 / (60 * 60)

        #expect(projection.burnRatePercentPerSecond < uncappedLatestSpikeRate / 4)
        #expect(projection.end.date <= reset)
    }

    @Test
    func `four recent intervals cannot let one spike dominate full evidence`() throws {
        let reset = Self.date(12 * 60 * 60)
        let history = Self.history(windowMinutes: 720, entries: [
            Self.entry(at: 1 * 60 * 60, used: 1, reset: reset),
            Self.entry(at: 2 * 60 * 60, used: 2, reset: reset),
            Self.entry(at: 3 * 60 * 60, used: 3, reset: reset),
            Self.entry(at: 4 * 60 * 60, used: 4, reset: reset),
            Self.entry(at: 5 * 60 * 60, used: 71, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(5 * 60 * 60)))
        let projection = try #require(model.projection)
        let spikeRate = 67.0 / (60 * 60)

        #expect(projection.evidence == 1)
        #expect(projection.burnRatePercentPerSecond < spikeRate / 4)
    }

    @Test
    func `nearest hover exposes precise raw display and pace delta`() throws {
        let reset = Self.date(120)
        let history = Self.history(windowMinutes: 2, entries: [
            Self.entry(at: 60, used: 20, reset: reset),
            Self.entry(at: 96, used: 120, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(96)))
        let hover = try #require(model.nearestObservedPoint(to: Self.date(98)))

        #expect(hover.point.date == Self.date(96))
        #expect(hover.point.rawRemainingPercent == -20)
        #expect(hover.point.displayRemainingPercent == 0)
        Self.expectClose(hover.point.paceRemainingPercent, 20)
        Self.expectClose(hover.deltaFromPace, -40)
    }

    @Test
    func `nearest hover returns nil inside an explicit history gap`() throws {
        let reset = Self.date(6 * 60 * 60)
        let history = Self.history(windowMinutes: 360, entries: [
            Self.entry(at: 60 * 60, used: 10, reset: reset),
            Self.entry(at: 4 * 60 * 60, used: 30, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(4 * 60 * 60)))

        #expect(model.nearestObservedPoint(to: Self.date(2 * 60 * 60)) == nil)
    }

    @Test
    func `reset jitter below two minutes belongs while exact boundary is excluded`() throws {
        let reset = Self.date(7200)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 1800, used: 10, reset: reset.addingTimeInterval(119)),
            Self.entry(at: 3600, used: 20, reset: reset.addingTimeInterval(2 * 60)),
        ])

        let model = try #require(Self.model(
            history: history,
            current: Self.window(used: 30, minutes: 120, reset: reset),
            now: Self.date(5400)))

        #expect(model.observedPoints.map(\.rawUsedPercent) == [10, 30])
    }

    @Test
    func `provider correction may move the remaining worm upward`() throws {
        let reset = Self.date(4 * 60 * 60)
        let history = Self.history(windowMinutes: 240, entries: [
            Self.entry(at: 60 * 60, used: 40, reset: reset),
            Self.entry(at: 2 * 60 * 60, used: 30, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(2 * 60 * 60)))

        #expect(model.observedPoints.map(\.rawRemainingPercent) == [60, 70])
    }

    @Test
    func `stale live snapshot keeps its capture time and does not forecast as fresh`() throws {
        let reset = Self.date(8 * 60 * 60)
        let capturedAt = Self.date(2 * 60 * 60)
        let now = Self.date(4 * 60 * 60)
        let history = Self.history(windowMinutes: 480, entries: [
            Self.entry(at: 60 * 60, used: 10, reset: reset),
        ])

        let model = try #require(PlanUtilizationPaceChartModel(
            history: history,
            currentWindow: Self.window(used: 20, minutes: 480, reset: reset),
            referenceDate: now,
            currentWindowCapturedAt: capturedAt))

        #expect(model.observedPoints.last?.date == capturedAt)
        #expect(model.projection == nil)
    }

    @Test
    func `stale latest history point does not project`() throws {
        let reset = Self.date(8 * 60 * 60)
        let history = Self.history(windowMinutes: 480, entries: [
            Self.entry(at: 60 * 60, used: 10, reset: reset),
            Self.entry(at: 2 * 60 * 60, used: 20, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(4 * 60 * 60)))

        #expect(model.projection == nil)
    }

    @Test
    func `out of order inputs sort into chronological points`() throws {
        let reset = Self.date(7200)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 5400, used: 30, reset: reset),
            Self.entry(at: 1800, used: 10, reset: reset),
            Self.entry(at: 3600, used: 20, reset: reset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(5400)))

        #expect(model.observedPoints.map(\.date) == [Self.date(1800), Self.date(3600), Self.date(5400)])
    }

    @Test
    func `out of order history chooses latest suitable reset when current is absent`() throws {
        let olderReset = Self.date(7200)
        let latestReset = Self.date(14400)
        let history = Self.history(windowMinutes: 120, entries: [
            Self.entry(at: 10800, used: 25, reset: latestReset),
            Self.entry(at: 3600, used: 75, reset: olderReset),
        ])

        let model = try #require(Self.model(history: history, current: nil, now: Self.date(10800)))

        #expect(model.resetsAt == latestReset)
        #expect(model.observedPoints.map(\.date) == [Self.date(10800)])
    }

    private static func model(
        history: PlanUtilizationSeriesHistory,
        current: RateWindow?,
        now: Date = Self.date(0)) -> PlanUtilizationPaceChartModel?
    {
        PlanUtilizationPaceChartModel(history: history, currentWindow: current, referenceDate: now)
    }

    private static func history(
        windowMinutes: Double,
        entries: [PlanUtilizationHistoryEntry]) -> PlanUtilizationSeriesHistory
    {
        PlanUtilizationSeriesHistory(name: .weekly, windowMinutes: Int(windowMinutes), entries: entries)
    }

    private static func window(used: Double, minutes: Int, reset: Date) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset, resetDescription: nil)
    }

    private static func entry(at timeInterval: TimeInterval, used: Double, reset: Date?)
        -> PlanUtilizationHistoryEntry
    {
        PlanUtilizationHistoryEntry(capturedAt: self.date(timeInterval), usedPercent: used, resetsAt: reset)
    }

    private static func date(_ timeInterval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: timeInterval)
    }

    private static func expectClose(
        _ actual: Double?,
        _ expected: Double,
        tolerance: Double = 0.001,
        sourceLocation: SourceLocation = #_sourceLocation)
    {
        guard let actual else {
            Issue.record("Expected value close to \(expected), got nil", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(actual - expected) <= tolerance, sourceLocation: sourceLocation)
    }
}
