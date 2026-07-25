import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
// Shared JSONL/SQLite fixtures make the attribution and sidecar assertions
// readable without duplicating test environments across several files.
// swiftlint:disable file_length
// swiftlint:disable type_body_length
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
    func `project root resolver keeps sibling paths distinct`() throws {
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
    func `local data scope avoids persisting raw Codex home paths`() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspaces-private-home", isDirectory: true)
        let scope = CodexLocalDataScope.resolve(options: CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true)))

        #expect(scope.codexHome == home.standardizedFileURL)
        #expect(scope.identifier.hasPrefix("codex-workspaces:"))
        #expect(!scope.identifier.contains(home.path))
    }

    @Test
    func `v10 cache remains untouched while v11 rebuilds and then refreshes incrementally`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date()
        let costCacheRoot = env.cacheRoot.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: costCacheRoot, withIntermediateDirectories: true)
        let v10URL = costCacheRoot.appendingPathComponent("codex-v10.json", isDirectory: false)
        let v10Bytes = Data("recoverable-v10-cursor".utf8)
        try v10Bytes.write(to: v10URL)
        let v11URL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(!FileManager.default.fileExists(atPath: v11URL.path))

        try self.writeCodexUsageFile(
            env: env,
            day: day,
            fixture: CodexUsageFixture(
                filename: "upgrade-first.jsonl",
                sessionID: "upgrade-first",
                cwd: env.root.path,
                input: 100,
                cached: 20,
                output: 30))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(first.data.first?.totalTokens == 130)
        #expect(try Data(contentsOf: v10URL) == v10Bytes)
        #expect(FileManager.default.fileExists(atPath: v11URL.path))
        #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files.count == 1)

        try self.writeCodexUsageFile(
            env: env,
            day: day,
            fixture: CodexUsageFixture(
                filename: "upgrade-second.jsonl",
                sessionID: "upgrade-second",
                cwd: env.root.path,
                input: 40,
                cached: 5,
                output: 10))
        let warmNow = Date().addingTimeInterval(1)
        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: warmNow,
            now: warmNow,
            options: options)

        #expect(warm.data.first?.totalTokens == 180)
        #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files.count == 2)
        #expect(try Data(contentsOf: v10URL) == v10Bytes)
    }

    @Test
    func `project root resolver treats git file worktree as most specific project`() throws {
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
    func `project root resolver preserves missing logged CWD when no git root exists`() throws {
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
    func `project root resolver preserves a deleted CWD below an existing repository`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("project", isDirectory: true)
        let deletedCWD = repository.appendingPathComponent("removed-worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)

        let identity = CodexLocalProjectRootResolver.projectIdentity(for: deletedCWD.path)

        #expect(identity.path == deletedCWD.standardizedFileURL.path)
        #expect(identity.displayName == "removed-worktree")
    }

    @Test
    func `project root resolver canonicalizes a live symlinked repository`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("project", isDirectory: true)
        let source = repository.appendingPathComponent("Sources", isDirectory: true)
        let symlink = root.appendingPathComponent("project-link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: repository.path)

        let direct = CodexLocalProjectRootResolver.projectIdentity(for: source.path)
        let linked = CodexLocalProjectRootResolver.projectIdentity(
            for: symlink.appendingPathComponent("Sources", isDirectory: true).path)

        #expect(linked.id == direct.id)
        #expect(linked.path == repository.standardizedFileURL.path)
    }

    @Test
    func `project usage index aggregates projects and chats from existing codex scan cache`() async throws {
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
        let legacyStore = CodexLocalProjectUsageIndexStore(cacheRoot: env.cacheRoot)
        legacyStore.saveSnapshot(CodexLocalProjectUsageSnapshot(
            updatedAt: day,
            historyDays: 2,
            scopeSignature: "legacy",
            rootsFingerprint: [:],
            indexedFileCount: 0,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: []))
        #expect(legacyStore.loadSnapshot() != nil)
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
        #expect(snapshot.projects.first?.daily.first?.totalTokens == 130)
        #expect(snapshot.projects.last?.id == CodexLocalProjectRootResolver.chatsProjectId)
        #expect(snapshot.projects.last?.daily.first?.totalTokens == 60)
        #expect(snapshot.total.totalTokens == 190)
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.daily.first?.totalTokens == 190)
        let allModels = try #require(snapshot.modelsAnalytics?.allWorkspaces)
        #if canImport(SQLite3) || canImport(CSQLite3)
        #expect(snapshot.sourceStatus == .catalogMissing)
        #expect(allModels.currentIsComplete == false)
        #expect(allModels.previousIsComplete == false)
        #else
        #expect(snapshot.sourceStatus == .complete)
        #expect(allModels.currentIsComplete == true)
        #expect(allModels.previousIsComplete == true)
        #endif
        #if canImport(SQLite3) || canImport(CSQLite3)
        #expect(legacyStore.loadSnapshot() == nil)
        #else
        #expect(legacyStore.loadSnapshot() != nil)
        #endif
    }

    @Test
    func `project usage index uses cached codex session metadata without reading jsonl`() throws {
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
    func `project usage index uses codex state database catalog when available`() throws {
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
    func `sidecar retains catalog metadata when a sparse rollout update arrives during catalog failure`() throws {
        #if canImport(SQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let rolloutURL = env.codexSessionsRoot.appendingPathComponent("retained-metadata.jsonl", isDirectory: false)
        let project = env.root.appendingPathComponent("RetainedCatalogProject", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try self.writeCodexStateDatabase(
            at: env.codexHomeRoot.appendingPathComponent("state_5.sqlite", isDirectory: false),
            thread: CodexStateThreadFixture(
                id: "retained-session",
                rolloutPath: rolloutURL.path,
                cwd: project.path,
                title: "Retained catalog title",
                preview: "Retained catalog preview",
                model: "openai/gpt-5.4-catalog",
                createdAtUnixMs: 1_800_000_000_000,
                updatedAtUnixMs: 1_800_000_120_000))

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let sparseFixture = CodexUsageFixture(
            filename: "retained-metadata.jsonl",
            sessionID: "retained-session",
            cwd: nil,
            input: 100,
            cached: 0,
            output: 20)
        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[rolloutURL.path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: sparseFixture,
            costNanos: 1)
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot)
        try sidecar.synchronizeSources(cache: cache, catalog: CodexThreadCatalogReader.load(options: options))

        var changedFixture = sparseFixture
        changedFixture.input = 110
        var changedUsage = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: changedFixture,
            costNanos: 1)
        changedUsage.mtimeUnixMs = 1
        cache.files[rolloutURL.path] = changedUsage
        try sidecar.synchronizeSources(cache: cache, catalog: .empty)

        let rehydrated = try sidecar.usageCache(roots: cache.roots ?? [:])
        let metadata = rehydrated.files[rolloutURL.path]?.codexSession
        #expect(metadata?.cwd == project.path)
        #expect(metadata?.title == "Retained catalog title")
        #expect(rehydrated.files[rolloutURL.path]?.days[dayKey]?["openai/gpt-5.4"]?[0] == 110)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `catalog reader distinguishes missing and corrupt state databases`() throws {
        #if canImport(SQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)

        #expect(CodexThreadCatalogReader.loadResult(options: options).completeness == .unavailable(.missing))

        let databaseURL = env.codexHomeRoot.appendingPathComponent("state_5.sqlite", isDirectory: false)
        try "not a SQLite database".write(to: databaseURL, atomically: true, encoding: .utf8)
        #expect(CodexThreadCatalogReader.loadResult(options: options).completeness == .unavailable(.corrupt))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `cached project usage snapshot preserves last complete data when pricing changes`() throws {
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
        let catalog = CodexThreadCatalogReader.load(options: options)
        try CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot).synchronize(
            snapshot: snapshot,
            cache: cache,
            catalog: catalog,
            rootsFingerprint: CostUsageScanner.codexRootsFingerprint(options: options))

        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(now: day, historyDays: 1, options: .init(
            scannerOptions: options)) != nil)

        cache.codexPricingKey = "pricing-b"
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: env.cacheRoot)

        #expect(CodexLocalProjectUsageIndexer.cachedSnapshot(now: day, historyDays: 1, options: .init(
            scannerOptions: options))?.total.totalTokens == 130)
    }

    @Test
    func `project usage severity separates high usage from unknown cost coverage`() throws {
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
        let projected = CodexLocalProjectUsageProjection(
            includesCachedInput: true,
            showsEstimatedCost: true)
            .rankedProjects(snapshot.projects)
        let projectsByName = Dictionary(uniqueKeysWithValues: projected.map { ($0.displayName, $0) })

        #expect(projectsByName["high"]?.severity == .high)
        #expect(projectsByName["normal"]?.severity == .normal)
        #expect(projectsByName["partial"]?.hasUnknownCost == true)
        #expect(projectsByName["partial"]?.severity == .normal)
        #expect(projectsByName["partial"]?.costEstimate.unknownTokens == 100)
    }

    @Test
    func `project usage index does not downgrade known session project to chats`() throws {
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
    func `project usage index reports remaining file progress`() throws {
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

    @Test
    func `workspace fingerprint covers sidecar semantics but not scanner cursors`() throws {
        let fixture = CodexUsageFixture(
            filename: "rollout.jsonl",
            sessionID: "fingerprint-session",
            cwd: "/tmp/fingerprint-project",
            input: 12,
            cached: 3,
            output: 4)
        let day = "2026-07-25"
        let baseline = self.makeCachedFileUsage(dayKey: day, fixture: fixture, costNanos: 42)
            .refreshingCodexWorkspaceUsageFingerprint()
        let fingerprint = try #require(baseline.codexWorkspaceContentFingerprint)

        var cursorOnly = baseline
        cursorOnly.lastRawTotalsWatermark = CostUsageCodexTotals(input: 1000, cached: 900, output: 100)
        #expect(cursorOnly.codexWorkspaceUsageFingerprintValue() == fingerprint)

        var changedDaily = baseline
        changedDaily.days[day]?["openai/gpt-5.4"] = [24, 6, 8]
        changedDaily = changedDaily.refreshingCodexWorkspaceUsageFingerprint()
        #expect(changedDaily.codexWorkspaceUsageFingerprintValue() != fingerprint)

        var changedCost = baseline
        changedCost.codexCostNanos?[day]?["openai/gpt-5.4"] = 84
        changedCost = changedCost.refreshingCodexWorkspaceUsageFingerprint()
        #expect(changedCost.codexWorkspaceUsageFingerprintValue() != fingerprint)

        var changedProject = baseline
        changedProject.projectPath = "/tmp/another-project"
        changedProject = changedProject.refreshingCodexWorkspaceUsageFingerprint()
        #expect(changedProject.codexWorkspaceUsageFingerprintValue() != fingerprint)
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

extension CodexLocalProjectUsageTests {
    @Test
    func `daily usage projection follows cached input setting`() {
        let point = CodexLocalUsageDailyPoint(
            day: "2026-07-12",
            totalTokens: 100,
            cachedInputTokens: 40,
            estimatedCostUSD: 1)
        let includeCache = CodexLocalProjectUsageProjection(includesCachedInput: true, showsEstimatedCost: true)
        let excludeCache = CodexLocalProjectUsageProjection(includesCachedInput: false, showsEstimatedCost: true)

        #expect(includeCache.displayedTokens(
            totalTokens: point.totalTokens,
            cachedInputTokens: point.cachedInputTokens) == 100)
        #expect(excludeCache.displayedTokens(
            totalTokens: point.totalTokens,
            cachedInputTokens: point.cachedInputTokens) == 60)
    }

    @Test
    func `ranking projects preserves daily usage`() throws {
        let daily = CodexLocalUsageDailyPoint(
            day: "2026-07-12",
            totalTokens: 100,
            cachedInputTokens: 40,
            estimatedCostUSD: 1)
        let project = CodexLocalProjectUsage(
            id: "project",
            displayName: "Project",
            path: "/tmp/Project",
            totals: CodexLocalUsageTotals(
                inputTokens: 80,
                cachedInputTokens: 40,
                outputTokens: 20,
                totalTokens: 100),
            costEstimate: CodexLocalCostEstimate(knownUSD: 1, unknownTokens: 0),
            sessionCount: 1,
            latestActivity: nil,
            topModel: "gpt-5.4",
            topSessions: [],
            modelBreakdowns: [],
            daily: [daily])
        let projection = CodexLocalProjectUsageProjection(
            includesCachedInput: true,
            showsEstimatedCost: true)

        let ranked = try #require(projection.rankedProjects([project]).first)
        #expect(ranked.daily == [daily])
    }

    @Test
    func `projection derives severity from displayed tokens not price`() {
        let projection = CodexLocalProjectUsageProjection(
            includesCachedInput: true,
            showsEstimatedCost: true)
        let dominant = self.makeProject(
            id: "dominant",
            name: "Dominant",
            input: 1000,
            cached: 0,
            output: 0)
        let costlySmall = CodexLocalProjectUsage(
            id: "costly-small",
            displayName: "CostlySmall",
            path: "/tmp/CostlySmall",
            totals: CodexLocalUsageTotals(
                inputTokens: 1,
                cachedInputTokens: 0,
                outputTokens: 0,
                totalTokens: 1),
            costEstimate: CodexLocalCostEstimate(knownUSD: 10000, unknownTokens: 0),
            sessionCount: 1,
            latestActivity: nil,
            topModel: "gpt-5.4",
            topSessions: [],
            modelBreakdowns: [])

        let ranked = projection.rankedProjects([costlySmall, dominant])
        #expect(ranked.map(\.id) == ["dominant", "costly-small"])
        #expect(ranked.first?.severity == .high)
        #expect(ranked.last?.severity == .normal)
    }

    @Test
    func `cost coverage retains the number of unpriced tokens`() {
        let estimate = CodexLocalCostEstimate(knownUSD: 2.5, unknownTokens: 37)

        #expect(estimate.coverage == .partial)
        #expect(estimate.knownUSD == 2.5)
        #expect(estimate.unknownTokens == 37)
    }

    @Test
    func `persisted projects exclude display severity`() throws {
        let project = CodexLocalProjectUsage(
            id: "project",
            displayName: "Project",
            path: "/tmp/project",
            totals: .empty,
            costEstimate: CodexLocalCostEstimate(knownUSD: 1, unknownTokens: 0),
            sessionCount: 1,
            latestActivity: nil,
            topModel: nil,
            topSessions: [],
            modelBreakdowns: [],
            usageSeverity: .high)

        let encoded = try JSONEncoder.codexLocalProjectUsage.encode(project)
        let json = try #require(String(data: encoded, encoding: .utf8))
        let decoded = try JSONDecoder.codexLocalProjectUsage.decode(CodexLocalProjectUsage.self, from: encoded)

        #expect(!json.contains("usageSeverity"))
        #expect(decoded.severity == .normal)
    }

    @Test
    func `snapshot ignores legacy process state without persisting it again`() throws {
        let snapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            historyDays: 30,
            scopeSignature: "scope",
            rootsFingerprint: ["sessions": 1],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: [])

        let encoded = try JSONEncoder.codexLocalProjectUsage.encode(snapshot)
        let currentJSON = try #require(String(data: encoded, encoding: .utf8))
        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject["stale"] = true
        legacyObject["indexing"] = true
        legacyObject["errorMessage"] = "previous refresh failed"
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder.codexLocalProjectUsage.decode(
            CodexLocalProjectUsageSnapshot.self,
            from: legacyData)

        #expect(decoded == snapshot)
        #expect(!currentJSON.contains("\"stale\""))
        #expect(!currentJSON.contains("\"indexing\""))
        #expect(!currentJSON.contains("\"errorMessage\""))
    }

    @Test
    func `snapshot persists source completeness and defaults legacy payloads to complete`() throws {
        let snapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            historyDays: 30,
            scopeSignature: "scope",
            rootsFingerprint: ["sessions": 1],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            daily: [],
            sourceStatus: .catalogLocked)

        let encoded = try JSONEncoder.codexLocalProjectUsage.encode(snapshot)
        let decoded = try JSONDecoder.codexLocalProjectUsage.decode(
            CodexLocalProjectUsageSnapshot.self,
            from: encoded)
        #expect(decoded.sourceStatus == .catalogLocked)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "sourceStatus")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder.codexLocalProjectUsage.decode(
            CodexLocalProjectUsageSnapshot.self,
            from: legacyData)
        #expect(decodedLegacy.sourceStatus == .complete)
    }

    @Test
    func `aggregate only snapshots are rejected until inspector detail is available`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dailyPoint = CodexLocalUsageDailyPoint(
            day: "2023-11-14",
            totalTokens: 100,
            estimatedCostUSD: 1)
        let totals = CodexLocalUsageTotals(
            inputTokens: 80,
            cachedInputTokens: 20,
            outputTokens: 20,
            totalTokens: 100)
        let incompleteProject = CodexLocalProjectUsage(
            id: "project",
            displayName: "Project",
            path: "/tmp/project",
            totals: totals,
            costEstimate: CodexLocalCostEstimate(knownUSD: 1, unknownTokens: 0),
            sessionCount: 1,
            latestActivity: now,
            topModel: "gpt-5.4",
            topSessions: [],
            modelBreakdowns: [])
        let incomplete = CodexLocalProjectUsageSnapshot(
            updatedAt: now,
            historyDays: 1,
            scopeSignature: "scope",
            rootsFingerprint: [:],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: totals,
            projects: [incompleteProject],
            daily: [])
        #expect(!incomplete.hasInspectorDetail)

        let session = CodexLocalSessionUsage(
            id: "session",
            projectId: "project",
            displayTitle: "Project session",
            cwd: "/tmp/project",
            startedAt: now,
            latestActivity: now,
            totals: totals,
            estimatedCostUSD: 1,
            hasUnknownCost: false,
            topModel: "gpt-5.4",
            daily: [dailyPoint])
        let completeProject = CodexLocalProjectUsage(
            id: "project",
            displayName: "Project",
            path: "/tmp/project",
            totals: totals,
            costEstimate: CodexLocalCostEstimate(knownUSD: 1, unknownTokens: 0),
            sessionCount: 1,
            latestActivity: now,
            topModel: "gpt-5.4",
            topSessions: [session],
            modelBreakdowns: [],
            daily: [dailyPoint])
        let complete = CodexLocalProjectUsageSnapshot(
            updatedAt: now,
            historyDays: 1,
            scopeSignature: "scope",
            rootsFingerprint: [:],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: totals,
            projects: [completeProject],
            sessions: [session],
            daily: [dailyPoint])
        #expect(complete.hasInspectorDetail)
    }

    @Test
    func `session daily attribution round trips and legacy payload defaults to empty`() throws {
        let daily = [
            CodexLocalUsageDailyPoint(
                day: "2026-07-12",
                totalTokens: 100,
                cachedInputTokens: 20,
                estimatedCostUSD: 1.25),
            CodexLocalUsageDailyPoint(
                day: "2026-07-13",
                totalTokens: 250,
                cachedInputTokens: 50,
                estimatedCostUSD: 2.5),
        ]
        let session = CodexLocalSessionUsage(
            id: "session",
            projectId: "project",
            displayTitle: "A chat spanning two days",
            cwd: "/tmp/project",
            startedAt: nil,
            latestActivity: nil,
            totals: CodexLocalUsageTotals(
                inputTokens: 280,
                cachedInputTokens: 70,
                outputTokens: 70,
                totalTokens: 350),
            estimatedCostUSD: 3.75,
            hasUnknownCost: false,
            topModel: "gpt-5.4",
            daily: daily)

        let encoded = try JSONEncoder.codexLocalProjectUsage.encode(session)
        let decoded = try JSONDecoder.codexLocalProjectUsage.decode(
            CodexLocalSessionUsage.self,
            from: encoded)
        #expect(decoded.daily == daily)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "daily")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedLegacy = try JSONDecoder.codexLocalProjectUsage.decode(
            CodexLocalSessionUsage.self,
            from: legacyData)
        #expect(decodedLegacy.daily.isEmpty)
    }

    @Test
    func `sidecar migrates version two additively and preserves the database`() throws {
        #if canImport(SQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let databaseDirectory = env.cacheRoot.appendingPathComponent("local-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let databaseURL = databaseDirectory.appendingPathComponent("codex-workspaces-v1.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        try self.execSQLite(database, """
        CREATE TABLE usage_rollouts (
            rollout_path TEXT PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            session_id TEXT,
            cwd TEXT,
            title TEXT,
            started_at_ms INTEGER,
            latest_activity_ms INTEGER,
            last_model TEXT,
            project_path TEXT,
            canonical_project_path TEXT,
            forked_from_id TEXT,
            is_present INTEGER NOT NULL DEFAULT 1,
            last_seen_generation TEXT NOT NULL
        );
        PRAGMA user_version = 2;
        """)
        sqlite3_close(database)

        try CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot).synchronizeSources(
            cache: CostUsageCache(),
            catalog: .empty)

        database = nil
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 5)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(database, "PRAGMA table_info(usage_rollouts)", -1, &statement, nil) == SQLITE_OK)
        var columnNames: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                columnNames.append(String(cString: text))
            }
        }
        sqlite3_finalize(statement)
        #expect(columnNames.contains("event_detail_complete"))
        #expect(columnNames.contains("source_mtime_ms"))
        #expect(columnNames.contains("content_fingerprint"))

        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='usage_events'",
            -1,
            &statement,
            nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(database, "PRAGMA table_info(usage_events)", -1, &statement, nil) == SQLITE_OK)
        columnNames = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                columnNames.append(String(cString: text))
            }
        }
        sqlite3_finalize(statement)
        #expect(columnNames.contains("reasoning_tokens"))

        statement = nil
        #expect(sqlite3_prepare_v2(database, "PRAGMA table_info(snapshot_payloads)", -1, &statement, nil) == SQLITE_OK)
        columnNames = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                columnNames.append(String(cString: text))
            }
        }
        sqlite3_finalize(statement)
        #expect(columnNames.contains("payload_format_version"))

        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type='index' AND name='catalog_threads_rollout'",
            -1,
            &statement,
            nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            """
            EXPLAIN QUERY PLAN
            SELECT r.rollout_path
            FROM usage_rollouts r
            LEFT JOIN catalog_threads c ON c.id = r.session_id OR c.rollout_path = r.rollout_path
            JOIN usage_daily d ON d.rollout_path = r.rollout_path
            """,
            -1,
            &statement,
            nil) == SQLITE_OK)
        var planDetails: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3) {
                planDetails.append(String(cString: text))
            }
        }
        sqlite3_finalize(statement)
        #expect(planDetails.contains { $0.contains("catalog_threads_rollout") })
        #endif
    }

    @Test
    func `sidecar migrates version three event rows with nullable reasoning`() throws {
        #if canImport(SQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let databaseDirectory = env.cacheRoot.appendingPathComponent("local-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let databaseURL = databaseDirectory.appendingPathComponent("codex-workspaces-v1.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        try self.execSQLite(database, """
        CREATE TABLE usage_events (
            rollout_path TEXT NOT NULL,
            event_index INTEGER NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            day TEXT NOT NULL,
            canonical_model TEXT NOT NULL,
            raw_model TEXT,
            turn_id TEXT,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            known_cost_nanos INTEGER,
            unpriced_tokens INTEGER NOT NULL,
            pricing_model TEXT,
            pricing_mode TEXT,
            PRIMARY KEY (rollout_path, event_index)
        );
        PRAGMA user_version = 3;
        """)
        sqlite3_close(database)

        try CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot).synchronizeSources(
            cache: CostUsageCache(),
            catalog: .empty)

        database = nil
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 5)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(database, "PRAGMA table_info(usage_events)", -1, &statement, nil) == SQLITE_OK)
        var columnNames: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                columnNames.append(String(cString: text))
            }
        }
        sqlite3_finalize(statement)
        #expect(columnNames.contains("reasoning_tokens"))
        #endif
    }

    @Test
    func `sidecar migrates version four rows to explicit source identities`() throws {
        #if canImport(SQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let databaseDirectory = env.cacheRoot.appendingPathComponent("local-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let databaseURL = databaseDirectory.appendingPathComponent("codex-workspaces-v1.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        try self.execSQLite(database, """
        CREATE TABLE usage_rollouts (
            rollout_path TEXT PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            session_id TEXT,
            cwd TEXT,
            title TEXT,
            started_at_ms INTEGER,
            latest_activity_ms INTEGER,
            last_model TEXT,
            project_path TEXT,
            canonical_project_path TEXT,
            forked_from_id TEXT,
            event_detail_complete INTEGER NOT NULL DEFAULT 0,
            is_present INTEGER NOT NULL DEFAULT 1,
            last_seen_generation TEXT NOT NULL
        );
        CREATE TABLE usage_daily (
            rollout_path TEXT NOT NULL,
            day TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cost_nanos INTEGER,
            standard_tokens INTEGER,
            priority_tokens INTEGER,
            standard_cost_nanos INTEGER,
            priority_cost_nanos INTEGER,
            priority_surcharge_nanos INTEGER,
            PRIMARY KEY (rollout_path, day, model)
        );
        INSERT INTO usage_rollouts (rollout_path, fingerprint, last_seen_generation)
        VALUES ('legacy.jsonl', 'legacy', 'generation');
        INSERT INTO usage_daily (rollout_path, day, model, input_tokens, cached_input_tokens, output_tokens)
        VALUES ('legacy.jsonl', '2026-07-25', 'model', 1, 0, 1);
        PRAGMA user_version = 4;
        """)
        sqlite3_close(database)

        try CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot).synchronizeSources(
            cache: CostUsageCache(),
            catalog: .empty)

        database = nil
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 5)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM usage_rollouts", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 1)
        sqlite3_finalize(statement)

        statement = nil
        #expect(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM usage_daily", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 1)
        sqlite3_finalize(statement)
        #endif
    }

    @Test
    func `aggregate models analytics preserves priced zero and unavailable coverage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = Date()
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: now)
        let project = env.root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let pricedFixture = CodexUsageFixture(
            filename: "priced.jsonl",
            sessionID: "priced-fallback",
            cwd: project.path,
            input: 10,
            cached: 0,
            output: 0)
        let unavailableFixture = CodexUsageFixture(
            filename: "unavailable.jsonl",
            sessionID: "unavailable-fallback",
            cwd: project.path,
            input: 20,
            cached: 0,
            output: 0)
        var unavailableUsage = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: unavailableFixture,
            costNanos: nil)
        let unavailableModel = "openai/gpt-5.4-mini"
        unavailableUsage.days = [dayKey: [unavailableModel: [20, 0, 0]]]
        unavailableUsage.lastModel = unavailableModel

        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[env.root.appendingPathComponent("priced.jsonl").path] = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: pricedFixture,
            costNanos: 0)
        cache.files[env.root.appendingPathComponent("unavailable.jsonl").path] = unavailableUsage

        let snapshot = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: now,
            historyDays: 1,
            since: now,
            until: now,
            options: options,
            cacheOverride: cache,
            catalogOverride: .empty)
        let analytics = try #require(snapshot.modelsAnalytics?.allWorkspaces)
        let priced = try #require(analytics.rows.first { $0.id == "gpt-5.4" })
        let unavailable = try #require(analytics.rows.first { $0.id == "gpt-5.4-mini" })

        #expect(priced.cost.knownAmount == 0)
        #expect(priced.cost.pricedTokens == 10)
        #expect(priced.cost.unpricedTokens == 0)
        #expect(unavailable.cost.knownAmount == 0)
        #expect(unavailable.cost.pricedTokens == 0)
        #expect(unavailable.cost.unpricedTokens == 20)
        #expect(analytics.cost.knownAmount == 0)
        #expect(analytics.cost.pricedTokens == 10)
        #expect(analytics.cost.unpricedTokens == 20)
        #expect(analytics.diagnostics.isMatched)
    }

    @Test
    func `sidecar rehydrates cache-backed project aggregates`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let now = Date()
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: now)
        let project = env.root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        let path = env.root.appendingPathComponent("rollout.jsonl").path
        let fixture = CodexUsageFixture(
            filename: "rollout.jsonl",
            sessionID: "sidecar-session",
            cwd: project.path,
            input: 120,
            cached: 20,
            output: 30)
        var cache = CostUsageCache()
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        var cachedUsage = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: fixture,
            costNanos: 42)
        cachedUsage.codexRows = [CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: "openai/gpt-5.4",
            rawModel: "GPT-5.4",
            turnID: "turn-1",
            eventIndex: 0,
            timestampUnixMs: Int64(now.timeIntervalSince1970 * 1000),
            input: fixture.input,
            cached: fixture.cached,
            output: fixture.output,
            reasoning: 12,
            knownCostNanos: 42,
            unpricedTokens: 0,
            pricingModel: "openai/gpt-5.4",
            pricingMode: "standard")]
        cache.files[path] = cachedUsage
        let catalog = CodexThreadCatalog.empty
        let baseline = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: now,
            historyDays: 1,
            since: now,
            until: now,
            options: options,
            cacheOverride: cache,
            catalogOverride: catalog)
        let baselineModel = try #require(baseline.modelsAnalytics?.allWorkspaces.rows.first)
        let expectedKnownCost = try #require(Decimal(string: "0.000000042"))
        #expect(baselineModel.reasoningTokens == 12)
        #expect(baselineModel.cost.knownAmount == expectedKnownCost)
        #expect(baselineModel.cost.pricedTokens == Int64(fixture.input + fixture.output))
        #expect(baselineModel.cost.unpricedTokens == 0)
        #expect(baseline.modelsAnalytics?.allWorkspaces.diagnostics.isMatched == true)
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot)
        try sidecar.synchronize(
            snapshot: baseline,
            cache: cache,
            catalog: catalog,
            rootsFingerprint: cache.roots ?? [:])
        #if canImport(SQLite3)
        let sidecarURL = env.cacheRoot
            .appendingPathComponent("local-usage", isDirectory: true)
            .appendingPathComponent("codex-workspaces-v1.sqlite", isDirectory: false)
        var database: OpaquePointer?
        #expect(sqlite3_open(sidecarURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            database,
            "SELECT payload_format_version, payload FROM snapshot_payloads",
            -1,
            &statement,
            nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 3)
        let numericPayloadBytes = try #require(sqlite3_column_blob(statement, 1))
        let numericPayload = Data(
            bytes: numericPayloadBytes,
            count: Int(sqlite3_column_bytes(statement, 1)))
        sqlite3_finalize(statement)
        let numericObject = try #require(JSONSerialization.jsonObject(with: numericPayload) as? [String: Any])
        #expect(numericObject["updatedAt"] is NSNumber)

        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            "UPDATE snapshot_payloads SET payload_format_version = 2 WHERE scope_signature = ? AND history_days = ?",
            -1,
            &statement,
            nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, baseline.scopeSignature, -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(baseline.historyDays))
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        #expect(sidecar.loadLatestSnapshot(
            scopeSignature: baseline.scopeSignature,
            historyDays: baseline.historyDays) == nil)
        #expect(try sidecar.usageCache(roots: cache.roots ?? [:]).files[path]?.codexRows?.first?.knownCostNanos == 42)
        try sidecar.synchronize(
            snapshot: baseline,
            cache: cache,
            catalog: catalog,
            rootsFingerprint: cache.roots ?? [:])
        statement = nil
        #expect(sqlite3_prepare_v2(
            database,
            "SELECT payload_format_version FROM snapshot_payloads",
            -1,
            &statement,
            nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 3)
        sqlite3_finalize(statement)
        #expect(sidecar.loadLatestSnapshot(
            scopeSignature: baseline.scopeSignature,
            historyDays: baseline.historyDays)?.total == baseline.total)
        #endif
        let rehydratedCache = try sidecar.usageCache(roots: cache.roots ?? [:])
        let rehydratedEvent = try #require(rehydratedCache.files[path]?.codexRows?.first)
        let rehydrated = try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: now,
            historyDays: 1,
            since: now,
            until: now,
            options: options,
            cacheOverride: rehydratedCache,
            catalogOverride: catalog)

        #expect(rehydrated.total == baseline.total)
        #expect(rehydrated.projects.map(\.id) == baseline.projects.map(\.id))
        #expect(rehydrated.projects.first?.costEstimate == baseline.projects.first?.costEstimate)
        #expect(rehydratedEvent.rawModel == "GPT-5.4")
        #expect(rehydratedEvent.timestampUnixMs == Int64(now.timeIntervalSince1970 * 1000))
        #expect(rehydratedEvent.reasoning == 12)
        #expect(rehydratedEvent.knownCostNanos == 42)
        #expect(rehydratedEvent.pricingMode == "standard")
        let rehydratedModel = try #require(rehydrated.modelsAnalytics?.allWorkspaces.rows.first)
        #expect(rehydratedModel.reasoningTokens == 12)
        #expect(rehydratedModel.cost.knownAmount == expectedKnownCost)
        #expect(rehydratedModel.cost.pricedTokens == Int64(fixture.input + fixture.output))
        #expect(rehydratedModel.cost.unpricedTokens == 0)
        #expect(rehydrated.modelsAnalytics?.allWorkspaces.diagnostics.isMatched == true)
    }

    @Test
    func `sidecar refreshes changed usage when rollout metadata is unchanged`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: Date())
        let path = env.root.appendingPathComponent("rollout.jsonl").path
        let fixture = CodexUsageFixture(
            filename: "rollout.jsonl",
            sessionID: "sidecar-content-change",
            cwd: env.root.path,
            input: 120,
            cached: 20,
            output: 30)
        var cache = CostUsageCache()
        let timestampUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        var initialUsage = self.makeCachedFileUsage(
            dayKey: dayKey,
            fixture: fixture,
            costNanos: 42)
        initialUsage.codexRows = [CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: "openai/gpt-5.4",
            rawModel: "GPT-5.4",
            turnID: "turn-1",
            eventIndex: 0,
            timestampUnixMs: timestampUnixMs,
            input: 120,
            cached: 20,
            output: 30,
            knownCostNanos: 42,
            unpricedTokens: 0,
            pricingModel: "openai/gpt-5.4",
            pricingMode: "standard")]
        initialUsage = initialUsage.refreshingCodexWorkspaceUsageFingerprint()
        cache.files[path] = initialUsage
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: env.cacheRoot)
        try sidecar.synchronizeSources(cache: cache, catalog: .empty)

        let model = "openai/gpt-5.4"
        var changedUsage = try #require(cache.files[path])
        changedUsage.days[dayKey]?[model] = [240, 40, 60]
        changedUsage.codexCostNanos?[dayKey]?[model] = 84
        changedUsage.codexRows = [CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: model,
            rawModel: "GPT-5.4",
            turnID: "turn-1",
            eventIndex: 0,
            timestampUnixMs: timestampUnixMs,
            input: 240,
            cached: 40,
            output: 60,
            knownCostNanos: 84,
            unpricedTokens: 0,
            pricingModel: model,
            pricingMode: "priority")]
        changedUsage = changedUsage.refreshingCodexWorkspaceUsageFingerprint()
        cache.files[path] = changedUsage
        try sidecar.synchronizeSources(cache: cache, catalog: .empty)

        let updated = try #require(sidecar.usageCache(roots: [:]).files[path])
        #expect(updated.days[dayKey]?[model] == [240, 40, 60])
        #expect(updated.codexCostNanos?[dayKey]?[model] == 84)
        #expect(updated.codexRows?.first?.input == 240)
        #expect(updated.codexRows?.first?.knownCostNanos == 84)
        #expect(updated.codexRows?.first?.pricingMode == "priority")

        changedUsage.days = [:]
        changedUsage.codexCostNanos = [:]
        changedUsage.codexRows = []
        changedUsage = changedUsage.refreshingCodexWorkspaceUsageFingerprint()
        cache.files[path] = changedUsage
        try sidecar.synchronizeSources(cache: cache, catalog: .empty)

        #expect(try sidecar.usageCache(roots: [:]).files[path] == nil)
    }
}

// swiftlint:enable type_body_length
