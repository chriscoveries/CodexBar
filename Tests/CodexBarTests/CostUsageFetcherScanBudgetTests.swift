import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherScanBudgetTests {
    @Test
    func `automatic codex scan budget skips oversized cold cache`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        _ = try self.writeCodexSessionFile(env: env, day: day, tokens: 100)

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        await #expect(throws: CostUsageScanner.CodexScanBudgetExceeded.self) {
            _ = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: day,
                codexHomePath: env.codexHomeRoot.path,
                automaticCodexScanByteLimit: 1,
                scannerOptions: options)
        }

        let skippedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(skippedCache.files.isEmpty)

        let forced = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            forceRefresh: true,
            codexHomePath: env.codexHomeRoot.path,
            automaticCodexScanByteLimit: 1,
            scannerOptions: options)
        #expect(forced.sessionTokens == 100)
    }

    @Test
    func `automatic codex scan budget counts fork parent root lookup files`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let parentDay = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let childDay = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let parentTimestamp = env.isoString(for: parentDay.addingTimeInterval(1))
        _ = try self.writeCodexTotalSessionFile(
            env: env,
            day: parentDay,
            filename: "parent.jsonl",
            sessionID: "parent-session",
            tokens: 100)
        let childURL = try self.writeCodexTotalSessionFile(
            env: env,
            day: childDay,
            filename: "child.jsonl",
            sessionID: "child-session",
            forkedFromID: "parent-session",
            forkTimestamp: parentTimestamp,
            tokens: 125,
            output: 5)
        let childBytes = try Int64(childURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        let options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        await #expect(throws: CostUsageScanner.CodexScanBudgetExceeded.self) {
            _ = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: childDay,
                codexHomePath: env.codexHomeRoot.path,
                historyDays: 1,
                automaticCodexScanByteLimit: childBytes,
                scannerOptions: options)
        }

        let forced = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: childDay,
            forceRefresh: true,
            codexHomePath: env.codexHomeRoot.path,
            historyDays: 1,
            automaticCodexScanByteLimit: childBytes,
            scannerOptions: options)
        #expect(forced.sessionTokens == 30)
    }

    @Test
    func `automatic codex scan budget skips oversized incremental refresh`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let initialURL = try self.writeCodexSessionFile(env: env, day: day, filename: "initial.jsonl", tokens: 100)
        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let initial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            codexHomePath: env.codexHomeRoot.path,
            scannerOptions: options)
        #expect(initial.sessionTokens == 100)

        let initialBytes = try Int64(initialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        _ = try self.writeCodexSessionFile(env: env, day: day, filename: "new.jsonl", tokens: 50)

        await #expect(throws: CostUsageScanner.CodexScanBudgetExceeded.self) {
            _ = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: day.addingTimeInterval(90),
                codexHomePath: env.codexHomeRoot.path,
                automaticCodexScanByteLimit: initialBytes,
                scannerOptions: options)
        }
    }

    private func writeCodexSessionFile(
        env: CostUsageTestEnvironment,
        day: Date,
        filename: String = "large-enough.jsonl",
        tokens: Int) throws
        -> URL
    {
        try env.writeCodexSessionFile(day: day, filename: filename, contents: env.jsonl([
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": ["model": "openai/gpt-5.4"],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                        "model": "openai/gpt-5.4",
                    ],
                ],
            ],
        ]))
    }

    private func writeCodexTotalSessionFile(
        env: CostUsageTestEnvironment,
        day: Date,
        filename: String,
        sessionID: String,
        forkedFromID: String? = nil,
        forkTimestamp: String? = nil,
        tokens: Int,
        output: Int = 0) throws
        -> URL
    {
        var sessionPayload: [String: Any] = ["session_id": sessionID]
        if let forkedFromID {
            sessionPayload["forked_from_id"] = forkedFromID
        }
        if let forkTimestamp {
            sessionPayload["timestamp"] = forkTimestamp
        }

        return try env.writeCodexSessionFile(day: day, filename: filename, contents: env.jsonl([
            [
                "type": "session_meta",
                "timestamp": env.isoString(for: day),
                "payload": sessionPayload,
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "model": "openai/gpt-5.4",
                        "total_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": output,
                        ],
                    ],
                ],
            ],
        ]))
    }
}
