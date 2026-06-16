import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexLocalProjectUsageTests {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CodexLocalProjectUsageIndexProgress] = []

        func append(_ progress: CodexLocalProjectUsageIndexProgress) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.events.append(progress)
        }

        var snapshot: [CodexLocalProjectUsageIndexProgress] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.events
        }
    }

    private struct CodexUsageFixture {
        var filename: String
        var sessionID: String
        var cwd: String?
        var input: Int
        var cached: Int
        var output: Int
    }

    @Test
    func projectRootResolverKeepsSiblingPathsDistinct() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-project-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("app", isDirectory: true)
        let appOld = root.appendingPathComponent("app-old", isDirectory: true)
        let appSource = app.appendingPathComponent("Sources", isDirectory: true)
        let appOldSource = appOld.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: appOld.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appOldSource, withIntermediateDirectories: true)

        let appIdentity = CodexLocalProjectRootResolver.projectIdentity(for: appSource.path)
        let appOldIdentity = CodexLocalProjectRootResolver.projectIdentity(for: appOldSource.path)

        #expect(appIdentity.path == app.standardizedFileURL.path)
        #expect(appOldIdentity.path == appOld.standardizedFileURL.path)
        #expect(appIdentity.id != appOldIdentity.id)
    }

    @Test
    func projectRootResolverTreatsGitFileWorktreeAsMostSpecificProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-project-worktree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("app", isDirectory: true)
        let worktree = app.appendingPathComponent("worktree", isDirectory: true)
        let source = worktree.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "gitdir: ../.git/worktrees/worktree\n".write(
            to: worktree.appendingPathComponent(".git", isDirectory: false),
            atomically: true,
            encoding: .utf8)

        let identity = CodexLocalProjectRootResolver.projectIdentity(for: source.path)

        #expect(identity.path == worktree.standardizedFileURL.path)
        #expect(identity.displayName == "worktree")
    }

    @Test
    func projectRootResolverPreservesMissingLoggedCWDWhenNoGitRootExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-missing-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let loggedCWD = root.appendingPathComponent("deleted-project/Sources", isDirectory: true)

        let identity = CodexLocalProjectRootResolver.projectIdentity(for: loggedCWD.path)

        #expect(identity.path == loggedCWD.standardizedFileURL.path)
        #expect(identity.displayName == "Sources")
    }

    @Test
    func projectUsageIndexAggregatesProjectsAndChatsFromExistingCodexScanCache() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date()
        let project = env.root.appendingPathComponent("CodexBar", isDirectory: true)
        let projectSource = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSource, withIntermediateDirectories: true)

        try self.writeCodexUsageFile(
            env: env,
            day: day,
            fixture: CodexUsageFixture(
                filename: "project.jsonl",
                sessionID: "project-session",
                cwd: projectSource.path,
                input: 100,
                cached: 20,
                output: 30))
        try self.writeCodexUsageFile(
            env: env,
            day: day,
            fixture: CodexUsageFixture(
                filename: "chat.jsonl",
                sessionID: "chat-session",
                cwd: nil,
                input: 50,
                cached: 5,
                output: 10))

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let snapshot = try await CostUsageFetcher.loadCodexLocalProjectUsageSnapshot(
            now: day,
            forceRefresh: true,
            historyDays: 2,
            scannerOptions: options)

        #expect(snapshot.indexedFileCount == 2)
        #expect(snapshot.projects.map(\.displayName) == ["CodexBar", "Chats"])
        #expect(snapshot.projects.first?.totals.totalTokens == 130)
        #expect(snapshot.projects.first?.totals.cachedInputTokens == 20)
        #expect(snapshot.projects.first?.path == project.standardizedFileURL.path)
        #expect(snapshot.projects.first?.estimatedCostUSD != nil)
        #expect(snapshot.projects.first?.modelBreakdowns.first?.estimatedCostUSD != nil)
        #expect(snapshot.projects.first?.modelBreakdowns.first?.hasUnknownCost == false)
        #expect(snapshot.projects.last?.id == CodexLocalProjectRootResolver.chatsProjectId)
        #expect(snapshot.total.totalTokens == 190)
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.daily.first?.totalTokens == 190)
    }

    @Test
    func projectUsageIndexUsesCachedCodexSessionMetadataWithoutReadingJsonl() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date()
        let project = env.root.appendingPathComponent("CodexBar", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let fixture = CodexUsageFixture(
            filename: "missing.jsonl",
            sessionID: "cached-session",
            cwd: project.path,
            input: 100,
            cached: 20,
            output: 30)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let missingFileURL = env.root.appendingPathComponent("missing-session.jsonl", isDirectory: false)
        var cache = CostUsageCache()
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[missingFileURL.path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: fixture,
            costNanos: 1)
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let snapshot = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: day,
            historyDays: 1,
            since: day,
            until: day,
            options: options)

        #expect(FileManager.default.fileExists(atPath: missingFileURL.path) == false)
        #expect(snapshot.projects.count == 1)
        #expect(snapshot.projects.first?.displayName == "CodexBar")
        #expect(snapshot.projects.first?.path == project.standardizedFileURL.path)
        #expect(snapshot.projects.first?.totals.totalTokens == 130)
    }

    @Test
    func projectUsageIndexUsesCodexStateDatabaseCatalogWhenAvailable() throws {
        #if canImport(SQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let project = env.root.appendingPathComponent("CatalogProject", isDirectory: true)
        let projectSource = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSource, withIntermediateDirectories: true)

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let rolloutURL = env.codexSessionsRoot.appendingPathComponent("catalog-session.jsonl", isDirectory: false)
        let stateDatabaseURL = env.codexHomeRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        try self.writeCodexStateDatabase(
            at: stateDatabaseURL,
            thread: CodexStateThreadFixture(
                id: "catalog-session",
                rolloutPath: rolloutURL.path,
                cwd: projectSource.path,
                title: "Catalog title",
                preview: "Catalog preview",
                model: "openai/gpt-5.4-catalog",
                createdAtUnixMs: 1_800_000_000_000,
                updatedAtUnixMs: 1_800_000_120_000))

        var cache = CostUsageCache()
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[rolloutURL.path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: CodexUsageFixture(
                filename: "catalog-session.jsonl",
                sessionID: "catalog-session",
                cwd: nil,
                input: 100,
                cached: 10,
                output: 25),
            costNanos: 1)
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let snapshot = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: day,
            historyDays: 1,
            since: day,
            until: day,
            options: options)

        #expect(snapshot.projects.map(\.displayName) == ["CatalogProject"])
        #expect(snapshot.projects.first?.path == project.standardizedFileURL.path)
        #expect(snapshot.sessions.first?.displayTitle == "Catalog title")
        #expect(snapshot.sessions.first?.cwd == projectSource.path)
        #expect(snapshot.sessions.first?.latestActivity == Date(timeIntervalSince1970: 1_800_000_120))
        #expect(snapshot.sessions.first?.topModel == "openai/gpt-5.4-catalog")
        #expect(snapshot.total.totalTokens == 125)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func cachedProjectUsageSnapshotInvalidatesWhenCostCachePricingKeyChanges() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date()
        let project = env.root.appendingPathComponent("CodexBar", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let fixture = CodexUsageFixture(
            filename: "project.jsonl",
            sessionID: "cached-session",
            cwd: project.path,
            input: 100,
            cached: 20,
            output: 30)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        var cache = CostUsageCache()
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.codexPricingKey = "pricing-a"
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[env.root.appendingPathComponent("project.jsonl").path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: fixture,
            costNanos: 1)
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)
        let snapshot = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: day,
            historyDays: 1,
            since: day,
            until: day,
            options: options)
        CodexLocalProjectUsageIndexStore(cacheRoot: env.cacheRoot).saveSnapshot(snapshot)

        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(now: day, historyDays: 1, options: .init(
            scannerOptions: options)) != nil)

        cache.codexPricingKey = "pricing-b"
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(now: day, historyDays: 1, options: .init(
            scannerOptions: options)) == nil)
    }

    @Test
    func projectUsageSeveritySeparatesHighUsageFromUnknownCostCoverage() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date()
        let highProject = env.root.appendingPathComponent("high", isDirectory: true)
        let normalProject = env.root.appendingPathComponent("normal", isDirectory: true)
        let partialProject = env.root.appendingPathComponent("partial", isDirectory: true)
        for project in [highProject, normalProject, partialProject] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true)
        }
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        var cache = CostUsageCache()
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[env.root.appendingPathComponent("high.jsonl").path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: CodexUsageFixture(
                filename: "high.jsonl",
                sessionID: "high",
                cwd: highProject.path,
                input: 800,
                cached: 0,
                output: 200),
            costNanos: 1)
        cache.files[env.root.appendingPathComponent("normal.jsonl").path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: CodexUsageFixture(
                filename: "normal.jsonl",
                sessionID: "normal",
                cwd: normalProject.path,
                input: 80,
                cached: 0,
                output: 20),
            costNanos: 1)
        cache.files[env.root.appendingPathComponent("partial.jsonl").path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: CodexUsageFixture(
                filename: "partial.jsonl",
                sessionID: "partial",
                cwd: partialProject.path,
                input: 80,
                cached: 0,
                output: 20),
            costNanos: nil)
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let snapshot = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: day,
            historyDays: 1,
            since: day,
            until: day,
            options: options)
        let projectsByName = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.displayName, $0) })

        #expect(projectsByName["high"]?.severity == .high)
        #expect(projectsByName["normal"]?.severity == .normal)
        #expect(projectsByName["partial"]?.hasUnknownCost == true)
        #expect(projectsByName["partial"]?.severity == .normal)
    }

    @Test
    func projectUsageIndexDoesNotDowngradeKnownSessionProjectToChats() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date()
        let project = env.root.appendingPathComponent("CodexBar", isDirectory: true)
        let projectSource = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSource, withIntermediateDirectories: true)

        let projectFixture = CodexUsageFixture(
            filename: "a-project-fragment.jsonl",
            sessionID: "split-session",
            cwd: projectSource.path,
            input: 100,
            cached: 20,
            output: 30)
        let chatFixture = CodexUsageFixture(
            filename: "z-chat-fragment.jsonl",
            sessionID: "split-session",
            cwd: nil,
            input: 50,
            cached: 5,
            output: 10)
        let projectFileURL = try self.writeCodexUsageFile(
            env: env,
            day: day,
            fixture: projectFixture)
        let chatFileURL = try self.writeCodexUsageFile(
            env: env,
            day: day,
            fixture: chatFixture)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        var cache = CostUsageCache()
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[projectFileURL.path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: projectFixture,
            costNanos: 1)
        cache.files[chatFileURL.path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: chatFixture,
            costNanos: 1)
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let snapshot = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: day,
            historyDays: 1,
            since: day,
            until: day,
            options: options)

        #expect(snapshot.projects.count == 1)
        #expect(snapshot.projects.first?.displayName == "CodexBar")
        #expect(snapshot.projects.first?.path == project.standardizedFileURL.path)
        #expect(snapshot.projects.first?.sessionCount == 1)
        #expect(snapshot.projects.first?.totals.totalTokens == 190)
        #expect(snapshot.sessions.first?.projectId != CodexLocalProjectRootResolver.chatsProjectId)
    }

    @Test
    func projectUsageIndexReportsRemainingFileProgress() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date()
        let firstFixture = CodexUsageFixture(
            filename: "first.jsonl",
            sessionID: "first-session",
            cwd: nil,
            input: 100,
            cached: 20,
            output: 30)
        let secondFixture = CodexUsageFixture(
            filename: "second.jsonl",
            sessionID: "second-session",
            cwd: nil,
            input: 50,
            cached: 5,
            output: 10)
        let firstFileURL = try self.writeCodexUsageFile(env: env, day: day, fixture: firstFixture)
        let secondFileURL = try self.writeCodexUsageFile(env: env, day: day, fixture: secondFixture)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        var cache = CostUsageCache()
        cache.scanSinceKey = dayKey
        cache.scanUntilKey = dayKey
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[firstFileURL.path] = self.makeCachedFileUsage(dayKey: dayKey, fixture: firstFixture, costNanos: 1)
        cache.files[secondFileURL.path] = self.makeCachedFileUsage(dayKey: dayKey, fixture: secondFixture, costNanos: 1)
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        let recorder = ProgressRecorder()
        _ = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: day,
            historyDays: 1,
            since: day,
            until: day,
            options: options,
            progress: { progress in
                recorder.append(progress)
            })
        let events = recorder.snapshot

        #expect(events.first?.phase == .indexingProjects)
        #expect(events.first?.processedFileCount == 0)
        #expect(events.first?.totalFileCount == 2)
        #expect(events.last?.processedFileCount == 2)
        #expect(events.last?.totalFileCount == 2)
        #expect(events.last?.indexedFileCount == 2)
    }

    @Test
    func displayRankingTracksCachedInputSetting() {
        let settings = self.makeCodexOnlySettings()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let cacheHeavy = self.makeProject(
            id: "cache-heavy",
            name: "CacheHeavy",
            input: 1100,
            cached: 1000,
            output: 0)
        let uncached = self.makeProject(
            id: "uncached",
            name: "Uncached",
            input: 200,
            cached: 0,
            output: 0)

        settings.codexLocalProjectUsageIncludesCachedInput = true
        #expect(store.codexLocalProjectUsageRankedProjects([cacheHeavy, uncached]).map(\.id) == [
            "cache-heavy",
            "uncached",
        ])

        settings.codexLocalProjectUsageIncludesCachedInput = false
        #expect(store.codexLocalProjectUsageRankedProjects([cacheHeavy, uncached]).map(\.id) == [
            "uncached",
            "cache-heavy",
        ])
    }

    @Test
    func workspacesRowSubtitleStaysQuietExceptIndexingStaleAndFailureStates() {
        let settings = self.makeCodexOnlySettings()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        store.codexLocalProjectUsageSnapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date(),
            historyDays: 30,
            scopeSignature: "test",
            rootsFingerprint: [:],
            indexedFileCount: 0,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: [])
        #expect(store.codexLocalProjectUsageRowSubtitle == nil)

        store.codexLocalProjectUsageRefreshInFlight = true
        #expect(store.codexLocalProjectUsageRowSubtitle == "Indexing local Codex logs…")

        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(phase: .scanningLogs)
        #expect(store.codexLocalProjectUsageRowSubtitle == "Indexing local Codex logs…")
        #expect(store.codexLocalProjectUsageProgressSubtitle == "Scanning Codex logs…")

        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 10,
            totalFileCount: 25,
            indexedFileCount: 9,
            skippedFileCount: 1)
        #expect(store.codexLocalProjectUsageRowSubtitle == "Indexing local Codex logs…")
        #expect(store.codexLocalProjectUsageProgressSubtitle == "Indexing projects… 10/25 files, 15 left")
        #expect(store.codexLocalProjectUsageProgressFraction == 0.4)

        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 25,
            totalFileCount: 25,
            indexedFileCount: 24,
            skippedFileCount: 1)
        #expect(store.codexLocalProjectUsageRowSubtitle == "Indexing local Codex logs…")
        #expect(store.codexLocalProjectUsageProgressSubtitle == "Finalizing project index… 25 files")

        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(phase: .saving)
        #expect(store.codexLocalProjectUsageRowSubtitle == "Indexing local Codex logs…")
        #expect(store.codexLocalProjectUsageProgressSubtitle == "Saving project index…")

        store.codexLocalProjectUsageRefreshInFlight = false
        store.codexLocalProjectUsageProgress = nil
        store.codexLocalProjectUsageError = "boom"
        #expect(store.codexLocalProjectUsageRowSubtitle == "Failed to read Codex logs")

        store.codexLocalProjectUsageError = nil
        store.codexLocalProjectUsageSnapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date().addingTimeInterval(-(2 * 60 * 60 + 15 * 60)),
            historyDays: 30,
            scopeSignature: "test",
            rootsFingerprint: [:],
            indexedFileCount: 0,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: [])
        #expect(store.codexLocalProjectUsageRowSubtitle == "Updated 2h 15m ago")
    }

    @Test
    func rebuildProjectUsageIndexClearsSidecarAndForcesFreshScan() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let previousDay = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: previousDay)
        let day = try env.makeLocalNoon(
            year: try #require(components.year),
            month: try #require(components.month),
            day: try #require(components.day))
        let project = env.root.appendingPathComponent("CodexBar", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try self.writeCodexUsageFile(
            env: env,
            day: day,
            fixture: CodexUsageFixture(
                filename: "project.jsonl",
                sessionID: "project-session",
                cwd: project.path,
                input: 100,
                cached: 20,
                output: 30))

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let staleSnapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: day.addingTimeInterval(-3600),
            historyDays: 1,
            scopeSignature: "stale",
            rootsFingerprint: [:],
            indexedFileCount: 0,
            skippedFileCount: 0,
            total: CodexLocalUsageTotals(inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1),
            projects: [],
            daily: [])
        CodexLocalProjectUsageIndexStore(cacheRoot: env.cacheRoot).saveSnapshot(staleSnapshot)
        #expect(CodexLocalProjectUsageIndexStore(cacheRoot: env.cacheRoot).loadSnapshot()?.total.totalTokens == 1)

        let settings = self.makeCodexOnlySettings()
        settings.costUsageHistoryDays = 2
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: options),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        await store.rebuildCodexLocalProjectUsageIndex()

        #expect(store.codexLocalProjectUsageError == nil)
        #expect(store.codexLocalProjectUsageSnapshot?.total.totalTokens == 130)
        #expect(CodexLocalProjectUsageIndexStore(cacheRoot: env.cacheRoot).loadSnapshot()?.total.totalTokens == 130)
    }

    @discardableResult
    private func writeCodexUsageFile(
        env: CostUsageTestEnvironment,
        day: Date,
        fixture: CodexUsageFixture) throws
        -> URL
    {
        var turnPayload: [String: Any] = [
            "model": "openai/gpt-5.4",
        ]
        if let cwd = fixture.cwd {
            turnPayload["cwd"] = cwd
        }
        let objects: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": env.isoString(for: day),
                "payload": ["id": fixture.sessionID],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": turnPayload,
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": fixture.input,
                            "cached_input_tokens": fixture.cached,
                            "output_tokens": fixture.output,
                        ],
                        "model": "openai/gpt-5.4",
                    ],
                ],
            ],
        ]
        return try env.writeCodexSessionFile(day: day, filename: fixture.filename, contents: env.jsonl(objects))
    }

    private func makeCachedFileUsage(
        dayKey: String,
        fixture: CodexUsageFixture,
        costNanos: Int64?) -> CostUsageFileUsage
    {
        let model = "openai/gpt-5.4"
        return CostUsageFileUsage(
            mtimeUnixMs: 0,
            size: 0,
            days: [dayKey: [model: [fixture.input, fixture.cached, fixture.output]]],
            parsedBytes: nil,
            lastModel: model,
            lastTotals: nil,
            lastCountedTotals: nil,
            lastRawTotalsBaseline: nil,
            hasDivergentTotals: nil,
            lastCodexTurnID: nil,
            sessionId: fixture.sessionID,
            forkedFromId: nil,
            codexSession: CostUsageCodexSessionMetadata(
                sessionId: fixture.sessionID,
                forkedFromId: nil,
                cwd: fixture.cwd,
                title: nil,
                startedAtUnixMs: nil,
                latestActivityUnixMs: nil),
            codexCostNanos: costNanos.map { [dayKey: [model: $0]] },
            codexPrioritySurchargeNanos: nil,
            codexStandardCostNanos: nil,
            codexPriorityCostNanos: nil,
            codexStandardTokens: nil,
            codexPriorityTokens: nil,
            codexTurnIDs: nil,
            codexRows: nil,
            claudeRows: nil)
    }

    #if canImport(SQLite3)
    private struct CodexStateThreadFixture {
        var id: String
        var rolloutPath: String
        var cwd: String
        var title: String
        var preview: String
        var model: String
        var createdAtUnixMs: Int64
        var updatedAtUnixMs: Int64
    }

    private func writeCodexStateDatabase(at url: URL, thread: CodexStateThreadFixture) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "CodexLocalProjectUsageTests", code: 1)
        }
        defer { sqlite3_close(db) }
        try self.execSQLite(db, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            source TEXT NOT NULL,
            model_provider TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            sandbox_policy TEXT NOT NULL,
            approval_mode TEXT NOT NULL,
            tokens_used INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            model TEXT,
            reasoning_effort TEXT,
            created_at_ms INTEGER,
            updated_at_ms INTEGER,
            preview TEXT NOT NULL DEFAULT ''
        )
        """)
        var stmt: OpaquePointer?
        let insert = """
        INSERT INTO threads (
            id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
            sandbox_policy, approval_mode, tokens_used, archived, model, reasoning_effort,
            created_at_ms, updated_at_ms, preview
        ) VALUES (?, ?, ?, ?, 'codex', 'openai', ?, ?, 'workspace-write', 'never', 0, 0, ?, 'high', ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexLocalProjectUsageTests", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, thread.id, -1, transient)
        sqlite3_bind_text(stmt, 2, thread.rolloutPath, -1, transient)
        sqlite3_bind_int64(stmt, 3, thread.createdAtUnixMs / 1000)
        sqlite3_bind_int64(stmt, 4, thread.updatedAtUnixMs / 1000)
        sqlite3_bind_text(stmt, 5, thread.cwd, -1, transient)
        sqlite3_bind_text(stmt, 6, thread.title, -1, transient)
        sqlite3_bind_text(stmt, 7, thread.model, -1, transient)
        sqlite3_bind_int64(stmt, 8, thread.createdAtUnixMs)
        sqlite3_bind_int64(stmt, 9, thread.updatedAtUnixMs)
        sqlite3_bind_text(stmt, 10, thread.preview, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "CodexLocalProjectUsageTests", code: 3)
        }
    }

    private func execSQLite(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            sqlite3_free(error)
            throw NSError(domain: "CodexLocalProjectUsageTests", code: 4)
        }
    }
    #endif

    private func makeCodexOnlySettings() -> SettingsStore {
        let suite = "CodexLocalProjectUsageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true
        settings.codexLocalProjectUsageShowsEstimatedCost = true
        settings.codexLocalProjectUsageIncludesCachedInput = true
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        return settings
    }

    private func makeProject(
        id: String,
        name: String,
        input: Int,
        cached: Int,
        output: Int) -> CodexLocalProjectUsage
    {
        CodexLocalProjectUsage(
            id: id,
            displayName: name,
            path: "/tmp/\(name)",
            totals: CodexLocalUsageTotals(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                totalTokens: input + output),
            estimatedCostUSD: Double(input + output) / 1000,
            hasUnknownCost: false,
            sessionCount: 1,
            latestActivity: nil,
            topModel: "gpt-5.4",
            topSessions: [],
            modelBreakdowns: [])
    }
}
