import Foundation
import Testing

/// Regression probe for the `URLProtocol` test-stub `handler` data race fixed by backing each
/// stub's handler with a `LockIsolated` box. The stubs store their per-test handler in a static
/// that URLSession reads on a background thread while the test assigns it from another — a data
/// race under ThreadSanitizer. This mirrors that exact shape on a representative stub-style static
/// and asserts TSan sees no race once the storage is boxed.
///
/// Opt-in: it hammers a static thousands of times, so it is gated behind `CODEXBAR_TSAN_STRESS` and
/// run in isolation via `CODEXBAR_TSAN_STRESS=1 swift test --sanitize=thread --filter
/// StubURLProtocolHandlerConcurrencyTests`, never in the normal parallel suite.
private enum StubHandlerRaceProbe {
    // Mirrors the fixed stub shape: handler stored behind a LockIsolated box, exposed as a
    // computed property so read and write are both serialized.
    private static let box = LockIsolated<(@Sendable (Int) -> Int)?>(nil)
    static var handler: (@Sendable (Int) -> Int)? {
        get { self.box.value }
        set { self.box.setValue(newValue) }
    }
}

@Suite(.serialized)
struct StubURLProtocolHandlerConcurrencyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_TSAN_STRESS"] == "1"))
    func `concurrent stub handler writes and reads are race-free`() {
        let iterations = 5000
        let lanes = 4
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stub-handler.concurrency", attributes: .concurrent)
        for lane in 0..<lanes {
            group.enter()
            queue.async {
                for i in 0..<iterations {
                    if (lane + i) % 2 == 0 {
                        StubHandlerRaceProbe.handler = { $0 + lane }
                    } else {
                        _ = StubHandlerRaceProbe.handler
                    }
                }
                group.leave()
            }
        }
        group.wait()
        StubHandlerRaceProbe.handler = nil
    }
}
