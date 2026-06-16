import Foundation

enum CodexLocalProjectUsageIndexer {
    enum IndexError: Error, Equatable {
        case cacheScopeMismatch
    }

    struct Options: Sendable {
        var scannerOptions: CostUsageScanner.Options

        init(scannerOptions: CostUsageScanner.Options = CostUsageScanner.Options()) {
            self.scannerOptions = scannerOptions
        }
    }

    static func cachedSnapshot(
        now: Date = Date(),
        historyDays: Int = 30,
        options: Options = Options()) -> CodexLocalProjectUsageSnapshot?
    {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let stableScopeSignature = self.stableScopeSignature(options: options.scannerOptions)
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: options.scannerOptions.cacheRoot)
        if let snapshot = sidecar.loadLatestSnapshot(
            scopeSignature: stableScopeSignature,
            historyDays: clampedHistoryDays)
        {
            return snapshot
        }

        // Compatibility only: pre-sidecar builds persisted a JSON snapshot. It is
        // never written again; the next successful refresh publishes the sidecar.
        let indexStore = CodexLocalProjectUsageIndexStore(cacheRoot: options.scannerOptions.cacheRoot)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: options.scannerOptions.cacheRoot)
        let catalog = CodexThreadCatalogReader.load(options: options.scannerOptions)
        let scopeSignature = self.scopeSignature(
            options: options.scannerOptions,
            cache: cache,
            catalogFingerprint: catalog.fingerprint)
        return indexStore.loadSnapshot(
            expectedScopeSignature: scopeSignature,
            expectedHistoryDays: clampedHistoryDays)
    }

    static func loadSnapshot(
        now: Date = Date(),
        historyDays: Int = 30,
        forceRefresh: Bool = false,
        options: Options = Options(),
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CodexLocalProjectUsageSnapshot
    {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let until = now
        let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now
        var scannerOptions = options.scannerOptions
        if forceRefresh {
            scannerOptions.refreshMinIntervalSeconds = 0
        }

        progress?(CodexLocalProjectUsageIndexProgress(phase: .scanningLogs))
        _ = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: until,
            now: now,
            options: scannerOptions,
            checkCancellation: checkCancellation)
        try checkCancellation?()

        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: scannerOptions.cacheRoot)
        let catalogResult = CodexThreadCatalogReader.loadResult(options: scannerOptions)
        let catalog = catalogResult.catalog
        let sourceStatus = CodexLocalProjectUsageSourceStatus(catalog: catalogResult.completeness)
        let rootsFingerprint = self.rootsFingerprint(CostUsageScanner.codexRootsFingerprint(options: scannerOptions))
        let sidecar = CodexWorkspaceUsageSidecar(cacheRoot: scannerOptions.cacheRoot)
        if !forceRefresh {
            if let snapshot = sidecar.loadLatestSnapshot(
                scopeSignature: self.stableScopeSignature(options: scannerOptions),
                historyDays: clampedHistoryDays,
                rootsFingerprint: rootsFingerprint,
                cache: cache,
                catalog: catalogResult.isComplete ? catalog : nil)
            {
                return snapshot
            }
        }

        // Import only scanner-derived deltas, then aggregate from the
        // sidecar's normalized rows. The raw cache remains the cursor and
        // cumulative-token authority; it is no longer the aggregation source.
        try sidecar.synchronizeSources(cache: cache, catalog: catalog)
        let sidecarCache = try sidecar.usageCache(roots: rootsFingerprint)
        let snapshot = try self.buildSnapshotFromCostCache(
            now: now,
            historyDays: clampedHistoryDays,
            since: since,
            until: until,
            options: scannerOptions,
            cacheOverride: sidecarCache,
            catalogOverride: catalog,
            sourceStatus: sourceStatus,
            progress: progress,
            checkCancellation: checkCancellation)
        progress?(CodexLocalProjectUsageIndexProgress(phase: .saving))
        try sidecar.synchronize(
            snapshot: snapshot,
            cache: cache,
            catalog: catalog,
            rootsFingerprint: rootsFingerprint)
        #if canImport(SQLite3) || canImport(CSQLite3)
        // The sidecar commit is now the durable source of the last complete
        // snapshot. Retain the legacy JSON only until that commit succeeds so
        // a stale pre-sidecar payload cannot be resurrected later.
        CodexLocalProjectUsageIndexStore(cacheRoot: scannerOptions.cacheRoot).clear()
        #endif
        return snapshot
    }

    static func buildSnapshotFromCostCache(
        now: Date = Date(),
        historyDays: Int = 30,
        since: Date,
        until: Date,
        options: CostUsageScanner.Options = CostUsageScanner.Options(),
        cacheOverride: CostUsageCache? = nil,
        catalogOverride: CodexThreadCatalog? = nil,
        sourceStatus: CodexLocalProjectUsageSourceStatus = .complete,
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CodexLocalProjectUsageSnapshot
    {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until)
        let cache = cacheOverride ?? CostUsageCacheIO.load(provider: .codex, cacheRoot: options.cacheRoot)
        let catalog = catalogOverride ?? CodexThreadCatalogReader.load(options: options)
        let expectedRoots = CostUsageScanner.codexRootsFingerprint(options: options)
        let scopeSignature = self.stableScopeSignature(options: options)
        let rootsFingerprint = self.rootsFingerprint(expectedRoots)

        guard cache.roots == expectedRoots else {
            // The cost cache belongs to a different Codex home. Publishing an
            // empty replacement would erase a still-valid last-complete view.
            throw IndexError.cacheScopeMismatch
        }

        let indexed = try self.sessionBuckets(
            from: cache,
            range: range,
            catalog: catalog,
            progress: progress,
            checkCancellation: checkCancellation)
        let indexedFiles = indexed.indexedFiles
        let skippedFiles = indexed.skippedFiles
        let sessionBuckets = indexed.sessionBuckets

        let sessions = sessionBuckets.values.map { bucket in
            CodexLocalSessionUsage(
                id: bucket.id,
                projectId: bucket.projectId,
                displayTitle: self.sessionTitle(
                    explicitTitle: bucket.title,
                    startedAt: bucket.startedAt,
                    latestActivity: bucket.latestActivity,
                    model: bucket.topModel),
                cwd: bucket.cwd,
                startedAt: bucket.startedAt,
                latestActivity: bucket.latestActivity,
                totals: bucket.total,
                costEstimate: CodexLocalCostEstimate(
                    knownUSD: self.usd(fromNanos: bucket.costNanos) ?? 0,
                    unknownTokens: bucket.unknownCostTokens),
                topModel: bucket.displayModel,
                daily: self.dailyPoints(from: bucket.dailyTotals))
        }.sorted { lhs, rhs in
            self.sortSessions(lhs, rhs)
        }

        let projectBuckets = Dictionary(grouping: sessionBuckets.values, by: \.projectId)
        let rawProjects = projectBuckets.values.map { buckets in
            let sortedSessions = buckets.map { bucket in
                CodexLocalSessionUsage(
                    id: bucket.id,
                    projectId: bucket.projectId,
                    displayTitle: self.sessionTitle(
                        explicitTitle: bucket.title,
                        startedAt: bucket.startedAt,
                        latestActivity: bucket.latestActivity,
                        model: bucket.topModel),
                    cwd: bucket.cwd,
                    startedAt: bucket.startedAt,
                    latestActivity: bucket.latestActivity,
                    totals: bucket.total,
                    costEstimate: CodexLocalCostEstimate(
                        knownUSD: self.usd(fromNanos: bucket.costNanos) ?? 0,
                        unknownTokens: bucket.unknownCostTokens),
                    topModel: bucket.displayModel,
                    daily: self.dailyPoints(from: bucket.dailyTotals))
            }.sorted { lhs, rhs in
                self.sortSessions(lhs, rhs)
            }
            var total = CodexLocalUsageTotals.empty
            var costNanos: Int64?
            var unknownCostTokens = 0
            var latestActivity: Date?
            var modelTotals: [String: ModelTotals] = [:]
            var dailyTotals: [String: DailyTotals] = [:]
            for bucket in buckets {
                total = total.adding(bucket.total)
                costNanos = self.addCost(costNanos, bucket.costNanos)
                unknownCostTokens += bucket.unknownCostTokens
                latestActivity = self.later(latestActivity, bucket.latestActivity)
                for (day, daily) in bucket.dailyTotals {
                    self.mergeDailyTotals(&dailyTotals, day: day, totals: daily)
                }
                for (model, totals) in bucket.modelTotals {
                    self.mergeModelTotals(&modelTotals, model: model, totals: totals)
                }
            }
            let first = buckets[0]
            return CodexLocalProjectUsage(
                id: first.projectId,
                displayName: first.projectDisplayName,
                path: first.projectPath,
                totals: total,
                costEstimate: CodexLocalCostEstimate(
                    knownUSD: self.usd(fromNanos: costNanos) ?? 0,
                    unknownTokens: unknownCostTokens),
                sessionCount: buckets.count,
                latestActivity: latestActivity,
                topModel: self.topModel(from: modelTotals),
                topSessions: Array(sortedSessions.prefix(5)),
                modelBreakdowns: self.modelBreakdowns(from: modelTotals),
                daily: self.dailyPoints(from: dailyTotals))
        }.sorted { lhs, rhs in
            self.sortProjects(lhs, rhs)
        }
        let projects = rawProjects

        return CodexLocalProjectUsageSnapshot(
            updatedAt: now,
            historyDays: clampedHistoryDays,
            scopeSignature: scopeSignature,
            rootsFingerprint: rootsFingerprint,
            indexedFileCount: indexedFiles,
            skippedFileCount: skippedFiles,
            total: self.total(from: projects),
            projects: projects,
            sessions: sessions,
            modelBreakdowns: self.globalModelBreakdowns(from: sessionBuckets.values),
            daily: self.dailyPoints(from: cache.files.values, range: range),
            sourceStatus: sourceStatus)
    }
}

