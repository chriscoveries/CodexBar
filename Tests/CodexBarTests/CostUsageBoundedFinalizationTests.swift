import Foundation
#if canImport(SQLite3)
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageBoundedFinalizationTests {
    @Test
    func `exact progress proof follows the final bounded work pass`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = 600, candidateLimit = CostUsageScanner.codexCatchUpScanCandidateLimit
        _ = try CostUsagePerformanceGateTests.writeSyntheticCodexCorpus(
            env: env,
            day: day,
            files: corpusSize,
            turnsPerFile: 1)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0

        let first = Self.runPass(day: day, pass: 1, options: &options)
        #expect(first.metrics.codexFileScanAttempts == candidateLimit)
        #expect(first.metrics.codexProgressAccountingVisits == 0)
        #expect(first.cache.codexScanCatchUpPending == true)

        let second = Self.runPass(day: day, pass: 2, options: &options)
        #expect(second.metrics.codexFileScanAttempts == corpusSize - candidateLimit)
        #expect(second.metrics.codexProgressAccountingVisits == 0)
        #expect(second.cache.codexScanCatchUpPending == true)
        #expect(second.cache.codexActiveLookbackState != nil)

        let proof = Self.runPass(day: day, pass: 3, options: &options)
        print(
            "[finalization-proof] finalWorkAttempts=\(second.metrics.codexFileScanAttempts), "
                + "finalWorkAccounting=\(second.metrics.codexProgressAccountingVisits), "
                + "proofAttempts=\(proof.metrics.codexFileScanAttempts), "
                + "proofAccounting=\(proof.metrics.codexProgressAccountingVisits)")
        #expect(proof.metrics.codexFileScanAttempts == 0)
        #expect(proof.metrics.codexProgressAccountingVisits == corpusSize)
        #expect(proof.cache.codexScanCatchUpPending == false)
        #expect(proof.cache.codexScanProcessedBytes == proof.cache.codexScanTotalBytes)
        #expect(proof.cache.codexScanCompletedFiles == proof.cache.codexScanTotalFiles)
    }

    private static func runPass(
        day: Date,
        pass: Int,
        options: inout CostUsageScanner.Options)
        -> (metrics: CostUsageScanner.CodexScanWorkMetrics, cache: CostUsageCache)
    {
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(TimeInterval(pass)),
            options: options)
        return (recorder.snapshot(), CostUsageStoreAccess.read(cacheRoot: options.cacheRoot))
    }
}
#endif
