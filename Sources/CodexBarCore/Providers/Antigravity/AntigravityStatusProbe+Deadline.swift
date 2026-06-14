import Foundation

extension AntigravityStatusProbe {
    static func fetch(
        processInfo: ProcessInfoResult,
        timeout: TimeInterval,
        deadline: Date) async throws -> AntigravityStatusSnapshot
    {
        guard let portTimeout = timeoutForNextAttempt(timeout: timeout, deadline: deadline) else {
            throw AntigravityStatusProbeError.timedOut
        }
        let ports = try await Self.listeningPorts(pid: processInfo.pid, timeout: portTimeout)
        let endpoint = try await Self.resolveWorkingEndpoint(
            candidateEndpoints: Self.connectionCandidates(
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: timeout,
            deadline: deadline)
        let context = RequestContext(
            endpoints: Self.requestEndpoints(
                resolvedEndpoint: endpoint,
                listeningPorts: ports,
                languageServerCSRFToken: processInfo.csrfToken,
                extensionServerPort: processInfo.extensionPort,
                extensionServerCSRFToken: processInfo.extensionServerCSRFToken),
            timeout: timeout,
            deadline: deadline)

        return try await Self.fetchSnapshot(context: context)
    }

    static func timeoutForNextAttempt(timeout: TimeInterval, deadline: Date?) -> TimeInterval? {
        guard let deadline else { return timeout }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return min(timeout, remaining)
    }
}