extension CodexLocalProjectUsageIndexer {
    fileprivate struct FileTotals {
        var totals: CodexLocalUsageTotals
        var costNanos: Int64?
        var unknownCostTokens: Int
        var modelTotals: [String: ModelTotals]
        var dailyTotals: [String: DailyTotals]
        var topModel: String?
    }

    fileprivate struct DailyTotals {
        var totalTokens: Int
        var cachedInputTokens: Int
        var costNanos: Int64?
        var unknownCostTokens: Int
    }

    fileprivate struct ModelTotals {
        var totalTokens: Int
        var costNanos: Int64?
        var unknownCostTokens: Int
    }

    fileprivate struct SessionBucket {
        var id: String
        var projectId: String
        var projectDisplayName: String
        var projectPath: String?
        var cwd: String?
        var title: String?
        var startedAt: Date?
        var latestActivity: Date?
        var catalogModel: String?
        var modelTotals: [String: ModelTotals]
        var dailyTotals: [String: DailyTotals]
        var total: CodexLocalUsageTotals
        var costNanos: Int64?
        var unknownCostTokens: Int

        var topModel: String? {
            CodexLocalProjectUsageIndexer.topModel(from: self.modelTotals)
        }

        var displayModel: String? {
            self.catalogModel ?? self.topModel
        }
    }

