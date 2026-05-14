import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CursorLoginRunnerTests {
    @Test
    func `login opens Cursor dashboard in browser before polling cookies`() async {
        var openedURLs: [URL] = []
        var phases: [String] = []

        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            timeout: 1,
            pollInterval: 0.01,
            openURL: { url in
                openedURLs.append(url)
                return true
            },
            loadSnapshot: {
                CursorStatusSnapshot(
                    planPercentUsed: 12,
                    planUsedUSD: 1,
                    planLimitUSD: 20,
                    onDemandUsedUSD: 0,
                    onDemandLimitUSD: nil,
                    teamOnDemandUsedUSD: nil,
                    teamOnDemandLimitUSD: nil,
                    billingCycleEnd: nil,
                    membershipType: "pro",
                    accountEmail: "cursor@example.com",
                    accountName: nil,
                    rawJSON: nil)
            },
            sleeper: { _ in })

        let result = await runner.run { phase in
            switch phase {
            case .loading: phases.append("loading")
            case .waitingLogin: phases.append("waitingLogin")
            case .success: phases.append("success")
            case let .failed(message): phases.append("failed:\(message)")
            }
        }

        #expect(openedURLs == [CursorLoginRunner.dashboardURL])
        #expect(phases == ["loading", "waitingLogin", "success"])
        #expect(result.email == "cursor@example.com")
    }

    @Test
    func `login reports launch failure when browser cannot open`() async {
        let runner = CursorLoginRunner(
            browserDetection: BrowserDetection(cacheTTL: 0),
            openURL: { _ in false },
            loadSnapshot: {
                Issue.record("Should not poll cookies when browser launch fails")
                throw CursorStatusProbeError.noSessionCookie
            },
            sleeper: { _ in })

        let result = await runner.run { _ in }

        guard case let .failed(message) = result.outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(message.contains("Could not open Cursor login"))
    }
}
