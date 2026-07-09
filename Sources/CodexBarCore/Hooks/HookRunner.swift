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

    /// Runs a single rule for an event to completion. Throws `SubprocessRunnerError`
    /// on a missing/invalid executable, timeout, or non-zero exit.
    @discardableResult
    public static func run(
        rule: HookRule,
        event: HookEvent,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws -> SubprocessResult
    {
        var environment = baseEnvironment
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
        guard await rateLimiter.allow(event) else {
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
                self.log.warning(
                    "hook failed",
                    metadata: [
                        "event": "\(event.event.rawValue)",
                        "error": "\(error.localizedDescription)",
                    ])
            }
        }
    }
}
