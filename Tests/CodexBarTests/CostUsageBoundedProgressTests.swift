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
        #expect(secondRecorder.snapshot().codexProgressAccountingVisits == corpusSize)
        #expect(secondCache.codexScanCompletedFiles == corpusSize)
        #expect(secondCache.codexScanTotalFiles == corpusSize)
        #expect(secondCache.codexScanInventoryPaths?.count == corpusSize)
        #expect(secondCache.codexScanCatchUpPending == false)
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
    func `bounded queue advances past a cached complete prefix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 1
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)
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
        let incompleteFilename = try #require(fileURLs.last?.lastPathComponent)
        let incompletePath = try #require(pendingCache.files.keys.first { $0.hasSuffix(incompleteFilename) })
        pendingCache.files[incompletePath]?.codexScanComplete = false
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

        let firstMetrics = recorder.snapshot()
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(firstMetrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexProgressAccountingVisits == 0)
        #expect(firstCache.codexActiveLookbackState?.pendingFilePaths == [incompletePath.resolvingTemporaryPath])
        #expect(firstCache.files[incompletePath]?.codexScanComplete == false)
        #expect(firstCache.codexScanCompletedFiles == corpusSize - 1)
        #expect(firstCache.codexScanTotalFiles == corpusSize)
        #expect(firstCache.codexScanInventoryPaths == nil)
        #expect(firstCache.codexScanCatchUpPending == true)

        let secondRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = secondRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondMetrics = secondRecorder.snapshot()
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(secondMetrics.codexCandidateSelectionVisits == 1)
        #expect(secondMetrics.codexFileScanAttempts == 1)
        #expect(secondMetrics.codexProgressAccountingVisits == corpusSize)
        #expect(secondCache.files[incompletePath]?.codexScanComplete == true)
        #expect(secondCache.codexActiveLookbackState == nil)
        #expect(secondCache.codexScanCompletedFiles == corpusSize)
        #expect(secondCache.codexScanTotalFiles == corpusSize)
        #expect(secondCache.codexScanCatchUpPending == false)
    }

    @Test
    func `bounded queue rescans an appended cached complete path outside the first slice`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 2
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)
        let oldModificationDate = day.addingTimeInterval(-24 * 60 * 60)
        for fileURL in fileURLs {
            try FileManager.default.setAttributes(
                [.modificationDate: oldModificationDate],
                ofItemAtPath: fileURL.path)
        }

        var options = Self.boundedOptions(env: env)
        options.maxCodexScanDurationPerRefresh = nil
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let appendedURL = fileURLs[CostUsageScanner.codexCatchUpScanCandidateLimit]
        let incompleteURL = try #require(fileURLs.last)
        var pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let appendedPath = try #require(pendingCache.files.keys.first { $0.hasSuffix(appendedURL.lastPathComponent) })
        let incompletePath = try #require(pendingCache.files.keys
            .first { $0.hasSuffix(incompleteURL.lastPathComponent) })
        let beforeTotals = try #require(pendingCache.files[appendedPath]?.lastCountedTotals)
        #expect(beforeTotals.input == 100)
        #expect(beforeTotals.cached == 20)
        pendingCache.files[incompletePath]?.codexScanComplete = false
        pendingCache.codexActiveLookbackState = nil
        pendingCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: pendingCache)

        options.maxCodexScanDurationPerRefresh = 60
        let firstRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = firstRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let firstMetrics = firstRecorder.snapshot()
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(firstMetrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexProgressAccountingVisits == 0)
        #expect(firstCache.codexActiveLookbackState?.pendingFilePaths.count == 2)

        let iso = env.isoString(for: day.addingTimeInterval(2))
        let appendedLine = [
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#,
            #"{"total_token_usage":{"input_tokens":250,"cached_input_tokens":80,"output_tokens":30},"#,
            #""model":"openai/gpt-5.2-codex"}}}"#,
        ].joined()
        let handle = try FileHandle(forWritingTo: appendedURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLine + "\n").utf8))
        try handle.close()

        let secondRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = secondRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondMetrics = secondRecorder.snapshot()
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let afterTotals = try #require(secondCache.files[appendedPath]?.lastCountedTotals)
        #expect(secondMetrics.codexCandidateSelectionVisits == 2)
        #expect(secondMetrics.codexFileScanAttempts == 2)
        #expect(secondMetrics.codexProgressAccountingVisits == corpusSize)
        #expect(afterTotals.input == 250)
        #expect(afterTotals.cached == 80)
        #expect(afterTotals.output == 30)
        #expect(afterTotals != beforeTotals)
        #expect(secondCache.files[incompletePath]?.codexScanComplete == true)
        #expect(secondCache.codexActiveLookbackState == nil)
        #expect(secondCache.codexScanCompletedFiles == corpusSize)
        #expect(secondCache.codexScanTotalFiles == corpusSize)
        #expect(secondCache.codexScanCatchUpPending == false)
    }

    @Test
    func `exact validation requeues a completed prefix path rewritten after its slice`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 1
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)

        var options = Self.boundedOptions(env: env)
        options.maxCodexScanDurationPerRefresh = nil
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let rewrittenURL = fileURLs[0]
        let incompleteURL = try #require(fileURLs.last)
        var pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let rewrittenPath = try #require(pendingCache.files.keys.first { $0.hasSuffix(rewrittenURL.lastPathComponent) })
        let incompletePath = try #require(pendingCache.files.keys
            .first { $0.hasSuffix(incompleteURL.lastPathComponent) })
        pendingCache.files[incompletePath]?.codexScanComplete = false
        pendingCache.codexActiveLookbackState = nil
        pendingCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: pendingCache)

        options.maxCodexScanDurationPerRefresh = 60
        let firstRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = firstRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(firstRecorder.snapshot().codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstRecorder.snapshot().codexProgressAccountingVisits == 0)

        let original = try String(contentsOf: rewrittenURL, encoding: .utf8)
        let rewritten = original.replacingOccurrences(of: #""input_tokens":100"#, with: #""input_tokens":900"#)
        #expect(rewritten != original)
        #expect(rewritten.utf8.count == original.utf8.count)
        try rewritten.write(to: rewrittenURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: rewrittenURL.path)

        let secondRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = secondRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let secondMetrics = secondRecorder.snapshot()
        let secondCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(secondMetrics.codexCandidateSelectionVisits == 1)
        #expect(secondMetrics.codexFileScanAttempts == 1)
        #expect(secondMetrics.codexProgressAccountingVisits == corpusSize)
        #expect(secondCache.codexActiveLookbackState == nil)
        #expect(secondCache.codexScanCompletedFiles == corpusSize - 1)
        #expect(secondCache.codexScanInventoryPaths == nil)
        #expect(secondCache.codexScanCatchUpPending == true)

        let thirdRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = thirdRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        let thirdMetrics = thirdRecorder.snapshot()
        let thirdCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(thirdMetrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(thirdMetrics.codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(thirdMetrics.codexProgressAccountingVisits == 0)
        #expect(thirdCache.files[rewrittenPath]?.lastCountedTotals?.input == 900)
        #expect(thirdCache.codexActiveLookbackState?.pendingFilePaths.count == 1)
        #expect(thirdCache.codexScanCatchUpPending == true)

        let finalRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = finalRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        let finalMetrics = finalRecorder.snapshot()
        let finalCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(finalMetrics.codexCandidateSelectionVisits == 1)
        #expect(finalMetrics.codexFileScanAttempts == 1)
        #expect(finalMetrics.codexProgressAccountingVisits == corpusSize)
        #expect(finalCache.codexActiveLookbackState == nil)
        #expect(finalCache.codexScanCompletedFiles == corpusSize)
        #expect(finalCache.codexScanTotalFiles == corpusSize)
        #expect(finalCache.codexScanCatchUpPending == false)
    }

    @Test
    func `missing queue prefix advances after scanner validation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 1
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)

        var options = Self.boundedOptions(env: env)
        options.maxCodexScanDurationPerRefresh = nil
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let validURL = try #require(fileURLs.last)
        let validPath = try #require(pendingCache.files.keys.first { $0.hasSuffix(validURL.lastPathComponent) })
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()
        let missingURLs = fileURLs.prefix(CostUsageScanner.codexCatchUpScanCandidateLimit)
        for fileURL in missingURLs {
            try FileManager.default.removeItem(at: fileURL)
        }
        pendingCache.files[validPath]?.codexScanComplete = false
        pendingCache.codexScanInventoryPaths = nil
        pendingCache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(pendingCache.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: missingURLs.map(\.path.resolvingTemporaryPath) + [validURL.path.resolvingTemporaryPath])
        pendingCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: pendingCache)

        options.maxCodexScanDurationPerRefresh = 60
        let firstRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = firstRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let firstMetrics = firstRecorder.snapshot()
        let firstCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(firstMetrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(firstMetrics.codexProgressAccountingVisits == 0)
        #expect(firstCache.codexActiveLookbackState?.pendingFilePaths == [validURL.path.resolvingTemporaryPath])
        #expect(firstCache.codexScanCatchUpPending == true)

        let finalRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = finalRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let finalMetrics = finalRecorder.snapshot()
        let finalCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(finalMetrics.codexCandidateSelectionVisits == 1)
        #expect(finalMetrics.codexFileScanAttempts == 1)
        #expect(finalMetrics.codexProgressAccountingVisits == 1)
        #expect(finalCache.codexActiveLookbackState == nil)
        #expect(finalCache.codexScanCompletedFiles == 1)
        #expect(finalCache.codexScanTotalFiles == 1)
        #expect(finalCache.codexScanCatchUpPending == false)
    }

    @Test
    func `time budget stop retains selected paths that were not scanned`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 1
        let fileURLs = try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)

        var options = Self.boundedOptions(env: env)
        options.maxCodexScanDurationPerRefresh = nil
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let incompleteURL = try #require(fileURLs.last)
        let incompletePath = try #require(pendingCache.files.keys
            .first { $0.hasSuffix(incompleteURL.lastPathComponent) })
        pendingCache.files[incompletePath]?.codexScanComplete = false
        pendingCache.codexScanInventoryPaths = nil
        pendingCache.codexActiveLookbackState = nil
        pendingCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: pendingCache)

        options.maxCodexScanDurationPerRefresh = .leastNonzeroMagnitude
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let metrics = recorder.snapshot()
        let stoppedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(metrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(metrics.codexFileScanAttempts == 0)
        #expect(metrics.activeLookbackCompletionCandidates == 0)
        #expect(metrics.codexProgressAccountingVisits == 0)
        #expect(stoppedCache.codexActiveLookbackState?.pendingFilePaths.count == corpusSize)
        #expect(stoppedCache.files[incompletePath]?.codexScanComplete == false)
        #expect(stoppedCache.codexScanCatchUpPending == true)
    }

    @Test
    func `reset progress baseline counts validated cached snapshots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let corpusSize = CostUsageScanner.codexCatchUpScanCandidateLimit + 1
        try Self.writeSyntheticCorpus(env: env, day: day, fileCount: corpusSize)

        var options = Self.boundedOptions(env: env)
        options.maxCodexScanDurationPerRefresh = nil
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        for path in pendingCache.files.keys {
            pendingCache.files[path]?.codexCostCacheComplete = false
        }
        pendingCache.codexScanInventoryPaths = nil
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
        let migratedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(metrics.codexCandidateSelectionVisits == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(metrics.codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(metrics.codexProgressAccountingVisits == 0)
        #expect(migratedCache.codexScanCompletedFiles == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(migratedCache.codexScanTotalFiles == corpusSize)
        #expect(migratedCache.codexActiveLookbackState?.pendingFilePaths.count == 1)
        #expect(migratedCache.codexScanCatchUpPending == true)
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

    @discardableResult
    private static func writeSyntheticCorpus(
        env: CostUsageTestEnvironment,
        day: Date,
        fileCount: Int) throws -> [URL]
    {
        let iso = env.isoString(for: day)
        var fileURLs: [URL] = []
        fileURLs.reserveCapacity(fileCount)
        for index in 0..<fileCount {
            let lines = [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"progress-\#(index)"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ]
            try fileURLs.append(env.writeCodexSessionFile(
                day: day,
                filename: String(format: "progress-%04d.jsonl", index),
                contents: lines.joined(separator: "\n") + "\n"))
        }
        return fileURLs
    }
}

extension String {
    fileprivate var resolvingTemporaryPath: String {
        URL(fileURLWithPath: self).resolvingSymlinksInPath().standardizedFileURL.path
            .replacingOccurrences(of: "/private/var/", with: "/var/", options: [.anchored])
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
