import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LiteLLMUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingBaseURL
    case missingUserID
    case invalidURL
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing LiteLLM API key. Set apiKey in ~/.codexbar/config.json or LITELLM_API_KEY."
        case .missingBaseURL:
            "Missing LiteLLM base URL. Set enterpriseHost in ~/.codexbar/config.json or LITELLM_BASE_URL."
        case .missingUserID:
            "LiteLLM key info did not include a user_id."
        case .invalidURL:
            "LiteLLM URL is invalid."
        case let .apiError(message):
            "LiteLLM API error: \(message)"
        case let .parseFailed(message):
            "LiteLLM parse error: \(message)"
        }
    }
}

public struct LiteLLMKeyInfoSnapshot: Codable, Sendable, Equatable {
    public let userID: String
    public let teamID: String?
    public let keyName: String?
    public let spendUSD: Double
    public let expiresAt: Date?
}

public struct LiteLLMUsageSnapshot: Codable, Sendable, Equatable {
    public let userID: String
    public let accountEmail: String?
    public let personalSpendUSD: Double
    public let personalBudgetUSD: Double?
    public let personalResetAt: Date?
    public let teamUsage: TeamUsage?
    public let keyName: String?
    public let keyExpiresAt: Date?
    public let updatedAt: Date

    public struct TeamUsage: Codable, Sendable, Equatable {
        public let id: String
        public let alias: String?
        public let spendUSD: Double
        public let budgetUSD: Double?
        public let resetAt: Date?
        public let budgetDuration: String?
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = Self.rateWindow(
            spend: self.personalSpendUSD,
            budget: self.personalBudgetUSD,
            resetAt: self.personalResetAt,
            description: Self.budgetDescription(spend: self.personalSpendUSD, budget: self.personalBudgetUSD))

        let secondary = self.teamUsage.flatMap { team in
            Self.rateWindow(
                spend: team.spendUSD,
                budget: team.budgetUSD,
                resetAt: team.resetAt,
                description: Self.teamDescription(team))
        }

        let providerCost = self.personalBudgetUSD.map {
            ProviderCostSnapshot(
                used: self.personalSpendUSD,
                limit: $0,
                currencyCode: "USD",
                period: "Personal budget",
                resetsAt: self.personalResetAt,
                updatedAt: self.updatedAt)
        }

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: providerCost,
            subscriptionExpiresAt: self.keyExpiresAt,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .litellm,
                accountEmail: self.accountEmail,
                accountOrganization: self.teamUsage?.alias,
                loginMethod: "api"))
    }

    private static func rateWindow(
        spend: Double,
        budget: Double?,
        resetAt: Date?,
        description: String?) -> RateWindow?
    {
        guard let budget, budget > 0 else { return nil }
        return RateWindow(
            usedPercent: min(100, max(0, (spend / budget) * 100)),
            windowMinutes: nil,
            resetsAt: resetAt,
            resetDescription: description)
    }

    private static func budgetDescription(spend: Double, budget: Double?) -> String? {
        guard let budget, budget > 0 else { return UsageFormatter.usdString(spend) }
        return "\(UsageFormatter.usdString(spend)) / \(UsageFormatter.usdString(budget))"
    }

    private static func teamDescription(_ team: TeamUsage) -> String? {
        let label = team.alias.map { "Team \($0)" } ?? "Team"
        guard let budget = team.budgetUSD, budget > 0 else {
            return "\(label): \(UsageFormatter.usdString(team.spendUSD))"
        }
        return "\(label): \(UsageFormatter.usdString(team.spendUSD)) / \(UsageFormatter.usdString(budget))"
    }
}

private struct LiteLLMKeyInfoResponse: Decodable {
    struct Info: Decodable {
        let keyName: String?
        let spend: Double?
        let expires: String?
        let userID: String?
        let teamID: String?

        private enum CodingKeys: String, CodingKey {
            case keyName = "key_name"
            case spend
            case expires
            case userID = "user_id"
            case teamID = "team_id"
        }
    }

    let info: Info
}

private struct LiteLLMUserInfoResponse: Decodable {
    struct UserInfo: Decodable {
        struct Metadata: Decodable {
            let preferredUsername: String?

