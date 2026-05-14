import AppKit
import CodexBarCore
import Foundation

/// Opens Cursor in the user's browser and waits until the normal browser-cookie importer can read a session.
@MainActor
final class CursorLoginRunner {
    enum Phase {
        case loading
        case waitingLogin
        case success
        case failed(String)
    }

    struct Result {
        enum Outcome {
            case success
            case cancelled
            case failed(String)
        }

        let outcome: Outcome
        let email: String?
    }

    typealias SnapshotLoader = @Sendable () async throws -> CursorStatusSnapshot
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let loadSnapshot: SnapshotLoader
    private let openURL: @MainActor (URL) -> Bool
    private let sleeper: Sleeper
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let logger = CodexBarLog.logger(LogCategories.cursorLogin)

    static let dashboardURL = URL(string: "https://cursor.com/dashboard")!

    init(
        browserDetection: BrowserDetection,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 2,
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        loadSnapshot: SnapshotLoader? = nil,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) })
    {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.openURL = openURL
        self.sleeper = sleeper
        self.loadSnapshot = loadSnapshot ?? {
            let probe = CursorStatusProbe(browserDetection: browserDetection)
            return try await probe.fetch()
        }
    }

    func run(onPhaseChange: @escaping @MainActor (Phase) -> Void) async -> Result {
        onPhaseChange(.loading)
        self.logger.info("Cursor login started")

        guard self.openURL(Self.dashboardURL) else {
            let message = "Could not open Cursor login in your browser."
            onPhaseChange(.failed(message))
            self.logger.error("Cursor login browser launch failed")
            return Result(outcome: .failed(message), email: nil)
        }

        onPhaseChange(.waitingLogin)
        let deadline = Date().addingTimeInterval(self.timeout)
        var lastError: Error?

        repeat {
            if Task.isCancelled {
                self.logger.info("Cursor login cancelled")
                return Result(outcome: .cancelled, email: nil)
            }

            do {
                let snapshot = try await self.loadSnapshot()
                onPhaseChange(.success)
                self.logger.info("Cursor login completed", metadata: ["outcome": "success"])
                return Result(outcome: .success, email: snapshot.accountEmail)
            } catch {
                lastError = error
            }

            guard Date() < deadline else { break }
            let delay = UInt64(max(0.1, self.pollInterval) * 1_000_000_000)
            try? await self.sleeper(delay)
        } while true

        let message = Self.timeoutMessage(lastError: lastError)
        onPhaseChange(.failed(message))
        self.logger.warning("Cursor login timed out", metadata: ["error": message])
        return Result(outcome: .failed(message), email: nil)
    }

    private static func timeoutMessage(lastError: Error?) -> String {
        let hint = "Sign in to cursor.com in your browser, then refresh Cursor in CodexBar."
        guard let lastError else {
            return "Timed out waiting for Cursor login. \(hint)"
        }
        return "Timed out waiting for Cursor login. \(hint) Last error: \(lastError.localizedDescription)"
    }
}
