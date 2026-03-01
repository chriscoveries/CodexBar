import Foundation

public struct AlibabaCodingPlanSettingsReader: Sendable {
    public static let apiTokenKey = "ALIBABA_CODING_PLAN_API_KEY"
    public static let cookieHeaderKey = "ALIBABA_CODING_PLAN_COOKIE"
    public static let hostKey = "ALIBABA_CODING_PLAN_HOST"
    public static let quotaURLKey = "ALIBABA_CODING_PLAN_QUOTA_URL"

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiTokenKey])
    }

    public static func hostOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.hostKey])
    }

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.cookieHeaderKey])
    }

    public static func quotaURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[self.quotaURLKey]) else { return nil }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(raw)")
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum AlibabaCodingPlanSettingsError: LocalizedError, Sendable {
    case missingToken
    case missingCookie
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Alibaba Coding Plan API key not found. Set apiKey in ~/.codexbar/config.json or ALIBABA_CODING_PLAN_API_KEY."
        case .missingCookie:
            "No Alibaba Coding Plan session cookies found in browsers."
        case .invalidCookie:
            "Alibaba Coding Plan cookie header is invalid."
        }
    }
}