            private enum CodingKeys: String, CodingKey {
                case preferredUsername = "preferred_username"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.preferredUsername = try? container.decodeIfPresent(String.self, forKey: .preferredUsername)
            }
        }

        let userID: String?
        let userAlias: String?
        let maxBudget: Double?
        let spend: Double?
        let userEmail: String?
        let budgetResetAt: String?
        let metadata: Metadata?

        private enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case userAlias = "user_alias"
            case maxBudget = "max_budget"
            case spend
            case userEmail = "user_email"
            case budgetResetAt = "budget_reset_at"
            case metadata
        }
    }

    struct Key: Decodable {
        let keyName: String?
        let expires: String?
        let userID: String?
        let teamID: String?

        private enum CodingKeys: String, CodingKey {
            case keyName = "key_name"
            case expires
            case userID = "user_id"
            case teamID = "team_id"
        }
    }

    struct Team: Decodable {
        let teamAlias: String?
        let teamID: String
        let maxBudget: Double?
        let spend: Double?
        let budgetResetAt: String?
        let budgetDuration: String?

        private enum CodingKeys: String, CodingKey {
            case teamAlias = "team_alias"
            case teamID = "team_id"
            case maxBudget = "max_budget"
            case spend
            case budgetResetAt = "budget_reset_at"
            case budgetDuration = "budget_duration"
        }
    }

    let userID: String?
    let userInfo: UserInfo
    let keys: [Key]?
    let teams: [Team]?

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case userInfo = "user_info"
        case keys
        case teams
    }
}

public struct LiteLLMUsageFetcher: Sendable {
    public init() {}

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> LiteLLMUsageSnapshot
    {
        let cleanedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAPIKey.isEmpty else {
            throw LiteLLMUsageError.missingCredentials
        }

        let keyInfo = try await self.fetchKeyInfo(
            apiKey: cleanedAPIKey,
            baseURL: baseURL,
            transport: transport)
        let userUsage = try await self.fetchUserInfo(
            apiKey: cleanedAPIKey,
            baseURL: baseURL,
            userID: keyInfo.userID,
            transport: transport,
            updatedAt: updatedAt)

        if userUsage.keyName != nil || userUsage.keyExpiresAt != nil {
            return userUsage
        }
        return LiteLLMUsageSnapshot(
            userID: userUsage.userID,
            accountEmail: userUsage.accountEmail,
            personalSpendUSD: userUsage.personalSpendUSD,
            personalBudgetUSD: userUsage.personalBudgetUSD,
            personalResetAt: userUsage.personalResetAt,
            teamUsage: userUsage.teamUsage,
            keyName: keyInfo.keyName,
            keyExpiresAt: keyInfo.expiresAt,
            updatedAt: userUsage.updatedAt)
    }

    public static func _parseUserInfoForTesting(_ data: Data, updatedAt: Date) throws -> LiteLLMUsageSnapshot {
        try self.parseUserInfo(data: data, updatedAt: updatedAt)
    }

    public static func _parseKeyInfoForTesting(_ data: Data) throws -> LiteLLMKeyInfoSnapshot {
        try self.parseKeyInfo(data: data)
    }

    public static func _keyInfoURLForTesting(baseURL: URL, apiKey: String) -> URL {
        self.keyInfoURL(baseURL: baseURL, apiKey: apiKey)
    }

    public static func _userInfoURLForTesting(baseURL: URL, userID: String) -> URL {
        self.userInfoURL(baseURL: baseURL, userID: userID)
    }

