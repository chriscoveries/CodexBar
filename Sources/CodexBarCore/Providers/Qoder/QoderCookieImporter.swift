import Foundation

#if os(macOS)
import SweetCookieKit

public enum QoderCookieImporter {
    private static let log = CodexBarLog.logger(LogCategories.qoderCookie)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.qoder]?.browserCookieOrder ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String
        public let site: QoderWebSite

        public init(cookies: [HTTPCookie], sourceLabel: String, site: QoderWebSite) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
            self.site = site
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [],
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        guard let session = try self.importSessions(
            browserDetection: browserDetection,
            preferredBrowsers: preferredBrowsers,
            logger: logger).first
        else {
            throw QoderUsageError.missingCredentials
        }
        return session
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection(),
        preferredBrowsers: [Browser] = [],
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        let installedBrowsers = preferredBrowsers.isEmpty
            ? self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
            : preferredBrowsers.cookieImportCandidates(using: browserDetection)
        var sessions: [SessionInfo] = []

        for browserSource in installedBrowsers {
            for site in QoderWebSite.allCases {
                do {
                    let query = BrowserCookieQuery(domains: site.cookieDomains)
                    let sources = try Self.cookieClient.codexBarRecords(
                        matching: query,
                        in: browserSource,
                        logger: { msg in self.emit(msg, logger: logger) })
                    for source in sources where !source.records.isEmpty {
                        let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                        guard !cookies.isEmpty else { continue }
                        self.emit("Found \(cookies.count) cookies in \(source.label)", logger: logger)
                        sessions.append(SessionInfo(cookies: cookies, sourceLabel: source.label, site: site))
                    }
                } catch {
                    BrowserCookieAccessGate.recordIfNeeded(error)
                    self.emit(
                        "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                        logger: logger)
                }
            }
        }

        guard !sessions.isEmpty else {
            throw QoderUsageError.missingCredentials
        }
        return sessions
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[qoder-cookie] \(message)")
        self.log.debug(message)
    }
}
#endif
