import CodexBarCore
import Foundation

struct PlanUtilizationPaceChartModel: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            case history
            case live
            case projection
        }

        let date: Date
        let rawUsedPercent: Double
        let rawRemainingPercent: Double
        let displayRemainingPercent: Double
        let paceRemainingPercent: Double
        let source: Source
    }

    struct PaceEndpoint: Equatable, Sendable {
        let date: Date
        let remainingPercent: Double
    }

    struct Gap: Equatable, Sendable {
        let start: Date
        let end: Date
        let duration: TimeInterval
    }

    struct HoverPoint: Equatable, Sendable {
        let point: Point
        let deltaFromPace: Double
    }

    struct Projection: Equatable, Sendable {
        let start: Point
        let end: Point
        let runOutAt: Date?
        let burnRatePercentPerSecond: Double
        let evidence: Double
        let isLowConfidence: Bool
    }

    let seriesName: PlanUtilizationSeriesName
    let windowStart: Date
    let resetsAt: Date
    let windowDuration: TimeInterval
    let paceEndpoints: [PaceEndpoint]
    let resetMarker: Date
    let observedPoints: [Point]
    let observedSegments: [[Point]]
    let gaps: [Gap]
    let projection: Projection?

    /// Matches plan-history reset segmentation: reset timestamps less than two minutes apart
    /// describe the same provider window; exactly two minutes starts a different segment.
    private static let resetBoundaryTolerance: TimeInterval = 2 * 60
    private static let recentEvidenceTarget = 4.0
    private static let medianAbsoluteDeviationMultiplier = 3.0

    init?(
        history: PlanUtilizationSeriesHistory,
        currentWindow: RateWindow?,
        referenceDate: Date,
        currentWindowCapturedAt: Date? = nil,
        historyBucketInterval: TimeInterval = 60 * 60,
        expectedRefreshInterval: TimeInterval = 30 * 60,
        conservativeGapFloor: TimeInterval = 90 * 60)
    {
        if currentWindow?.isSyntheticPlaceholder == true {
            return nil
        }

        let windowMinutes = Self.authoritativeWindowMinutes(history: history, currentWindow: currentWindow)
        guard let windowMinutes, windowMinutes > 0 else { return nil }
        let windowDuration = TimeInterval(windowMinutes) * 60
        guard windowDuration.isFinite, windowDuration > 0 else { return nil }

        let resetsAt = Self.authoritativeReset(history: history, currentWindow: currentWindow, duration: windowDuration)
        guard let resetsAt, resetsAt.timeIntervalSince1970.isFinite else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-windowDuration)
        guard windowStart < resetsAt else { return nil }
        let windowDomain = WindowDomain(start: windowStart, reset: resetsAt, duration: windowDuration)

        let gapThreshold = max(historyBucketInterval * 1.5, expectedRefreshInterval * 2, conservativeGapFloor)
        let observations = Self.observations(
            history: history,
            currentWindow: currentWindow,
            currentWindowCapturedAt: currentWindowCapturedAt ?? referenceDate,
            windowStart: windowStart,
            resetsAt: resetsAt)
        let observedPoints = Self.deduplicatedPoints(
            observations: observations,
            domain: windowDomain)
        let segmentation = Self.segment(points: observedPoints, gapThreshold: gapThreshold)

        self.seriesName = history.name
        self.windowStart = windowStart
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
        self.paceEndpoints = [
            PaceEndpoint(date: windowStart, remainingPercent: 100),
            PaceEndpoint(date: resetsAt, remainingPercent: 0),
        ]
        self.resetMarker = resetsAt
        self.observedPoints = observedPoints
        self.observedSegments = segmentation.segments
        self.gaps = segmentation.gaps
        self.projection = Self.projection(
            latestSegment: segmentation.segments.last ?? [],
            domain: windowDomain,
            referenceDate: referenceDate,
            staleThreshold: gapThreshold)
    }

    func nearestObservedPoint(to date: Date) -> HoverPoint? {
        if self.gaps.contains(where: { date > $0.start && date < $0.end }) {
            return nil
        }
        guard let point = self.observedPoints.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.date.timeIntervalSince(date))
            let rhsDistance = abs(rhs.date.timeIntervalSince(date))
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhs.date < rhs.date
        }) else {
            return nil
        }
        return HoverPoint(point: point, deltaFromPace: point.rawRemainingPercent - point.paceRemainingPercent)
    }

    private struct Observation: Sendable {
        let date: Date
        let usedPercent: Double
        let source: Point.Source
    }

    private struct WindowDomain: Sendable {
        let start: Date
        let reset: Date
        let duration: TimeInterval
    }

    private static func authoritativeWindowMinutes(
        history: PlanUtilizationSeriesHistory,
        currentWindow: RateWindow?) -> Int?
    {
        if let windowMinutes = currentWindow?.windowMinutes, windowMinutes > 0 {
            return windowMinutes
        }
        return history.windowMinutes > 0 ? history.windowMinutes : nil
    }

    private static func authoritativeReset(
        history: PlanUtilizationSeriesHistory,
        currentWindow: RateWindow?,
        duration: TimeInterval) -> Date?
    {
        if let resetsAt = currentWindow?.resetsAt {
            return resetsAt
        }
        return history.entries.compactMap { entry -> (capturedAt: Date, resetsAt: Date)? in
            guard let resetsAt = entry.resetsAt else { return nil }
            let windowStart = resetsAt.addingTimeInterval(-duration)
            guard entry.capturedAt >= windowStart, entry.capturedAt <= resetsAt else { return nil }
            return (entry.capturedAt, resetsAt)
        }
        .max { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            return lhs.resetsAt < rhs.resetsAt
        }?.resetsAt
    }

    private static func observations(
        history: PlanUtilizationSeriesHistory,
        currentWindow: RateWindow?,
        currentWindowCapturedAt: Date,
        windowStart: Date,
        resetsAt: Date) -> [Observation]
    {
        var observations = history.entries.compactMap { entry -> Observation? in
            guard entry.usedPercent.isFinite else { return nil }
            guard entry.capturedAt >= windowStart, entry.capturedAt <= resetsAt else { return nil }
            if let entryReset = entry.resetsAt,
               abs(entryReset.timeIntervalSince(resetsAt)) >= Self.resetBoundaryTolerance
            {
                return nil
            }
            return Observation(date: entry.capturedAt, usedPercent: entry.usedPercent, source: .history)
        }

        if let currentWindow,
           !currentWindow.isSyntheticPlaceholder,
           currentWindow.usedPercent.isFinite,
           currentWindowCapturedAt >= windowStart,
           currentWindowCapturedAt <= resetsAt
        {
            observations.append(Observation(
                date: currentWindowCapturedAt,
                usedPercent: currentWindow.usedPercent,
                source: .live))
        }

        return observations
    }

    private static func deduplicatedPoints(
        observations: [Observation],
        domain: WindowDomain) -> [Point]
    {
        observations
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date < rhs.date
                }
                if lhs.source != rhs.source {
                    return Self.sourceRank(lhs.source) < Self.sourceRank(rhs.source)
                }
                return lhs.usedPercent < rhs.usedPercent
            }
            .reduce(into: [Point]()) { points, observation in
                let point = Self.point(
                    date: observation.date,
                    usedPercent: observation.usedPercent,
                    source: observation.source,
                    domain: domain)
                if points.last?.date == point.date {
                    points[points.count - 1] = point
                } else {
                    points.append(point)
                }
            }
    }

    private static func sourceRank(_ source: Point.Source) -> Int {
        switch source {
        case .history: 0
        case .live: 1
        case .projection: 2
        }
    }

    private static func point(
        date: Date,
        usedPercent: Double,
        source: Point.Source,
        domain: WindowDomain) -> Point
    {
        let rawRemainingPercent = 100 - usedPercent
        return Point(
            date: date,
            rawUsedPercent: usedPercent,
            rawRemainingPercent: rawRemainingPercent,
            displayRemainingPercent: UsagePercent(raw: rawRemainingPercent).displayClamped,
            paceRemainingPercent: Self.paceRemainingPercent(
                at: date,
                windowStart: domain.start,
                resetsAt: domain.reset,
                windowDuration: domain.duration),
            source: source)
    }

    private static func paceRemainingPercent(
        at date: Date,
        windowStart: Date,
        resetsAt: Date,
        windowDuration: TimeInterval) -> Double
    {
        if date <= windowStart {
            return 100
        }
        if date >= resetsAt {
            return 0
        }
        let elapsed = date.timeIntervalSince(windowStart)
        return 100 - (elapsed / windowDuration * 100)
    }

    private static func segment(points: [Point], gapThreshold: TimeInterval)
        -> (segments: [[Point]], gaps: [Gap])
    {
        guard let first = points.first else {
            return ([], [])
        }

        var segments: [[Point]] = [[first]]
        var gaps: [Gap] = []

        for point in points.dropFirst() {
            guard let previous = segments[segments.count - 1].last else {
                segments[segments.count - 1].append(point)
                continue
            }
            let interval = point.date.timeIntervalSince(previous.date)
            if interval > gapThreshold {
                gaps.append(Gap(start: previous.date, end: point.date, duration: interval))
                segments.append([point])
            } else {
                segments[segments.count - 1].append(point)
            }
        }

        return (segments, gaps)
    }

    private static func projection(
        latestSegment: [Point],
        domain: WindowDomain,
        referenceDate: Date,
        staleThreshold: TimeInterval) -> Projection?
    {
        guard latestSegment.count >= 2,
              let latest = latestSegment.last,
              latest.rawRemainingPercent > 0,
              latest.date < domain.reset
        else {
            return nil
        }
        if referenceDate.timeIntervalSince(latest.date) > staleThreshold {
            return nil
        }

        let observedWindowInterval = latest.date.timeIntervalSince(domain.start)
        guard observedWindowInterval > 0 else { return nil }

        // Provider usage is cumulative within the reset window, so this remains meaningful even
        // when CodexBar's first retained observation arrives after the window began.
        let wholeRate = max(0, latest.rawUsedPercent) / observedWindowInterval
        let intervals = self.burnIntervals(
            points: latestSegment,
            latestDate: latest.date,
            windowDuration: domain.duration)
        let recentIntervalCount = intervals.count
        let evidence = min(Double(recentIntervalCount) / self.recentEvidenceTarget, 1)
        let recentRate = self.weightedRecentRate(intervals)
        let blendedRate = evidence * recentRate + (1 - evidence) * wholeRate

        let endDate: Date
        let endRemaining: Double
        let runOutAt: Date?
        if blendedRate <= 0 {
            endDate = domain.reset
            endRemaining = latest.rawRemainingPercent
            runOutAt = nil
        } else {
            let runOut = latest.date.addingTimeInterval(latest.rawRemainingPercent / blendedRate)
            if runOut <= domain.reset {
                endDate = runOut
                endRemaining = 0
                runOutAt = runOut
            } else {
                endDate = domain.reset
                endRemaining = latest.rawRemainingPercent - blendedRate * domain.reset.timeIntervalSince(latest.date)
                runOutAt = nil
            }
        }

        let endPoint = Point(
            date: endDate,
            rawUsedPercent: 100 - endRemaining,
            rawRemainingPercent: endRemaining,
            displayRemainingPercent: UsagePercent(raw: endRemaining).displayClamped,
            paceRemainingPercent: Self.paceRemainingPercent(
                at: endDate,
                windowStart: domain.start,
                resetsAt: domain.reset,
                windowDuration: domain.duration),
            source: .projection)
        return Projection(
            start: latest,
            end: endPoint,
            runOutAt: runOutAt,
            burnRatePercentPerSecond: blendedRate,
            evidence: evidence,
            isLowConfidence: evidence < 1)
    }

    private struct BurnInterval {
        let rate: Double
        let age: TimeInterval
    }

    private static func burnIntervals(
        points: [Point],
        latestDate: Date,
        windowDuration: TimeInterval) -> [BurnInterval]
    {
        let horizon = min(24 * 60 * 60, windowDuration * 0.25)
        let horizonStart = latestDate.addingTimeInterval(-horizon)
        let rawRates = zip(points, points.dropFirst()).compactMap { previous, current -> (rate: Double, end: Date)? in
            let interval = current.date.timeIntervalSince(previous.date)
            guard interval > 0, current.date >= horizonStart else { return nil }
            return (max(0, current.rawUsedPercent - previous.rawUsedPercent) / interval, current.date)
        }
        let cap = self.winsorizedUpperCap(rawRates.map(\.rate))
        return rawRates.map {
            BurnInterval(rate: min($0.rate, cap ?? $0.rate), age: latestDate.timeIntervalSince($0.end))
        }
    }

    private static func weightedRecentRate(_ intervals: [BurnInterval]) -> Double {
        guard !intervals.isEmpty else { return 0 }
        let maxAge = max(intervals.map(\.age).max() ?? 0, 1)
        var weightedSum = 0.0
        var totalWeight = 0.0
        for interval in intervals {
            let weight = exp(-interval.age / maxAge)
            weightedSum += interval.rate * weight
            totalWeight += weight
        }
        return totalWeight > 0 ? weightedSum / totalWeight : 0
    }

    private static func winsorizedUpperCap(_ values: [Double]) -> Double? {
        guard values.count >= 4 else { return nil }
        let sorted = values.sorted()
        let q1 = self.percentile(sorted, 0.25)
        let q3 = self.percentile(sorted, 0.75)
        let iqrCap = q3 + 1.5 * (q3 - q1)
        let median = self.percentile(sorted, 0.5)
        let absoluteDeviations = sorted.map { abs($0 - median) }.sorted()
        let medianAbsoluteDeviation = self.percentile(absoluteDeviations, 0.5)
        let deviationCap = median + self.medianAbsoluteDeviationMultiplier * medianAbsoluteDeviation
        return min(iqrCap, deviationCap)
    }

    private static func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
        guard let first = sortedValues.first else { return 0 }
        guard sortedValues.count > 1 else { return first }
        let position = percentile * Double(sortedValues.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        if lowerIndex == upperIndex {
            return sortedValues[lowerIndex]
        }
        let fraction = position - Double(lowerIndex)
        return sortedValues[lowerIndex] + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * fraction
    }
}
