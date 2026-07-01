import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct QoderProviderBehaviorTests {
    @MainActor
    private final class SessionQuotaNotifierSpy: SessionQuotaNotifying {
        private(set) var posts: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []
        private(set) var quotaWarningPosts: [(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)] = []

        func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
            self.posts.append((transition: transition, provider: provider))
        }

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)
        {
            self.quotaWarningPosts.append((
                event: event,
                provider: provider,
                soundEnabled: soundEnabled,
                onScreenAlertEnabled: onScreenAlertEnabled))
        }
    }

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var cookieHeaders: [String] = []
        private var skippedLabels: [Set<String>] = []
        private var sites: [QoderWebSite] = []
        private var site: QoderWebSite?

        func appendCookieHeader(_ value: String) {
            self.lock.withLock {
                self.cookieHeaders.append(value)
            }
        }

        func appendSkippedLabels(_ value: Set<String>) {
            self.lock.withLock {
                self.skippedLabels.append(value)
            }
        }

        func setSite(_ value: QoderWebSite) {
            self.lock.withLock {
                self.site = value
            }
        }

        func appendSite(_ value: QoderWebSite) {
            self.lock.withLock {
                self.sites.append(value)
                self.site = value
            }
        }

        func cookieHeadersSnapshot() -> [String] {
            self.lock.withLock { self.cookieHeaders }
        }

        func skippedLabelsSnapshot() -> [Set<String>] {
            self.lock.withLock { self.skippedLabels }
        }

        func siteSnapshot() -> QoderWebSite? {
            self.lock.withLock { self.site }
        }

        func sitesSnapshot() -> [QoderWebSite] {
            self.lock.withLock { self.sites }
        }
    }

    @Test
    func `token account selection forces manual cookie source in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Qoder",
                    token: "sid=qoder-account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .qoder,
                cookieSource: .auto,
                tokenAccounts: accounts),
        ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .qoder).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .qoder, account: account))
        let qoderSettings = try #require(snapshot.qoder)

        #expect(qoderSettings.cookieSource == .manual)
        #expect(qoderSettings.manualCookieHeader == "sid=qoder-account-token")
    }

    @Test
    func `model shows credit total only as primary detail when reset date missing`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.qoder])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "125 / 500 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .qoder,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.resetText == nil)
        #expect(primary.detailText == "125 / 500 credits")
        #expect(model.creditsText == nil)
        #expect(model.creditsHintText == nil)
    }

    @Test
    func `model shows reset countdown with credit detail`() throws {
        let now = Date(timeIntervalSince1970: 1_719_206_400)
        let snapshot = QoderUsageSnapshot(
            usedCredits: 125,
            totalCredits: 500,
            remainingCredits: 375,
            usagePercentage: 25,
            unit: "credit",
            resetsAt: now.addingTimeInterval(86400),
            updatedAt: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.qoder])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .qoder,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.resetText != nil)
        #expect(primary.detailText == "125 / 500 credits")
    }

    @MainActor
    @Test
    func `standard menu shows credit total as detail instead of reset line`() throws {
        let suite = "QoderProviderBehaviorTests-menu-detail"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "125 / 500 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        store._setSnapshotForTesting(snapshot, provider: .qoder)

        let descriptor = MenuDescriptor.build(
            provider: .qoder,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let textLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(textLines.contains("125 / 500 credits"))
        #expect(!textLines.contains(where: { $0.contains("Resets 125 / 500 credits") }))
    }

    @Test
    func `manual cookie header can route to Qoder China site`() {
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=abc") == .international)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=abc; Domain=.qoder.com.cn") == .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl https://qoder.com.cn -H 'Cookie: sid=abc'") == .china)
    }

    @Test
    func `auto cookie fetch retries every imported candidate before succeeding`() async throws {
        let candidates = [
            QoderResolvedCookie(cookieHeader: "sid=expired-one", sourceLabel: "Chrome Default / qoder.com"),
            QoderResolvedCookie(cookieHeader: "sid=expired-two", sourceLabel: "Chrome Profile 2 / qoder.com.cn"),
            QoderResolvedCookie(cookieHeader: "sid=valid", sourceLabel: "Chrome Profile 3 / qoder.com.cn"),
        ]
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { cookieHeader, _, _ in
                recorder.appendCookieHeader(cookieHeader)
                if cookieHeader != "sid=valid" {
                    throw QoderUsageError.invalidCredentials
                }
                return QoderUsageSnapshot(
                    usedCredits: 125,
                    totalCredits: 500,
                    remainingCredits: 375,
                    usagePercentage: 25,
                    unit: "credit")
            },
            cookieResolver: { _, _, skippedLabels in
                recorder.appendSkippedLabels(skippedLabels)
                return candidates.first { !skippedLabels.contains($0.sourceLabel) }
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(cookieSource: .auto, manualCookieHeader: nil))))

        #expect(recorder.cookieHeadersSnapshot() == ["sid=expired-one", "sid=expired-two", "sid=valid"])
        #expect(recorder.skippedLabelsSnapshot() == [
            Set<String>(),
            ["Chrome Default / qoder.com"],
            ["Chrome Default / qoder.com", "Chrome Profile 2 / qoder.com.cn"],
        ])
        #expect(result.sourceLabel == "Chrome Profile 3 / qoder.com.cn")
        #expect(result.usage.primary?.resetDescription == "125 / 500 credits")
    }

    @Test
    func `auto cookie fetch retries freshly imported session after stale cache`() async throws {
        let sourceLabel = "Chrome Default / qoder.com"
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { cookieHeader, _, _ in
                recorder.appendCookieHeader(cookieHeader)
                if cookieHeader == "sid=expired-cache" {
                    throw QoderUsageError.invalidCredentials
                }
                return QoderUsageSnapshot(
                    usedCredits: 125,
                    totalCredits: 500,
                    remainingCredits: 375,
                    usagePercentage: 25,
                    unit: "credit")
            },
            cookieResolver: { _, allowCached, skippedLabels in
                recorder.appendSkippedLabels(skippedLabels)
                if allowCached {
                    return QoderResolvedCookie(
                        cookieHeader: "sid=expired-cache",
                        sourceLabel: sourceLabel,
                        isFromCache: true)
                }
                return QoderResolvedCookie(cookieHeader: "sid=fresh", sourceLabel: sourceLabel)
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(cookieSource: .auto, manualCookieHeader: nil))))

        #expect(recorder.cookieHeadersSnapshot() == ["sid=expired-cache", "sid=fresh"])
        #expect(recorder.skippedLabelsSnapshot() == [Set<String>(), Set<String>()])
        #expect(result.sourceLabel == sourceLabel)
    }

    @Test
    func `manual cookie fetch uses China endpoint when header identifies China site`() async throws {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.setSite(site)
                return QoderUsageSnapshot(
                    usedCredits: 0,
                    totalCredits: 300,
                    remainingCredits: 300,
                    usagePercentage: 0,
                    unit: "credit")
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(
                cookieSource: .manual,
                manualCookieHeader: "curl https://qoder.com.cn -H 'Cookie: sid=china'"))))

        #expect(recorder.siteSnapshot() == .china)
        #expect(result.sourceLabel == "manual / qoder.com.cn")
    }

    @Test
    func `manual plain cookie fetch retries China endpoint after international auth failure`() async throws {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.appendSite(site)
                if site == .international {
                    throw QoderUsageError.invalidCredentials
                }
                return QoderUsageSnapshot(
                    usedCredits: 0,
                    totalCredits: 300,
                    remainingCredits: 300,
                    usagePercentage: 0,
                    unit: "credit")
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(
                cookieSource: .manual,
                manualCookieHeader: "sid=plain-cookie"))))

        #expect(recorder.sitesSnapshot() == [.international, .china])
        #expect(result.sourceLabel == "manual / qoder.com.cn")
    }

    @Test
    func `manual plain cookie fetch retries China endpoint after international network failure`() async throws {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.appendSite(site)
                if site == .international {
                    throw QoderUsageError.networkError("timed out")
                }
                return QoderUsageSnapshot(
                    usedCredits: 0,
                    totalCredits: 300,
                    remainingCredits: 300,
                    usagePercentage: 0,
                    unit: "credit")
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(
                cookieSource: .manual,
                manualCookieHeader: "sid=plain-cookie"))))

        #expect(recorder.sitesSnapshot() == [.international, .china])
        #expect(result.sourceLabel == "manual / qoder.com.cn")
    }

    @Test
    func `manual plain cookie fetch preserves international error when China also fails`() async {
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                if site == .international {
                    throw QoderUsageError.networkError("timed out")
                }
                throw QoderUsageError.apiError(503)
            })

        await #expect(throws: QoderUsageError.networkError("timed out")) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "sid=plain-cookie"))))
        }
    }

    @Test
    @MainActor
    func `monthly credits keep nil cadence and do not emit quota notifications`() throws {
        let suiteName = "QoderProviderBehaviorTests-quota-notifications"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
        let depletedSnapshot = QoderUsageSnapshot(
            usedCredits: 500,
            totalCredits: 500,
            remainingCredits: 0,
            usagePercentage: 100,
            unit: "credit",
            resetsAt: Date().addingTimeInterval(30 * 24 * 60 * 60))
            .toUsageSnapshot()
        let restoredSnapshot = QoderUsageSnapshot(
            usedCredits: 100,
            totalCredits: 500,
            remainingCredits: 400,
            usagePercentage: 20,
            unit: "credit",
            resetsAt: Date().addingTimeInterval(30 * 24 * 60 * 60))
            .toUsageSnapshot()
        let restoredPrimary = try #require(restoredSnapshot.primary)

        #expect(depletedSnapshot.primary?.windowMinutes == nil)
        #expect(restoredPrimary.windowMinutes == nil)
        #expect(store.weeklyPace(provider: .qoder, window: restoredPrimary, now: Date()) == nil)

        for snapshot in [depletedSnapshot, restoredSnapshot] {
            store.handleSessionQuotaTransition(provider: .qoder, snapshot: snapshot)
            store.handleQuotaWarningTransitions(provider: .qoder, snapshot: snapshot)
        }

        #expect(notifier.posts.isEmpty)
        #expect(notifier.quotaWarningPosts.isEmpty)
    }

    private func makeContext(settings: ProviderSettingsSnapshot?) -> ProviderFetchContext {
        let env: [String: String] = [:]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}
