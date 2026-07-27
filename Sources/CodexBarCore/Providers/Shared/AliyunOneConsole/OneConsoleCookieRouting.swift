import Foundation

/// Cookie-routing helper for Aliyun OneConsole-based providers.
///
/// The same browser session supplies cookies for two scopes: dashboard HTML
/// GETs (which may live on the console host or a passport sub-domain) and
/// API POSTs (which live on the data-gateway host). A redirect chain can
/// bounce between them; this routing keeps cookies pinned to the right
/// scope so the redirected request still authenticates.
public struct OneConsoleCookieRouting: ProviderHTTPCookieRouting, Sendable {
    public let apiHost: String
    public let apiPath: String
    public let apiCookieHeader: String
    public let dashboardCookieHeader: String

    public init(
        apiHost: String,
        apiPath: String,
        apiCookieHeader: String,
        dashboardCookieHeader: String)
    {
        self.apiHost = apiHost.lowercased()
        self.apiPath = apiPath
        self.apiCookieHeader = apiCookieHeader
        self.dashboardCookieHeader = dashboardCookieHeader
    }

    public func cookieHeader(
        forRedirectFrom original: URLRequest,
        to redirected: URLRequest) -> String?
    {
        let acceptHeader = original.value(forHTTPHeaderField: "Accept")
        let isDashboardNavigation = acceptHeader?.contains("text/html") == true
        let cookieHeader = isDashboardNavigation ? self.dashboardCookieHeader : self.apiCookieHeader

        // If the redirect lands back on the same API endpoint, pin cookies to
        // the API scope regardless of the original Accept header. Some console
        // paths bounce through a same-host path (e.g. locale prefixes) before
        // the actual /data/api.json POST.
        if let url = redirected.url,
           url.host?.lowercased() == self.apiHost,
           url.path == self.apiPath,
           !isDashboardNavigation
        {
            return self.apiCookieHeader
        }
        return cookieHeader
    }
}
