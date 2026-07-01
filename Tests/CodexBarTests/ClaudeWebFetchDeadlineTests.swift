import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeWebFetchDeadlineTests {
    @Test
    func `CLI auto descriptor defers browser probe and falls back after web deadline`() async throws {
        let planningProbe = ClaudeWebPlanningAvailabilityProbe()
        let webProbe = ClaudeWebDeadlineProbe()
        let context = Self.makeContext(
            sourceMode: .auto,
            webTimeout: 0.01,
            cookieSource: .auto,
            env: ["CLAUDE_CLI_PATH": "/usr/bin/true"])
        let availabilityOverride: @Sendable (ProviderFetchContext, BrowserDetection) -> Bool = { _, _ in
            planningProbe.stallAndReportUnavailable()
        }
        let usageLoader: ClaudeWebFetchStrategy.UsageLoader = { _ in
            await webProbe.waitUntilReleased()
            return Self.makeClaudeUsage()
        }
        let cliFetchOverride: @Sendable (String, TimeInterval, Bool) async throws -> ClaudeStatusSnapshot =
            { _, _, _ in Self.makeClaudeStatus() }

        let outcome = await ClaudeWebFetchStrategy.$availabilityProbeOverrideForTesting.withValue(
            availabilityOverride)
        {
            await ClaudeWebFetchStrategy.$usageLoaderOverrideForTesting.withValue(usageLoader) {
                await ClaudeStatusProbe.$fetchOverride.withValue(cliFetchOverride) {
                    await ClaudeProviderDescriptor.makeDescriptor().fetchPlan.fetchOutcome(
                        context: context,
                        provider: .claude)
                }
            }
        }
        await webProbe.release()
        let result = try outcome.result.get()

        #expect(!planningProbe.wasInvoked)
        #expect(result.strategyID == "claude.cli")
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web", "claude.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true, true])
        #expect(outcome.attempts.first?.errorDescription?.contains("Claude web usage fetch timed out") == true)
    }

    @Test
    func `app auto descriptor bounds and reuses browser availability`() async throws {
        let planningProbe = ClaudeWebPlanningAvailabilityProbe()
        let context = Self.makeContext(
            runtime: .app,
            sourceMode: .auto,
            webTimeout: 0.1,
            cookieSource: .auto,
            env: [
                "CLAUDE_CLI_PATH": "/usr/bin/true",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token",
            ])
        let availabilityOverride: @Sendable (ProviderFetchContext, BrowserDetection) -> Bool = { _, _ in
            planningProbe.stallAndReportUnavailable()
        }

        let strategies = await ClaudeWebFetchStrategy.$availabilityProbeOverrideForTesting.withValue(
            availabilityOverride)
        {
            await ClaudeProviderDescriptor.makeDescriptor().fetchPlan.pipeline.resolveStrategies(context)
        }
        planningProbe.release()
        let cliStrategy = try #require(strategies.first(where: { $0.id == "claude.cli" }))
        let shouldFallback = cliStrategy.shouldFallback(
            on: ClaudeUsageError.parseFailed("cli failed"),
            context: context)

        #expect(planningProbe.invocationCount == 1)
        #expect(!shouldFallback)
        #expect(planningProbe.invocationCount == 1)
    }

    @Test
    func `CLI auto timeout cancels web and falls back to CLI`() async throws {
        let probe = ClaudeWebDeadlineProbe()
        let web = Self.makeTimedOutWebStrategy(probe: probe)
        let pipeline = ProviderFetchPipeline { _ in [web, ClaudeWebDeadlineCLIStrategy()] }
        let context = Self.makeContext(sourceMode: .auto, webTimeout: 0.01)

        let outcome = await pipeline.fetch(context: context, provider: .claude)
        await probe.release()
        let result = try outcome.result.get()

        #expect(result.strategyID == "claude.cli")
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web", "claude.cli"])
        #expect(outcome.attempts.first?.errorDescription?.contains("Claude web usage fetch timed out") == true)
    }

    @Test
    func `explicit web timeout surfaces without CLI fallback`() async {
        let probe = ClaudeWebDeadlineProbe()
        let web = Self.makeTimedOutWebStrategy(probe: probe)
        let pipeline = ProviderFetchPipeline { _ in [web, ClaudeWebDeadlineCLIStrategy()] }
        let context = Self.makeContext(sourceMode: .web, webTimeout: 0.01)

        let outcome = await pipeline.fetch(context: context, provider: .claude)
        await probe.release()

        switch outcome.result {
        case .success:
            Issue.record("Expected the explicit web deadline to fail")
        case let .failure(error):
            #expect(error as? ClaudeWebFetchStrategyError == .timedOut(seconds: 0.01))
        }
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web"])
    }

    @Test
    func `caller cancellation does not fall back to CLI`() async {
        let probe = ClaudeWebDeadlineProbe()
        let web = Self.makeTimedOutWebStrategy(probe: probe)
        let pipeline = ProviderFetchPipeline { _ in [web, ClaudeWebDeadlineCLIStrategy()] }
        let context = Self.makeContext(sourceMode: .auto, webTimeout: 60)
        let fetchTask = Task {
            await pipeline.fetch(context: context, provider: .claude)
        }

        await probe.waitUntilStarted()
        fetchTask.cancel()
        let outcome = await fetchTask.value
        await probe.release()

        switch outcome.result {
        case .success:
            Issue.record("Expected caller cancellation to stop the fetch pipeline")
        case let .failure(error):
            #expect(error is CancellationError)
        }
        #expect(outcome.attempts.map(\.strategyID) == ["claude.web"])
    }

    @Test
    func `unsafe timeout is rejected before starting web work`() async {
        let strategy = ClaudeWebFetchStrategy(
            browserDetection: BrowserDetection(cacheTTL: 0),
            usageLoader: { _ in
                Issue.record("Unsafe timeout should be rejected before invoking the loader")
                return Self.makeClaudeUsage()
            })

        for timeout in [-1, .nan, .infinity, .greatestFiniteMagnitude] {
            do {
                _ = try await strategy.fetch(Self.makeContext(sourceMode: .web, webTimeout: timeout))
                Issue.record("Expected timeout \(timeout) to be rejected")
            } catch let error as ClaudeWebFetchStrategyError {
                #expect(error == .invalidTimeout)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    private static func makeTimedOutWebStrategy(probe: ClaudeWebDeadlineProbe) -> ClaudeWebFetchStrategy {
        ClaudeWebFetchStrategy(
            browserDetection: BrowserDetection(cacheTTL: 0),
            usageLoader: { _ in
                await probe.waitUntilReleased()
                return self.makeClaudeUsage()
            })
    }

    private static func makeContext(
        runtime: ProviderRuntime = .cli,
        sourceMode: ProviderSourceMode,
        webTimeout: TimeInterval,
        cookieSource: ProviderCookieSource = .manual,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: webTimeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(claude: .init(
                usageDataSource: sourceMode == .web ? .web : .auto,
                webExtrasEnabled: false,
                cookieSource: cookieSource,
                manualCookieHeader: cookieSource == .manual ? "sessionKey=sk-ant-session-token" : nil)),
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func makeClaudeUsage() -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            opus: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            rawText: nil)
    }

    private static func makeClaudeStatus() -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
            sessionPercentLeft: 80,
            weeklyPercentLeft: nil,
            opusPercentLeft: nil,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil,
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            opusResetDescription: nil,
            rawText: "stub")
    }
}

private final class ClaudeWebPlanningAvailabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var invocations = 0

    var invocationCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.invocations
    }

    var wasInvoked: Bool {
        self.invocationCount > 0
    }

    func stallAndReportUnavailable() -> Bool {
        self.lock.lock()
        self.invocations += 1
        self.lock.unlock()
        _ = self.releaseSemaphore.wait(timeout: .now() + 1)
        return false
    }

    func release() {
        self.releaseSemaphore.signal()
    }
}

private actor ClaudeWebDeadlineProbe {
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        if !self.started {
            self.started = true
            self.startWaiter?.resume()
            self.startWaiter = nil
        }
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiter = continuation
        }
    }

    func release() {
        self.released = true
        self.releaseWaiter?.resume()
        self.releaseWaiter = nil
    }
}

private struct ClaudeWebDeadlineCLIStrategy: ProviderFetchStrategy {
    let id = "claude.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        self.makeResult(
            usage: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_100)),
            sourceLabel: "claude")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
