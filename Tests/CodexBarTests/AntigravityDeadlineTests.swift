import Foundation
import Testing
@testable import CodexBarCore

private final class AntigravityTimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []

    func append(_ timeout: TimeInterval) {
        self.lock.withLock {
            self.timeouts.append(timeout)
        }
    }

    func snapshot() -> [TimeInterval] {
        self.lock.withLock {
            self.timeouts
        }
    }
}

struct AntigravityDeadlineTests {
    @Test
    func `shared deadline reduces later probe timeout`() async throws {
        let endpoints = [
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 64001,
                csrfToken: "token",
                source: .languageServer),
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 64002,
                csrfToken: "token",
                source: .languageServer),
        ]
        let recorder = AntigravityTimeoutRecorder()
        let deadline = Date().addingTimeInterval(0.2)

        let resolved = try await AntigravityStatusProbe.resolveWorkingEndpoint(
            candidateEndpoints: endpoints,
            timeout: 1,
            deadline: deadline,
            testConnectivity: { endpoint, timeout in
                recorder.append(timeout)
                if endpoint.port == 64001 {
                    try? await Task.sleep(for: .milliseconds(80))
                    return false
                }
                return true
            })

        let timeouts = recorder.snapshot()
        #expect(resolved.port == 64002)
        #expect(timeouts.count == 2)
        #expect(timeouts[1] < timeouts[0])
        #expect(timeouts[1] < 0.18)
    }
}
