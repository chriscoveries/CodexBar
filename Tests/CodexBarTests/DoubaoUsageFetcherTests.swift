import Foundation
import Testing
@testable import CodexBarCore

struct DoubaoUsageSnapshotTests {
    @Test
    func `normal usage with both headers present and non-empty reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 750,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "250/1000 requests")
    }

    @Test
    func `boundary normal usage at near-full reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 1,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 99.9)
        #expect(usage.primary?.resetDescription == "999/1000 requests")
    }

    @Test
    func `unreliable headers omit the request limit window`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true,
            requestLimitsReliable: false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
    }

    @Test
    func `explicit rate limit with zero remaining reports exhausted quota`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
    }

    @Test
    func `both headers missing but key valid omit the request limit window`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
    }

    @Test
    func `invalid key with no headers reports No usage data`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "No usage data")
    }

    @Test
    func `provider identity is correctly tagged as doubao`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 500,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.accountEmail == nil)
    }
}

struct DoubaoUsageFetcherTests {
    @Test
    func `arkcli response maps coding plan and agent plan windows`() throws {
        let data = Data(
            """
            {
              "viewer": {
                "auth_method": "sso",
                "profile": "agent-plan_cn-beijing_personal"
              },
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "5h", "total": 2000, "percent": 0},
                    {"label": "weekly", "used": 2009.33, "total": 7000, "percent": 28.7, "reset_at": "2026-07-20T00:00:00+08:00"},
                    {"label": "monthly", "used": 2009.33, "total": 20000, "percent": 10.05, "reset_at": "2026-08-14T23:59:59+08:00"}
                  ]
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "session", "percent": 7.48, "reset_at": "2026-07-16T19:12:07+08:00"},
                    {"label": "weekly", "percent": 2.71, "reset_at": "2026-07-20T00:00:00+08:00"},
                    {"label": "monthly", "percent": 1.36, "reset_at": "2026-08-15T23:59:59+08:00"}
                  ],
                  "updated_at": 1784191193
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        // Coding plan should be primary/secondary/tertiary
        #expect(usage.primary?.usedPercent == 7.48)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 2.71)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary?.usedPercent == 1.36)
        #expect(usage.tertiary?.windowMinutes == 43200)

        // Agent plan should appear as extra rate windows
        let agentWindows = usage.extraRateWindows ?? []
        #expect(agentWindows.count == 3)
        #expect(agentWindows[0].title == "Agent 5h")
        #expect(agentWindows[0].window.usedPercent == 0)
        #expect(agentWindows[1].title == "Agent Weekly")
        #expect(agentWindows[1].window.usedPercent == 28.7)
        #expect(agentWindows[2].title == "Agent Monthly")
        #expect(agentWindows[2].window.usedPercent == 10.05)

        // Update time from coding-plan's updated_at
        #expect(usage.updatedAt == Date(timeIntervalSince1970: 1_784_191_193))
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.loginMethod == "subscribed")
    }

    @Test
    func `arkcli response handles missing reset_at fields`() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "periods": [
                    {"label": "session", "percent": 12.5},
                    {"label": "weekly", "percent": 24.0, "reset_at": "2026-07-20T00:00:00+08:00"}
                  ]
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 42))

        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.secondary?.usedPercent == 24.0)
        #expect(usage.secondary?.resetsAt != nil)
    }

    @Test
    func `arkcli response with only agent plan maps agent windows to primary`() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "5h", "total": 2000, "percent": 5.0, "reset_at": "2026-07-16T19:12:07+08:00"},
                    {"label": "weekly", "percent": 15.0, "reset_at": "2026-07-20T00:00:00+08:00"},
                    {"label": "monthly", "percent": 25.0, "reset_at": "2026-08-15T23:59:59+08:00"}
                  ]
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        // With no coding-plan, agent windows become primary/secondary/tertiary
        #expect(usage.primary?.usedPercent == 5.0)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 15.0)
        #expect(usage.tertiary?.usedPercent == 25.0)
        // No extra windows since there's no coding-plan to pair with
        #expect(usage.extraRateWindows == nil || usage.extraRateWindows?.isEmpty == true)
    }

    @Test
    func `arkcli fetch via injected runner returns parsed snapshot`() async throws {
        let jsonData = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "session", "percent": 42.0, "reset_at": "2026-07-16T19:12:07+08:00"}
                  ],
                  "updated_at": 1784191193
                }
              ]
            }
            """.utf8)

        let snapshot = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
            runArkcli: { jsonData },
            date: Date(timeIntervalSince1970: 0))

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 42.0)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.updatedAt == Date(timeIntervalSince1970: 1_784_191_193))
    }

    @Test
    func `arkcli fetch surfaces parse error for invalid JSON`() async {
        await #expect {
            _ = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
                runArkcli: { Data("not json".utf8) })
        } throws: { error in
            guard case let DoubaoUsageError.parseFailed(_) = error else { return false }
            return true
        }
    }

    @Test
    func `repeated successful zero remaining responses omit unknown request limit`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 200, limit: 1000, remaining: 0),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `successful final request followed by rate limit reports exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 429, limit: 1000, remaining: 0),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `headerless rate limit confirmation preserves exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 429, limit: nil, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `rate limit with request limit header reports exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 429, limit: 1000, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 1)
    }

    @Test
    func `bare rate limit omits unknown request limit`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 429, limit: nil, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
        #expect(await transport.requestCount() == 1)
    }

    @Test
    func `failed zero remaining confirmation preserves exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .failure(URLError(.timedOut)),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `task cancellation during confirmation propagates`() async {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .cancellation,
        ])

        await #expect(throws: CancellationError.self) {
            _ = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        }
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `url cancellation during confirmation propagates`() async {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .failure(URLError(.cancelled)),
        ])

        await #expect {
            _ = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        } throws: { error in
            (error as? URLError)?.code == .cancelled
        }
        #expect(await transport.requestCount() == 2)
    }
}

private actor DoubaoScriptedTransport: ProviderHTTPTransport {
    enum Result {
        case response(statusCode: Int, limit: Int?, remaining: Int?)
        case rawResponse(statusCode: Int, body: String)
        case failure(URLError)
        case cancellation
    }

    struct CapturedRequest {
        let url: String?
        let method: String?
        let host: String?
        let date: String?
        let contentSHA256: String?
        let authorization: String?
    }

    private var results: [Result]
    private var requests = 0
    private var capturedRequest: CapturedRequest?

    init(results: [Result]) {
        self.results = results
    }

    func requestCount() -> Int {
        self.requests
    }

    func lastCapturedRequest() -> CapturedRequest? {
        self.capturedRequest
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests += 1
        self.capturedRequest = CapturedRequest(
            url: request.url?.absoluteString,
            method: request.httpMethod,
            host: request.value(forHTTPHeaderField: "Host"),
            date: request.value(forHTTPHeaderField: "X-Date"),
            contentSHA256: request.value(forHTTPHeaderField: "X-Content-Sha256"),
            authorization: request.value(forHTTPHeaderField: "Authorization"))
        let result = self.results.removeFirst()
        switch result {
        case let .response(statusCode, limit, remaining):
            var headers: [String: String] = [:]
            if let limit {
                headers["x-ratelimit-limit-requests"] = String(limit)
            }
            if let remaining {
                headers["x-ratelimit-remaining-requests"] = String(remaining)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!
            return (Data(#"{"usage":{"total_tokens":1}}"#.utf8), response)
        case let .rawResponse(statusCode, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [:])!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        case .cancellation:
            throw CancellationError()
        }
    }
}
