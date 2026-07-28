import Foundation

public enum LiteLLMSettingsReader {
    public static let apiKeyEnvironmentKey = "LITELLM_API_KEY"
    public static let baseURLEnvironmentKey = "LITELLM_BASE_URL"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) else { return nil }
        // The API key is sent to this URL as a bearer token, so validate it like every other
        // provider override. Loopback HTTP stays allowed for self-hosted proxies; any other
        // host must use HTTPS and carry no embedded credentials.
        return ProviderEndpointOverrideValidator().validatedURLAllowingLoopbackHTTP(raw)
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
