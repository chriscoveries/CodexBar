import Foundation

#if os(macOS)
import SweetCookieKit

private let alibabaCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.alibaba]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum AlibabaCodingPlanCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "modelstudio.console.alibabacloud.com",
        "bailian.console.aliyun.com",
        "free.aliyun.com",
        "account.aliyun.com",
        "signin.aliyun.com",
        "passport.alibabacloud.com",
        "console.alibabacloud.com",
        "console.aliyun.com",
        "alibabacloud.com",
        "aliyun.com",
    ]

    public struct SessionInfo: Sendable {
        public let cookies: [HTTPCookie]
        public let sourceLabel: String

        public init(cookies: [HTTPCookie], sourceLabel: String) {
            self.cookies = cookies
            self.sourceLabel = sourceLabel
        }

        public var cookieHeader: String {
            self.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    public static func importSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionInfo
    {
        let log: (String) -> Void = { msg in logger?("[alibaba-cookie] \(msg)") }
        var installedBrowsers = alibabaCookieImportOrder.cookieImportCandidates(using: browserDetection)
        if !installedBrowsers.contains(.safari) {
            installedBrowsers.insert(.safari, at: 0)
        }

        for browserSource in installedBrowsers {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if !httpCookies.isEmpty {
                        log("Found \(httpCookies.count) Alibaba cookies in \(source.label)")
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        throw AlibabaCodingPlanSettingsError.missingCookie
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        do {
            _ = try self.importSession(browserDetection: browserDetection, logger: logger)
            return true
        } catch {
            return false
        }
    }
}
#endif
