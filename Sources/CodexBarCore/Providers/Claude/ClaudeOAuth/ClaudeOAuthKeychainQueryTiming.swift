import Dispatch
import Foundation

#if os(macOS)
import Security

enum ClaudeOAuthKeychainQueryTiming {
    static func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?, durationMs: Double) {
        var result: AnyObject?
        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        return (status, result, durationMs)
    }

    static func backoffIfSlowNoUIQuery(_ durationMs: Double, _ service: String, _ log: CodexBarLogger) -> Bool {
        guard ProviderInteractionContext.current == .background, durationMs > 1000 else { return false }
        ClaudeOAuthKeychainAccessGate.recordDenied()
        log.warning(
            "Claude keychain no-UI query was slow; backing off",
            metadata: [
                "service": service,
                "duration_ms": String(format: "%.2f", durationMs),
            ])
        return true
    }
}
#endif
