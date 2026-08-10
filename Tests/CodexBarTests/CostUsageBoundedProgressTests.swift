import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageBoundedProgressTests {
    @Test
    func `bounded progress accumulates while retaining a wider scan window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        var options = Self.boundedOptions(env: env)
        let priorDay = try #require(options.calendar.date(byAdding: .day, value: -1, to: day))
        options.maxCodexScanDurationPerRefresh = nil
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: priorDay,
            until: day,
            now: day,
            options: options)

        let corpusSize = 600
        try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)
        options.maxCodexScanDurationPerRefresh = 60
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(firstCache.codexScanCompletedFiles == 512)
        #expect(firstCache.codexScanTotalFiles == corpusSize)

        let secondRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = secondRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(secondRecorder.snapshot().codexProgressAccountingVisits == 0)
        #expect((secondCache.codexScanCompletedFiles ?? 0) > 512)
        #expect(secondCache.codexScanTotalFiles == corpusSize)
        #expect(secondCache.codexScanInventoryPaths == nil)
        #expect(secondCache.codexScanCatchUpPending == true)
    }

    @Test
    func `time limited catch-up keeps bounded progress until exact validation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = 1500
        try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)

        var options = Self.boundedOptions(env: env)
        let saveCounter = BoundedProgressCounter()
        CostUsageStore.codexCatchUpReconciliationVisitForTesting = { saveCounter.increment() }
        let firstRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = firstRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstMetrics = firstRecorder.snapshot()

        let loadCounter = BoundedProgressCounter()
        CostUsageStore.codexCatchUpReconciliationVisitForTesting = { loadCounter.increment() }
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        CostUsageStore.codexCatchUpReconciliationVisitForTesting = nil
        #expect(saveCounter.value == 512)
        #expect(loadCounter.value == 512)
        #expect(firstMetrics.codexFileScanAttempts == 512)
        #expect(firstMetrics.codexCandidateSelectionVisits == 512)
        #expect(firstMetrics.activeLookbackCompletionCandidates == 512)
        #expect(firstMetrics.codexProgressAccountingVisits == 0)
        #expect(firstCache.files.count == 512)
        #expect(firstCache.codexActiveLookbackState?.pendingFilePaths.count == 988)
        #expect(firstCache.codexScanProcessedBytes == 0)
        #expect(firstCache.codexScanTotalBytes == 0)
        #expect(firstCache.codexScanCompletedFiles == 512)
        #expect(firstCache.codexScanTotalFiles == corpusSize)
        #expect(firstCache.codexScanInventoryPaths == nil)
        #expect(firstCache.codexScanCatchUpPending == true)

        let secondRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = secondRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let secondMetrics = secondRecorder.snapshot()
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(secondMetrics.codexFileScanAttempts == 512)
        #expect(secondMetrics.codexCandidateSelectionVisits == 512)
        #expect(secondMetrics.activeLookbackCompletionCandidates == 512)
        #expect(secondMetrics.codexProgressAccountingVisits == 0)
        #expect(secondCache.files.count == 1024)
        #expect(secondCache.codexActiveLookbackState?.pendingFilePaths.count == 476)
        #expect(secondCache.codexScanProcessedBytes == 0)
        #expect(secondCache.codexScanTotalBytes == 0)
        #expect(secondCache.codexScanCompletedFiles == 1024)
        #expect(secondCache.codexScanTotalFiles == corpusSize)
        #expect(secondCache.codexScanInventoryPaths == nil)
        #expect(secondCache.codexScanCatchUpPending == true)

        let finalRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = finalRecorder
        options.maxCodexScanDurationPerRefresh = nil
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let finalMetrics = finalRecorder.snapshot()
        let finalCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let exactTotalBytes = finalCache.files.values.reduce(Int64(0)) { $0 + max(0, $1.size) }
        #expect(finalMetrics.codexProgressAccountingVisits == corpusSize)
        #expect(finalCache.codexActiveLookbackState == nil)
        #expect(finalCache.codexScanCatchUpPending == false)
        #expect(finalCache.files.count == corpusSize)
        #expect(Set(finalCache.codexScanInventoryPaths ?? []) == Set(finalCache.files.keys))
        #expect(finalCache.codexScanProcessedBytes == exactTotalBytes)
        #expect(finalCache.codexScanTotalBytes == exactTotalBytes)
        #expect(finalCache.codexScanCompletedFiles == corpusSize)
        #expect(finalCache.codexScanTotalFiles == corpusSize)
    }

    @Test
    func `candidate visit limit defers exact accounting without active lookback work`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 1
        var fileURLs: [URL] = []
        fileURLs.reserveCapacity(corpusSize)
        for index in 0..<corpusSize {
            let sessionID = "selection-limit-\(index)"
            let contents = [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"\#(sessionID)"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            ].joined(separator: "\n") + "\n"
            try fileURLs.append(env.writeCodexSessionFile(
                day: day,
                filename: String(format: "selection-limit-%04d.jsonl", index),
                contents: contents))
        }
        let oldModificationDate = day.addingTimeInterval(-24 * 60 * 60)
        for fileURL in fileURLs {
            try FileManager.default.setAttributes(
                [.modificationDate: oldModificationDate],
                ofItemAtPath: fileURL.path)
        }

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        for path in pendingCache.files.keys {
            pendingCache.files[path]?.codexScanComplete = false
        }
        pendingCache.codexActiveLookbackState = nil
        pendingCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: pendingCache)

        options.maxCodexScanDurationPerRefresh = 60
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let metrics = recorder.snapshot()
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(metrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(metrics.codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(metrics.codexProgressAccountingVisits == 0)
        #expect(cache.codexActiveLookbackState == nil)
        #expect(cache.files.values.count(where: { $0.codexScanComplete == false }) == 1)
        #expect(cache.codexScanProcessedBytes == 0)
        #expect(cache.codexScanTotalBytes == 0)
        #expect(cache.codexScanCompletedFiles == corpusSize - 1)
        #expect(cache.codexScanTotalFiles == corpusSize)
        #expect(cache.codexScanInventoryPaths == nil)
        #expect(cache.codexScanCatchUpPending == true)
    }

    private static func boundedOptions(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func writeSyntheticCorpus(
        env: CostUsageTestEnvironment,
        day: Date,
        fileCount: Int) throws
    {
        let iso = env.isoString(for: day)
        for index in 0..<fileCount {
            let lines = [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"progress-\#(index)"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ]
            _ = try env.writeCodexSessionFile(
                day: day,
                filename: String(format: "progress-%04d.jsonl", index),
                contents: lines.joined(separator: "\n") + "\n")
        }
    }
}

private final class BoundedProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