    private static func fetchKeyInfo(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> LiteLLMKeyInfoSnapshot
    {
        let request = self.request(url: self.keyInfoURL(baseURL: baseURL, apiKey: apiKey), apiKey: apiKey)
        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LiteLLMUsageError.apiError("HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        return try self.parseKeyInfo(data: response.data)
    }

    private static func fetchUserInfo(
        apiKey: String,
        baseURL: URL,
        userID: String,
        transport: any ProviderHTTPTransport,
        updatedAt: Date) async throws -> LiteLLMUsageSnapshot
    {
        let request = self.request(url: self.userInfoURL(baseURL: baseURL, userID: userID), apiKey: apiKey)
        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LiteLLMUsageError.apiError("HTTP \(response.statusCode): \(Self.responseSummary(response.data))")
        }
        return try self.parseUserInfo(data: response.data, updatedAt: updatedAt)
    }

    private static func request(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func keyInfoURL(baseURL: URL, apiKey: String) -> URL {
        self.managementBaseURL(baseURL).appending(
            queryItems: [URLQueryItem(name: "key", value: apiKey)],
            pathComponents: ["key", "info"])
    }

    private static func userInfoURL(baseURL: URL, userID: String) -> URL {
        self.managementBaseURL(baseURL).appending(
            queryItems: [URLQueryItem(name: "user_id", value: userID)],
            pathComponents: ["user", "info"])
    }

    private static func managementBaseURL(_ baseURL: URL) -> URL {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.split(separator: "/").last == "v1" else { return baseURL }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let parts = path.split(separator: "/").dropLast()
        components?.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
        return components?.url ?? baseURL
    }

    private static func parseKeyInfo(data: Data) throws -> LiteLLMKeyInfoSnapshot {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMKeyInfoResponse.self, from: data)
            guard let userID = decoded.info.userID, !userID.isEmpty else {
                throw LiteLLMUsageError.missingUserID
            }
            return LiteLLMKeyInfoSnapshot(
                userID: userID,
                teamID: decoded.info.teamID,
                keyName: decoded.info.keyName,
                spendUSD: decoded.info.spend ?? 0,
                expiresAt: self.parseDate(decoded.info.expires))
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func parseUserInfo(data: Data, updatedAt: Date) throws -> LiteLLMUsageSnapshot {
        do {
            let decoded = try JSONDecoder().decode(LiteLLMUserInfoResponse.self, from: data)
            let userID = decoded.userInfo.userID ?? decoded.userID
            guard let userID, !userID.isEmpty else {
                throw LiteLLMUsageError.missingUserID
            }

            let accountEmail = self.firstNonEmpty(
                decoded.userInfo.userEmail,
                decoded.userInfo.userAlias,
                decoded.userInfo.metadata?.preferredUsername)
            let key = decoded.keys?.first { $0.userID == userID } ?? decoded.keys?.first
            let team = self.preferredTeam(from: decoded.teams, keyTeamID: key?.teamID)

            return LiteLLMUsageSnapshot(
                userID: userID,
                accountEmail: accountEmail,
                personalSpendUSD: decoded.userInfo.spend ?? 0,
                personalBudgetUSD: decoded.userInfo.maxBudget,
                personalResetAt: self.parseDate(decoded.userInfo.budgetResetAt),
                teamUsage: team.map {
                    LiteLLMUsageSnapshot.TeamUsage(
                        id: $0.teamID,
                        alias: $0.teamAlias,
                        spendUSD: $0.spend ?? 0,
                        budgetUSD: $0.maxBudget,
                        resetAt: self.parseDate($0.budgetResetAt),
                        budgetDuration: $0.budgetDuration)
                },
                keyName: key?.keyName,
                keyExpiresAt: self.parseDate(key?.expires),
                updatedAt: updatedAt)
        } catch let error as LiteLLMUsageError {
            throw error
        } catch {
            throw LiteLLMUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func preferredTeam(
        from teams: [LiteLLMUserInfoResponse.Team]?,
        keyTeamID: String?) -> LiteLLMUserInfoResponse.Team?
    {
        guard let teams else { return nil }
        if let keyTeamID, let match = teams.first(where: { $0.teamID == keyTeamID }) {
            return match
        }
        return teams.first
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = self.iso8601DateFormatter(fractionalSeconds: true).date(from: raw) {
            return date
        }
        return self.iso8601DateFormatter(fractionalSeconds: false).date(from: raw)
    }

    private static func iso8601DateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        if fractionalSeconds {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func responseSummary(_ data: Data) -> String {
        String(bytes: data.prefix(500), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}

extension URL {
    fileprivate func appending(queryItems: [URLQueryItem], pathComponents: [String]) -> URL {
        let url = pathComponents.reduce(self) { partial, component in
            partial.appendingPathComponent(component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = queryItems
        return components.url ?? url
    }
}
