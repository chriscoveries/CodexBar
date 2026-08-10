import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCatchUpCompletionTests {
    @Test
    func `bounded catch-up clears already complete files from a retained lookback queue`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "retained-complete.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"retained-complete"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ].joined(separator: "\n") + "\n")

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var staleCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()
        #expect(staleCache.files.count == 1)
        let path = try #require(staleCache.files.keys.first)
        var completedUsage = try #require(staleCache.files[path])
        let currentIdentity = try #require(completedUsage.codexScanFileId)
        let inode = try #require(currentIdentity.split(separator: ":").last)
        completedUsage.codexScanFileId = "0:\(inode)"
        #expect(completedUsage.codexScanFileId != currentIdentity)
        #expect(completedUsage.codexTokenIndexAnchor != nil)
        staleCache.files[path] = completedUsage
        staleCache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(staleCache.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: [path])
        staleCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: staleCache)

        let repairedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(repairedCache.codexActiveLookbackState == nil)
        #expect(repairedCache.codexScanCatchUpPending == false)
        #expect(repairedCache.codexScanProcessedBytes == repairedCache.codexScanTotalBytes)
        #expect(repairedCache.codexScanCompletedFiles == repairedCache.codexScanTotalFiles)
        #expect(repairedCache.files[path]?.codexScanFileId == currentIdentity)

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let completedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(recorder.snapshot().codexFileScanAttempts == 1)
        #expect(completedCache.codexActiveLookbackState == nil)
        #expect(completedCache.codexScanCatchUpPending == false)
        #expect(completedCache.files.count == 1)
        #expect(completedCache.files.values.first?.codexScanComplete == true)
    }
}
