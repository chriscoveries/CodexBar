import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityWarmAgyReuseTests {
    // MARK: - Helper-seam tests (tryWarmAgyFetch)

    @Test
    func warmAgyFound_reusesPorts_withoutSpawn() async {
        let listeningPortsCallCount = LockedCounter()
        let fetchSnapshotCallCount = LockedCounter()

        let result = await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [Self.cliProcessInfo(pid: 9901)] },
                listeningPorts: { pid, _ in
                    listeningPortsCallCount.increment()
                    #expect(pid == 9901)
                    return [56789]
                },
                fetchSnapshot: { ports in
                    fetchSnapshotCallCount.increment()
                    #expect(ports == [56789])
                    return Self.usableSnapshot(email: "warm@example.com")
                }))

        #expect(result?.accountEmail == "warm@example.com")
        #expect(result?.modelQuotas.first?.modelId == "gemini-pro")
        #expect(listeningPortsCallCount.value == 1)
        #expect(fetchSnapshotCallCount.value == 1)
    }

    @Test
    func noWarmAgy_returnsNil() async {
        let result = await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [] },
                listeningPorts: { _, _ in
                    Issue.record("listeningPorts must not be called when no warm agy found")
                    return []
                },
                fetchSnapshot: { _ in
                    Issue.record("fetchSnapshot must not be called when no warm agy found")
                    throw AntigravityStatusProbeError.notRunning
                }))

        #expect(result == nil)
    }

    @Test
    func processInfosThrows_returnsNil() async {
        // detectProcessInfos throws (e.g. .missingCSRFToken / .notRunning) — the
        // fast path must swallow it and let the caller fall back to spawning.
        let result = await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { throw AntigravityStatusProbeError.missingCSRFToken },
                listeningPorts: { _, _ in
                    Issue.record("listeningPorts must not be called when discovery throws")
                    return []
                },
                fetchSnapshot: { _ in
                    Issue.record("fetchSnapshot must not be called when discovery throws")
                    throw AntigravityStatusProbeError.notRunning
                }))

        #expect(result == nil)
    }

    @Test
    func warmAgyFetchFails_returnsNil() async {
        let fetchSnapshotCallCount = LockedCounter()

        let result = await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [Self.cliProcessInfo(pid: 7701)] },
                listeningPorts: { _, _ in [55555] },
                fetchSnapshot: { _ in
                    fetchSnapshotCallCount.increment()
                    throw AntigravityStatusProbeError.portDetectionFailed("endpoint not ready")
                }))

        // Fetch fails → warm reuse returns nil → caller falls back to spawn
        #expect(result == nil)
        #expect(fetchSnapshotCallCount.value == 1)
    }

    @Test
    func ideProcessIgnored_notReuseableAsWarmCLI() async {
        // An IDE language server requires a CSRF token — must NOT be reused via
        // the token-less warm path.
        let ideProcessInfo = AntigravityStatusProbe.ProcessInfoResult(
            pid: 8801,
            extensionPort: nil,
            extensionServerCSRFToken: nil,
            csrfToken: "abc123",
            commandLine:
            // swiftlint:disable:next line_length
            "/Applications/Antigravity IDE.app/Contents/Resources/language_server --csrf_token abc123 --app_data_dir antigravity-ide")
        let fetchSnapshotCallCount = LockedCounter()

        let result = await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [ideProcessInfo] },
                listeningPorts: { _, _ in [44444] },
                fetchSnapshot: { _ in
                    fetchSnapshotCallCount.increment()
                    return Self.usableSnapshot(email: "ide@example.com")
                }))

        #expect(result == nil)
        #expect(fetchSnapshotCallCount.value == 0)
    }

    @Test
    func ownedAgyExcluded_fallsBackToSpawnPath() async {
        // CodexBar's own managed `agy` (pid 4242) appears in the process scan.
        // It must NOT be reused through the warm path — doing so would bypass the
        // session lifecycle and let `stopIfIdle` tear it down mid-poll.
        let fetchSnapshotCallCount = LockedCounter()

        let result = await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [Self.cliProcessInfo(pid: 4242)] },
                listeningPorts: { _, _ in
                    Issue.record("listeningPorts must not be called for a CodexBar-owned agy")
                    return []
                },
                fetchSnapshot: { _ in
                    fetchSnapshotCallCount.increment()
                    return Self.usableSnapshot(email: "owned@example.com")
                },
                ownedPID: { 4242 }))

        #expect(result == nil)
        #expect(fetchSnapshotCallCount.value == 0)
    }

    @Test
    func externalAgyReused_whenOwnedAlsoPresent() async {
        // With both an owned `agy` (pid 4242) and an external one (pid 7000), only
        // the external server is reused; the owned pid is filtered out.
        let listeningPortsCallCount = LockedCounter()

        let result = await AntigravityCLIHTTPSFetchStrategy.tryWarmAgyFetch(
            timeout: 2.0,
            dependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [Self.cliProcessInfo(pid: 4242), Self.cliProcessInfo(pid: 7000)] },
                listeningPorts: { pid, _ in
                    listeningPortsCallCount.increment()
                    #expect(pid == 7000)
                    return [50050]
                },
                fetchSnapshot: { _ in Self.usableSnapshot(email: "external@example.com") },
                ownedPID: { 4242 }))

        #expect(result?.accountEmail == "external@example.com")
        #expect(listeningPortsCallCount.value == 1)
    }

    // MARK: - Integration: fetchUsingWarmSession fast-path branch

    @Test
    func warmReuse_skipsSpawnPath() async throws {
        let spawnCallCount = LockedCounter()
        let strategy = AntigravityCLIHTTPSFetchStrategy()

        let result = try await strategy.fetchUsingWarmSession(
            binary: "/usr/local/bin/agy",
            idleWindow: nil,
            resetAfterFetch: true,
            warmDependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [Self.cliProcessInfo(pid: 1234)] },
                listeningPorts: { _, _ in [40000] },
                fetchSnapshot: { _ in Self.usableSnapshot(email: "warm@example.com") }),
            spawnFetch: { _, _, _ in
                spawnCallCount.increment()
                Issue.record("spawn path must not run when a warm agy is reused")
                throw AntigravityStatusProbeError.notRunning
            })

        #expect(result.usage.identity?.accountEmail == "warm@example.com")
        #expect(result.sourceLabel == AntigravityCLIHTTPSFetchStrategy.sourceLabel)
        // The warm path never touches AntigravityCLISession: the spawn seam (the
        // only place beginProbe/finishProbe run) was never invoked.
        #expect(spawnCallCount.value == 0)
    }

    @Test
    func noWarmAgy_fallsBackToSpawnPath() async throws {
        let spawnCallCount = LockedCounter()
        let strategy = AntigravityCLIHTTPSFetchStrategy()

        let result = try await strategy.fetchUsingWarmSession(
            binary: "/usr/local/bin/agy",
            idleWindow: nil,
            resetAfterFetch: true,
            warmDependencies: AntigravityCLIHTTPSFetchStrategy.WarmAgyDependencies(
                processInfos: { [] },
                listeningPorts: { _, _ in [] },
                fetchSnapshot: { _ in throw AntigravityStatusProbeError.notRunning }),
            spawnFetch: { binary, _, resetAfterFetch in
                spawnCallCount.increment()
                #expect(binary == "/usr/local/bin/agy")
                #expect(resetAfterFetch)
                return strategy.makeResult(
                    usage: Self.usableUsage(email: "spawned@example.com"),
                    sourceLabel: AntigravityCLIHTTPSFetchStrategy.sourceLabel)
            })

        #expect(result.usage.identity?.accountEmail == "spawned@example.com")
        #expect(spawnCallCount.value == 1)
    }

    // MARK: - Fixtures

    private static func cliProcessInfo(pid: Int) -> AntigravityStatusProbe.ProcessInfoResult {
        AntigravityStatusProbe.ProcessInfoResult(
            pid: pid,
            extensionPort: nil,
            extensionServerCSRFToken: nil,
            csrfToken: "",
            commandLine: "/usr/local/bin/agy")
    }

    private static func usableSnapshot(email: String) -> AntigravityStatusSnapshot {
        AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini Pro",
                    modelId: "gemini-pro",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: email,
            accountPlan: "Pro",
            source: .local)
    }

    private static func usableUsage(email: String) -> UsageSnapshot {
        (try? self.usableSnapshot(email: email).toUsageSnapshot())
            ?? UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .antigravity,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: nil))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        self.lock.withLock {
            self.count += 1
            return self.count
        }
    }

    var value: Int {
        self.lock.withLock { self.count }
    }
}