    fileprivate struct Metadata {
        var sessionId: String?
        var cwd: String?
        var title: String?
        var startedAt: Date?
        var latestActivity: Date?
    }

    fileprivate struct BucketMergeInput {
        var sessionId: String
        var projectIdentity: CodexLocalProjectRootResolver.ProjectIdentity
        var metadata: Metadata
        var started: Date?
        var latest: Date?
        var catalogModel: String?
        var model: String?
        var fileTotals: FileTotals
    }

    fileprivate static func sessionBuckets(
        from cache: CostUsageCache,
        range: CostUsageScanner.CostUsageDayRange,
        catalog: CodexThreadCatalog,
        progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)?,
        checkCancellation: CostUsageScanner.CancellationCheck?)
        throws -> (sessionBuckets: [String: SessionBucket], indexedFiles: Int, skippedFiles: Int)
    {
        var indexedFiles = 0
        var skippedFiles = 0
        var sessionBuckets: [String: SessionBucket] = [:]
        let files = cache.files.sorted(by: { $0.key < $1.key }).filter {
            $0.value.touchesCodexScanWindow(sinceKey: range.sinceKey, untilKey: range.untilKey)
        }
        progress?(CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 0,
            totalFileCount: files.count))

        for (offset, entry) in files.enumerated() {
            try checkCancellation?()
            let path = entry.key
            let usage = entry.value
            guard let fileTotals = self.fileTotals(from: usage, range: range) else {
                skippedFiles += 1
                self.reportProgressIfNeeded(
                    progress,
                    processedFiles: offset + 1,
                    totalFiles: files.count,
                    indexedFiles: indexedFiles,
                    skippedFiles: skippedFiles)
                continue
            }
            indexedFiles += 1
            let fileURL = URL(fileURLWithPath: path)
            let cachedMetadata = self.metadata(from: usage, catalogEntry: nil)
            let catalogEntry = catalog.entry(
                sessionId: cachedMetadata.sessionId ?? usage.sessionId,
                rolloutPath: path)
            let metadata = self.metadata(from: usage, catalogEntry: catalogEntry)
            let sessionId = metadata.sessionId ?? usage.sessionId ?? fileURL.deletingPathExtension().lastPathComponent
            let projectIdentity = CodexLocalProjectRootResolver.projectIdentity(for: metadata.cwd)
            let latest = metadata.latestActivity ?? self.latestDate(from: usage.days.keys)
            let started = metadata.startedAt ?? self.earliestDate(from: usage.days.keys)
            let model = catalogEntry?.model ?? usage.lastModel ?? fileTotals.topModel
            sessionBuckets[sessionId] = self.mergedBucket(
                sessionBuckets[sessionId],
                input: BucketMergeInput(
                    sessionId: sessionId,
                    projectIdentity: projectIdentity,
                    metadata: metadata,
                    started: started,
                    latest: latest,
                    catalogModel: catalogEntry?.model,
                    model: model,
                    fileTotals: fileTotals))
            self.reportProgressIfNeeded(
                progress,
                processedFiles: offset + 1,
                totalFiles: files.count,
                indexedFiles: indexedFiles,
                skippedFiles: skippedFiles)
        }

        return (sessionBuckets, indexedFiles, skippedFiles)
    }

    fileprivate static func reportProgressIfNeeded(
        _ progress: (@Sendable (CodexLocalProjectUsageIndexProgress) -> Void)?,
        processedFiles: Int,
        totalFiles: Int,
        indexedFiles: Int,
        skippedFiles: Int)
    {
        guard processedFiles == 1 || processedFiles == totalFiles || processedFiles.isMultiple(of: 25) else {
            return
        }
        progress?(CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: processedFiles,
            totalFileCount: totalFiles,
            indexedFileCount: indexedFiles,
            skippedFileCount: skippedFiles))
    }

    fileprivate static func mergedBucket(
        _ current: SessionBucket?,
        input: BucketMergeInput) -> SessionBucket
    {
        var bucket = current ?? SessionBucket(
            id: input.sessionId,
            projectId: input.projectIdentity.id,
            projectDisplayName: input.projectIdentity.displayName,
            projectPath: input.projectIdentity.path,
            cwd: input.metadata.cwd,
            title: input.metadata.title,
            startedAt: input.started,
            latestActivity: input.latest,
            catalogModel: input.catalogModel,
            modelTotals: [:],
            dailyTotals: [:],
            total: .empty,
            costNanos: nil,
            unknownCostTokens: 0)
        if self.shouldUseProjectIdentity(input.projectIdentity, over: bucket, latestActivity: input.latest) {
            bucket.projectId = input.projectIdentity.id
            bucket.projectDisplayName = input.projectIdentity.displayName
            bucket.projectPath = input.projectIdentity.path
        }
        bucket.cwd = bucket.cwd ?? input.metadata.cwd
        bucket.title = input.metadata.title ?? bucket.title
        bucket.catalogModel = input.catalogModel ?? bucket.catalogModel
        bucket.startedAt = self.earlier(bucket.startedAt, input.started)
        bucket.latestActivity = self.later(bucket.latestActivity, input.latest)
        bucket.total = bucket.total.adding(input.fileTotals.totals)
        bucket.costNanos = self.addCost(bucket.costNanos, input.fileTotals.costNanos)
        bucket.unknownCostTokens += input.fileTotals.unknownCostTokens
        for (modelName, totals) in input.fileTotals.modelTotals {
            self.mergeModelTotals(&bucket.modelTotals, model: modelName, totals: totals)
        }
        for (day, totals) in input.fileTotals.dailyTotals {
            self.mergeDailyTotals(&bucket.dailyTotals, day: day, totals: totals)
        }
        if let model = input.model, !model.isEmpty, bucket.modelTotals[model] == nil {
            bucket.modelTotals[model] = ModelTotals(totalTokens: 0, costNanos: nil, unknownCostTokens: 0)
        }
        return bucket
    }

    fileprivate static func shouldUseProjectIdentity(
        _ identity: CodexLocalProjectRootResolver.ProjectIdentity,
        over bucket: SessionBucket,
        latestActivity: Date?) -> Bool
    {
        guard identity.id != CodexLocalProjectRootResolver.chatsProjectId else {
            return bucket.projectId == CodexLocalProjectRootResolver.chatsProjectId
        }
        guard bucket.projectId != CodexLocalProjectRootResolver.chatsProjectId else {
            return true
        }
        let currentLatest = bucket.latestActivity ?? .distantPast
        let incomingLatest = latestActivity ?? .distantPast
        return incomingLatest >= currentLatest
    }

    fileprivate static func fileTotals(
        from usage: CostUsageFileUsage,
        range: CostUsageScanner.CostUsageDayRange) -> FileTotals?
    {
        var input = 0
        var cached = 0
        var output = 0
        var costNanos: Int64?
        var unknownCostTokens = 0
        var modelTotals: [String: ModelTotals] = [:]
        var dailyTotals: [String: DailyTotals] = [:]

        for (day, models) in usage.days where CostUsageScanner.CostUsageDayRange
            .isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
        {
            for (model, values) in models {
                let modelInput = max(0, values[safe: 0] ?? 0)
                let modelCached = max(0, values[safe: 1] ?? 0)
                let modelOutput = max(0, values[safe: 2] ?? 0)
                let modelTotal = modelInput + modelOutput
                guard modelTotal > 0 else { continue }
                input += modelInput
                cached += min(modelCached, modelInput)
                output += modelOutput
                let modelCostNanos = usage.codexCostNanos?[day]?[model]
                let modelUnknownCostTokens = modelCostNanos == nil ? modelTotal : 0
                self.addModelTotals(
                    &modelTotals,
                    model: model,
                    tokens: modelTotal,
                    costNanos: modelCostNanos,
                    unknownCostTokens: modelUnknownCostTokens)
                costNanos = self.addCost(costNanos, modelCostNanos)
                unknownCostTokens += modelUnknownCostTokens
                self.addDailyTotals(
                    &dailyTotals,
                    day: day,
                    totals: DailyTotals(
                        totalTokens: modelTotal,
                        cachedInputTokens: min(modelCached, modelInput),
                        costNanos: modelCostNanos,
                        unknownCostTokens: modelUnknownCostTokens))
            }
        }

        guard input + output > 0 else { return nil }
        return FileTotals(
            totals: CodexLocalUsageTotals(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                reasoningOutputTokens: nil,
                totalTokens: input + output),
            costNanos: costNanos,
            unknownCostTokens: unknownCostTokens,
            modelTotals: modelTotals,
            dailyTotals: dailyTotals,
            topModel: self.topModel(from: modelTotals))
    }

    fileprivate static func metadata(
        from usage: CostUsageFileUsage,
        catalogEntry: CodexThreadCatalogEntry?) -> Metadata
    {
        let session = usage.codexSession
        return Metadata(
            sessionId: catalogEntry?.id ?? session?.sessionId ?? usage.sessionId,
            cwd: catalogEntry?.cwd ?? session?.cwd,
            title: catalogEntry?.title ?? catalogEntry?.preview ?? session?.title,
            startedAt: self.date(fromUnixMilliseconds: catalogEntry?.createdAtUnixMs ?? session?.startedAtUnixMs),
            latestActivity: self
                .date(fromUnixMilliseconds: catalogEntry?.updatedAtUnixMs ?? session?.latestActivityUnixMs))
    }

    fileprivate static func date(fromUnixMilliseconds unixMs: Int64?) -> Date? {
        guard let unixMs else { return nil }
        return Date(timeIntervalSince1970: Double(unixMs) / 1000)
    }

    fileprivate static func scopeSignature(
        options: CostUsageScanner.Options,
        cache: CostUsageCache,
        catalogFingerprint: String? = nil) -> String
    {
        let roots = self.rootsFingerprint(CostUsageScanner.codexRootsFingerprint(options: options))
        var parts = roots.sorted { $0.key < $1.key }.map { "root:\($0.key)=\($0.value)" }
        parts.append("producer=\(cache.producerKey ?? "")")
        parts.append("pricing=\(cache.codexPricingKey ?? "")")
        parts.append("priorityMetadata=\(cache.codexPriorityMetadataKey ?? "")")
        if let catalogFingerprint {
            parts.append("catalog=\(catalogFingerprint)")
        }
        return "codex-local-project:" + parts.joined(separator: "|")
    }

    fileprivate static func stableScopeSignature(options: CostUsageScanner.Options) -> String {
        CodexLocalDataScope.resolve(options: options).identifier
    }

    fileprivate static func rootsFingerprint(_ roots: [String: Int64]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: roots.sorted { $0.key < $1.key })
    }

    fileprivate static func total(from projects: [CodexLocalProjectUsage]) -> CodexLocalUsageTotals {
        projects.reduce(.empty) { partial, project in
            partial.adding(project.totals)
        }
    }

    fileprivate static func dailyPoints(
        from usages: Dictionary<String, CostUsageFileUsage>.Values,
        range: CostUsageScanner.CostUsageDayRange) -> [CodexLocalUsageDailyPoint]
    {
        var buckets: [String: (tokens: Int, cachedInputTokens: Int, costNanos: Int64?)] = [:]
        for usage in usages {
            for (day, models) in usage.days where CostUsageScanner.CostUsageDayRange
                .isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
            {
                var bucket = buckets[day] ?? (0, 0, nil)
                for (model, values) in models {
                    let input = max(0, values[safe: 0] ?? 0)
                    let cached = min(max(0, values[safe: 1] ?? 0), input)
                    let tokens = input + max(0, values[safe: 2] ?? 0)
                    bucket.tokens += tokens
                    bucket.cachedInputTokens += cached
                    if let nanos = usage.codexCostNanos?[day]?[model] {
                        bucket.costNanos = self.addCost(bucket.costNanos, nanos)
                    }
                }
                buckets[day] = bucket
            }
        }
        return buckets.sorted { $0.key < $1.key }.map {
            CodexLocalUsageDailyPoint(
                day: $0.key,
                totalTokens: $0.value.tokens,
                cachedInputTokens: $0.value.cachedInputTokens,
                estimatedCostUSD: self.usd(fromNanos: $0.value.costNanos))
        }
    }

    fileprivate static func dailyPoints(from totals: [String: DailyTotals]) -> [CodexLocalUsageDailyPoint] {
        totals.sorted { $0.key < $1.key }.map {
            CodexLocalUsageDailyPoint(
                day: $0.key,
                totalTokens: $0.value.totalTokens,
                cachedInputTokens: $0.value.cachedInputTokens,
                estimatedCostUSD: self.usd(fromNanos: $0.value.costNanos))
        }
    }

    fileprivate static func modelBreakdowns(from modelTotals: [String: ModelTotals])
    -> [CodexLocalUsageModelBreakdown] {
        modelTotals.sorted {
            if $0.value.totalTokens != $1.value.totalTokens {
                return $0.value.totalTokens > $1.value.totalTokens
            }
            return $0.key < $1.key
        }.map {
            CodexLocalUsageModelBreakdown(
                model: $0.key,
                totals: CodexLocalUsageTotals(
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    reasoningOutputTokens: nil,
                    totalTokens: $0.value.totalTokens),
                costEstimate: CodexLocalCostEstimate(
                    knownUSD: self.usd(fromNanos: $0.value.costNanos) ?? 0,
                    unknownTokens: $0.value.unknownCostTokens))
        }
    }

    fileprivate static func globalModelBreakdowns(
        from sessions: Dictionary<String, SessionBucket>.Values) -> [CodexLocalUsageModelBreakdown]
    {
        var modelTotals: [String: ModelTotals] = [:]
        for session in sessions {
            for (model, totals) in session.modelTotals {
                self.mergeModelTotals(&modelTotals, model: model, totals: totals)
            }
        }
        return self.modelBreakdowns(from: modelTotals)
    }

    fileprivate static func topModel(from modelTotals: [String: ModelTotals]) -> String? {
        modelTotals.max {
            if $0.value.totalTokens != $1.value.totalTokens {
                return $0.value.totalTokens < $1.value.totalTokens
            }
            return $0.key > $1.key
        }?.key
    }

    fileprivate static func addModelTotals(
        _ modelTotals: inout [String: ModelTotals],
        model: String,
        tokens: Int,
        costNanos: Int64?,
        unknownCostTokens: Int)
    {
        self.mergeModelTotals(
            &modelTotals,
            model: model,
            totals: ModelTotals(
                totalTokens: tokens,
                costNanos: costNanos,
                unknownCostTokens: unknownCostTokens))
    }

    fileprivate static func addDailyTotals(
        _ dailyTotals: inout [String: DailyTotals],
        day: String,
        totals: DailyTotals)
    {
        self.mergeDailyTotals(
            &dailyTotals,
            day: day,
            totals: totals)
    }

    fileprivate static func mergeDailyTotals(
        _ dailyTotals: inout [String: DailyTotals],
        day: String,
        totals: DailyTotals)
    {
        var current = dailyTotals[day] ?? DailyTotals(
            totalTokens: 0,
            cachedInputTokens: 0,
            costNanos: nil,
            unknownCostTokens: 0)
        current.totalTokens += totals.totalTokens
        current.cachedInputTokens += totals.cachedInputTokens
        current.costNanos = self.addCost(current.costNanos, totals.costNanos)
        current.unknownCostTokens += totals.unknownCostTokens
        dailyTotals[day] = current
    }

    fileprivate static func mergeModelTotals(
        _ modelTotals: inout [String: ModelTotals],
        model: String,
        totals: ModelTotals)
    {
        var existing = modelTotals[model] ?? ModelTotals(totalTokens: 0, costNanos: nil, unknownCostTokens: 0)
        existing.totalTokens += totals.totalTokens
        existing.costNanos = self.addCost(existing.costNanos, totals.costNanos)
        existing.unknownCostTokens += totals.unknownCostTokens
        modelTotals[model] = existing
    }

    fileprivate static func sortProjects(_ lhs: CodexLocalProjectUsage, _ rhs: CodexLocalProjectUsage) -> Bool {
        let lTokens = lhs.totals.totalTokens ?? -1
        let rTokens = rhs.totals.totalTokens ?? -1
        if lTokens != rTokens { return lTokens > rTokens }
        let lCost = lhs.estimatedCostUSD ?? -1
        let rCost = rhs.estimatedCostUSD ?? -1
        if lCost != rCost { return lCost > rCost }
        if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
        if lhs.latestActivity != rhs.latestActivity {
            return (lhs.latestActivity ?? .distantPast) > (rhs.latestActivity ?? .distantPast)
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    fileprivate static func sortSessions(_ lhs: CodexLocalSessionUsage, _ rhs: CodexLocalSessionUsage) -> Bool {
        let lTokens = lhs.totals.totalTokens ?? -1
        let rTokens = rhs.totals.totalTokens ?? -1
        if lTokens != rTokens { return lTokens > rTokens }
        let lCost = lhs.estimatedCostUSD ?? -1
        let rCost = rhs.estimatedCostUSD ?? -1
        if lCost != rCost { return lCost > rCost }
        let lDate = lhs.latestActivity ?? .distantPast
        let rDate = rhs.latestActivity ?? .distantPast
        if lDate != rDate { return lDate > rDate }
        return lhs.id < rhs.id
    }

    fileprivate static func sessionTitle(
        explicitTitle: String?,
        startedAt: Date?,
        latestActivity: Date?,
        model: String?) -> String
    {
        if let explicitTitle = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitTitle.isEmpty
        {
            return explicitTitle
        }
        let date = latestActivity ?? startedAt
        var parts: [String] = []
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append(formatter.string(from: date))
        }
        if let model, !model.isEmpty {
            parts.append(model)
        }
        // Core stores a semantic fallback title, never a UI localization key.
        return parts.isEmpty ? CodexLocalSessionUsage.localChatFallbackTitle : parts.joined(separator: " · ")
    }

    fileprivate static func latestDate(from dayKeys: Dictionary<String, [String: [Int]]>.Keys) -> Date? {
        dayKeys.compactMap(CostUsageDateParser.parse).max()
    }

    fileprivate static func earliestDate(from dayKeys: Dictionary<String, [String: [Int]]>.Keys) -> Date? {
        dayKeys.compactMap(CostUsageDateParser.parse).min()
    }

    fileprivate static func addCost(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        guard let rhs else { return lhs }
        guard let lhs else { return rhs }
        return lhs + rhs
    }

    fileprivate static func earlier(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            min(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }
    }

    fileprivate static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            max(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }
    }

    fileprivate static func usd(fromNanos nanos: Int64?) -> Double? {
        guard let nanos else { return nil }
        return Double(nanos) / 1_000_000_000
    }
}
