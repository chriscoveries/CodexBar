import Foundation
import Testing

/// Regression probe for the `CookieHeaderCache` display-interval override race fixed by guarding
/// `displayStalenessIntervalOverride` / `displayUnavailableRetryIntervalOverride` with
/// `displayIntervalOverrideLock`. It mirrors that exact shape — a `TimeInterval?` static behind an
/// `NSLock` — and asserts ThreadSanitizer sees no race when the storage is locked.
///
/// Opt-in: it hammers a static thousands of times, so it is gated behind `CODEXBAR_TSAN_STRESS` and
/// run in isolation via `CODEXBAR_TSAN_STRESS=1 swift test --sanitize=thread --filter
/// DisplayIntervalOverrideConcurrencyTests`, never in the normal parallel suite.
private enum DisplayIntervalOverrideRaceProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storage: TimeInterval?
    static var value: TimeInterval? {
        get { self.lock.withLock { self.storage } }
        set { self.lock.withLock { self.storage = newValue } }
    }
}

@Suite(.serialized)
struct DisplayIntervalOverrideConcurrencyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_TSAN_STRESS"] == "1"))
    func `concurrent display-interval override writes and reads are race-free`() {
        let iterations = 5000
        let lanes = 4
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "display-interval-override.concurrency", attributes: .concurrent)
        for lane in 0..<lanes {
            group.enter()
            queue.async {
                for i in 0..<iterations {
                    if (lane + i) % 2 == 0 {
                        DisplayIntervalOverrideRaceProbe.value = TimeInterval(i)
                    } else {
                        _ = DisplayIntervalOverrideRaceProbe.value
                    }
                }
                group.leave()
            }
        }
        group.wait()
        DisplayIntervalOverrideRaceProbe.value = nil
    }
}
