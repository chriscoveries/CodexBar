import Foundation

public enum QoderProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .qoder,
            metadata: ProviderMetadata(
                id: .qoder,
                displayName: "Qoder",
                sessionLabel: "Credits",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Big model credits from the Qoder usage dashboard.",
                toggleTitle: "Show Qoder usage",
                cliName: "qoder",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.qoderCookieImportOrder,
                dashboardURL: "https://qoder.com/account/usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .qoder,
                iconResourceName: "ProviderIcon-qoder",
                color: ProviderColor(red: 16 / 255, green: 185 / 255, blue: 129 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Qoder cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [QoderWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "qoder",
                aliases: [],
                versionDetector: nil))
    }
}

struct QoderWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (String, QoderWebSite, TimeInterval) async throws -> QoderUsageSnapshot
    typealias CookieResolver = @Sendable (ProviderFetchContext, Bool, Set<String>) throws -> QoderResolvedCookie?

    let id: String = "qoder.web"
    let kind: ProviderFetchKind = .web
    private let usageLoader: UsageLoader
    private let cookieResolver: CookieResolver

    init(
        usageLoader: @escaping UsageLoader = { cookieHeader, site, timeout in
            try await QoderUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                site: site,
                timeout: timeout)
        },
        cookieResolver: @escaping CookieResolver = QoderWebFetchStrategy.resolveCookieHeader)
    {
        self.usageLoader = usageLoader
        self.cookieResolver = cookieResolver
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let cookieSource = context.settings?.qoder?.cookieSource ?? .auto
        guard cookieSource != .off else { return false }
        if cookieSource == .manual {
            return CookieHeaderNormalizer.normalize(context.settings?.qoder?.manualCookieHeader) != nil
        }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.qoder?.cookieSource ?? .auto
        let shouldRetry = cookieSource != .manual || Self.shouldRetryManualCookieHeader(
            context.settings?.qoder?.manualCookieHeader)
        var skippedSourceLabels = Set<String>()
        var allowCached = true
        var sawInvalidCredentials = false
        var deferredError: Error?

        while true {
            guard let resolvedCookie = try self.cookieResolver(
                context,
                allowCached,
                skippedSourceLabels)
            else {
                if sawInvalidCredentials {
                    throw QoderUsageError.invalidCredentials
                }
                if let deferredError {
                    throw deferredError
                }
                throw QoderUsageError.missingCredentials
            }

            do {
                let snapshot = try await self.usageLoader(
                    resolvedCookie.cookieHeader,
                    Self.site(for: resolvedCookie.sourceLabel),
                    context.webTimeout)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: resolvedCookie.sourceLabel)
            } catch is CancellationError {
                throw CancellationError()
            } catch let fetchError {
                guard shouldRetry else { throw fetchError }
                if deferredError == nil {
                    deferredError = fetchError
                }
                if case QoderUsageError.invalidCredentials = fetchError {
                    CookieHeaderCache.clear(provider: .qoder)
                    sawInvalidCredentials = true
                }
                if !resolvedCookie.isFromCache {
                    skippedSourceLabels.insert(resolvedCookie.sourceLabel)
                }
                allowCached = false
                continue
            }
        }
    }

    static func resolveCookieHeader(
        context: ProviderFetchContext,
        allowCached: Bool,
        skippingSourceLabels: Set<String>) throws -> QoderResolvedCookie?
    {
        if context.settings?.qoder?.cookieSource == .manual {
            let rawHeader = context.settings?.qoder?.manualCookieHeader
            guard let manual = CookieHeaderNormalizer.normalize(rawHeader) else {
                throw QoderUsageError.missingCredentials
            }
            for site in Self.sites(forManualCookieHeader: rawHeader) {
                let sourceLabel = Self.sourceLabel(browserLabel: "manual", site: site)
                guard Self.shouldUseSourceLabel(sourceLabel, skipping: skippingSourceLabels) else {
                    continue
                }
                return QoderResolvedCookie(cookieHeader: manual, sourceLabel: sourceLabel)
            }
            return nil
        }

        #if os(macOS)
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .qoder),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           shouldUseSourceLabel(cached.sourceLabel, skipping: skippingSourceLabels)
        {
            return QoderResolvedCookie(
                cookieHeader: cached.cookieHeader,
                sourceLabel: cached.sourceLabel,
                isFromCache: true)
        }

        let sessions: [QoderCookieImporter.SessionInfo]
        do {
            sessions = try QoderCookieImporter.importSessions(browserDetection: context.browserDetection)
        } catch {
            throw QoderUsageError.missingCredentials
        }
        guard let session = sessions.first(where: { session in
            Self.shouldUseSourceLabel(
                Self.sourceLabel(browserLabel: session.sourceLabel, site: session.site),
                skipping: skippingSourceLabels)
        })
        else {
            return nil
        }
        guard !session.cookies.isEmpty else {
            throw QoderUsageError.missingCredentials
        }
        let sourceLabel = Self.sourceLabel(browserLabel: session.sourceLabel, site: session.site)
        CookieHeaderCache.store(
            provider: .qoder,
            cookieHeader: session.cookieHeader,
            sourceLabel: sourceLabel)
        return QoderResolvedCookie(cookieHeader: session.cookieHeader, sourceLabel: sourceLabel)
        #else
        throw QoderUsageError.missingCredentials
        #endif
    }

    static func site(forManualCookieHeader rawHeader: String?) -> QoderWebSite {
        self.sites(forManualCookieHeader: rawHeader).first ?? .international
    }

    private static func sites(forManualCookieHeader rawHeader: String?) -> [QoderWebSite] {
        let raw = rawHeader?.lowercased() ?? ""
        let normalized = CookieHeaderNormalizer.normalize(rawHeader)?.lowercased() ?? ""
        if raw.contains("qoder.com.cn") || normalized.contains("qoder.com.cn") {
            return [.china]
        }
        if raw.contains("qoder.com") || normalized.contains("qoder.com") {
            return [.international]
        }
        return [.international, .china]
    }

    private static func shouldRetryManualCookieHeader(_ rawHeader: String?) -> Bool {
        self.sites(forManualCookieHeader: rawHeader).count > 1
    }

    private static func sourceLabel(browserLabel: String, site: QoderWebSite) -> String {
        switch site {
        case .international:
            "\(browserLabel) / qoder.com"
        case .china:
            "\(browserLabel) / qoder.com.cn"
        }
    }

    static func site(for sourceLabel: String) -> QoderWebSite {
        sourceLabel.contains("qoder.com.cn") ? .china : .international
    }

    private static func shouldUseSourceLabel(_ sourceLabel: String, skipping skippedLabels: Set<String>) -> Bool {
        !skippedLabels.contains(sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

struct QoderResolvedCookie {
    let cookieHeader: String
    let sourceLabel: String
    let isFromCache: Bool

    init(cookieHeader: String, sourceLabel: String, isFromCache: Bool = false) {
        self.cookieHeader = cookieHeader
        self.sourceLabel = sourceLabel
        self.isFromCache = isFromCache
    }
}
