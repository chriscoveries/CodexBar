import Foundation

/// Executes hook commands for quota/provider events.
///
/// Reuses `SubprocessRunner` for the actual process work: it validates the
/// executable path, runs the binary directly (no shell), injects the environment,
/// enforces a timeout with SIGTERM→SIGKILL escalation, and logs only the binary
/// name (never env values or the account). Event metadata reaches the command via
/// environment variables and a JSON stdin payload.
public enum HookRunner {
    private static let log = CodexBarLog.logger(LogCategories.hooks)

    /// Environment keys forwarded to a hook. Deliberately narrow: CodexBar's own
    /// process environment may hold provider API keys/tokens, and hooks must never
    /// receive secrets. Only these general-purpose vars pass through, plus the
    /// event's own `CODEXBAR_*` values.
    private static let forwardedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR",
    ]

    /// Runs a single rule for an event to completion. Throws `SubprocessRunnerError`
    /// on a missing/invalid executable, timeout, or non-zero exit.
    @discardableResult
    public static func run(
        rule: HookRule,
        event: HookEvent,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws -> SubprocessResult
    {
        var environment = baseEnvironment.filter { Self.forwardedEnvironmentKeys.contains($0.key) }
        for (key, value) in event.environmentVariables() {
            environment[key] = value
        }

        // Small payload (< 1KB) fits the OS pipe buffer (~64KB), so we can write it
        // and close the write end before launch; the child reads buffered bytes then EOF.
        let stdin = Pipe()
        let payload = try event.jsonPayload()
        stdin.fileHandleForWriting.write(payload)
        try? stdin.fileHandleForWriting.close()

        return try await SubprocessRunner.run(
            binary: rule.executable,
            arguments: rule.arguments,
            environment: environment,
            timeout: rule.timeoutSeconds,
            standardInput: stdin,
            acceptsNonZeroExit: false,
            label: "hook \(event.event.rawValue)")
    }

    /// Runs every enabled rule matching the event, subject to the rate limiter.
    /// Fire-and-forget friendly: failures are logged, never thrown to the caller.
    public static func dispatch(
        event: HookEvent,
        config: HooksConfig,
        rateLimiter: HookRateLimiter,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async
    {
        let rules = config.matchingRules(for: event)
        guard !rules.isEmpty else { return }
        // Quota events already dedupe upstream (threshold-crossing, depletion, and
        // reset-edge state), and rate-limiting them here would suppress a lower
        // remaining-quota warning that crosses within the window. Only the events
        // that can repeat every refresh while a condition persists are throttled.
        if event.event.isRateLimited, await !rateLimiter.allow(event) {
            self.log.debug("suppressed by rate limiter", metadata: ["event": "\(event.event.rawValue)"])
            return
        }
        for rule in rules {
            do {
                _ = try await self.run(rule: rule, event: event, baseEnvironment: baseEnvironment)
                self.log.info(
                    "ran hook",
                    metadata: [
                        "event": "\(event.event.rawValue)",
                        "provider": "\(event.provider)",
                    ])
            } catch {
                // Redacted: never log hook stderr (it can echo the payload/env). Log
                // only the event and a coarse failure reason.
                self.log.warning(
                    "hook failed",
                    metadata: [
                        "event": "\(event.event.rawValue)",
                        "provider": "\(event.provider)",
                        "reason": "\(Self.redactedFailureReason(error))",
                    ])
            }
        }
    }

    private static func redactedFailureReason(_ error: Error) -> String {
        guard let error = error as? SubprocessRunnerError else { return "error" }
        switch error {
        case .binaryNotFound: return "executable not found"
        case .launchFailed: return "launch failed"
        case .timedOut: return "timed out"
        case let .nonZeroExit(code, _): return "exit \(code)"
        }
    }
}
